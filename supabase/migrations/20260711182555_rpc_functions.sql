-- Operaciones atómicas críticas como funciones PostgreSQL/RPC.
--
-- Decisión de arquitectura (ver ARCHITECTURE.md / DECISIONS.md): el SDK
-- cliente de Supabase no permite ejecutar de forma segura una
-- transacción multi-statement desde JavaScript. "Reservar stock",
-- "convertir una reserva en entradas" y "expirar reservas" son
-- operaciones que necesitan verificar un estado, actuar sobre varias
-- tablas y comprometerse atómicamente. Por eso se implementan acá como
-- funciones PL/pgSQL, invocadas vía RPC desde el backend (Route
-- Handlers) usando la service role key. Nunca se simulan estas
-- transacciones con múltiples llamadas independientes desde TypeScript.
--
-- Todas las funciones fijan `search_path` explícitamente (buena
-- práctica estándar para funciones de Postgres, independientemente de
-- SECURITY DEFINER/INVOKER) y quedan con EXECUTE revocado para
-- anon/authenticated al final de este archivo: solo se invocan desde el
-- servidor con la service role key.

-- ---------------------------------------------------------------------
-- create_order_with_reservation
--
-- Crea una orden PENDING_PAYMENT y reserva stock de forma atómica.
-- Los precios SIEMPRE se leen de `ticket_types` en este momento; nunca
-- se confía en un precio enviado por el cliente (ver AJUSTE 1).
--
-- Idempotencia: `p_idempotency_key` es única globalmente. Si ya existe
-- una orden con esa clave:
--   - mismo fingerprint (mismo comprador + mismos ítems) -> se devuelve
--     la orden existente sin crear una nueva.
--   - fingerprint distinto -> conflicto (excepción
--     IDEMPOTENCY_KEY_CONFLICT), la capa HTTP la traduce a 409.
--
-- p_items: jsonb con la forma [{"ticket_type_id": "<uuid>", "quantity": 2}, ...]
-- ---------------------------------------------------------------------

create function public.create_order_with_reservation(
  p_buyer_name text,
  p_buyer_email text,
  p_buyer_phone text,
  p_idempotency_key text,
  p_items jsonb,
  p_reservation_minutes integer default 15
)
returns table (
  order_id uuid,
  order_status public.order_status,
  total_amount_cents bigint,
  is_new boolean
)
language plpgsql
set search_path = public, extensions
as $$
declare
  v_fingerprint text;
  v_existing record;
  v_order_id uuid;
  v_expires_at timestamptz;
  v_total_cents bigint := 0;
  v_item record;
  v_tt record;
  v_normalized_items jsonb;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) = 0 then
    raise exception 'INVALID_REQUEST: idempotency key is required';
  end if;

  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'INVALID_REQUEST: at least one item is required';
  end if;

  -- Representación canónica para el fingerprint: comprador normalizado +
  -- ítems ordenados por ticket_type_id. Cualquier cambio de contenido de
  -- la compra cambia el fingerprint.
  select jsonb_agg(jsonb_build_object(
           'ticket_type_id', x.ticket_type_id,
           'quantity', x.quantity
         ) order by x.ticket_type_id)
    into v_normalized_items
    from jsonb_to_recordset(p_items) as x(ticket_type_id uuid, quantity integer);

  v_fingerprint := encode(
    digest(
      jsonb_build_object(
        'buyer_email', lower(trim(p_buyer_email)),
        'buyer_name', trim(p_buyer_name),
        'items', v_normalized_items
      )::text,
      'sha256'
    ),
    'hex'
  );

  select o.id, o.status, o.total_amount_cents, o.request_fingerprint
    into v_existing
    from public.orders o
    where o.idempotency_key = p_idempotency_key;

  if found then
    if v_existing.request_fingerprint = v_fingerprint then
      return query
        select v_existing.id, v_existing.status, v_existing.total_amount_cents, false;
      return;
    else
      raise exception 'IDEMPOTENCY_KEY_CONFLICT: key % already used with a different payload', p_idempotency_key;
    end if;
  end if;

  v_expires_at := now() + make_interval(mins => p_reservation_minutes);
  v_order_id := extensions.gen_random_uuid();

  -- Bloquear los ticket_types involucrados en un orden estable
  -- (por id) para evitar deadlocks entre compras concurrentes que
  -- comparten tipos de entrada.
  for v_item in
    select x.ticket_type_id, x.quantity
    from jsonb_to_recordset(p_items) as x(ticket_type_id uuid, quantity integer)
    order by x.ticket_type_id
  loop
    if v_item.quantity is null or v_item.quantity <= 0 then
      raise exception 'INVALID_REQUEST: quantity must be positive';
    end if;

    select * into v_tt
      from public.ticket_types
      where id = v_item.ticket_type_id
      for update;

    if not found then
      raise exception 'TICKET_TYPE_NOT_FOUND: %', v_item.ticket_type_id;
    end if;

    if v_tt.status <> 'active' then
      raise exception 'TICKET_TYPE_INACTIVE: %', v_item.ticket_type_id;
    end if;

    if v_tt.sales_start is not null and now() < v_tt.sales_start then
      raise exception 'SALES_NOT_STARTED: %', v_item.ticket_type_id;
    end if;

    if v_tt.sales_end is not null and now() > v_tt.sales_end then
      raise exception 'SALES_ENDED: %', v_item.ticket_type_id;
    end if;

    if v_item.quantity > v_tt.max_per_order then
      raise exception 'MAX_PER_ORDER_EXCEEDED: % > %', v_item.quantity, v_tt.max_per_order;
    end if;

    if (v_tt.capacity - v_tt.reserved - v_tt.sold) < v_item.quantity then
      raise exception 'SOLD_OUT: %', v_item.ticket_type_id;
    end if;

    v_total_cents := v_total_cents + (v_tt.price_cents::bigint * v_item.quantity);
  end loop;

  insert into public.orders (
    id, buyer_name, buyer_email, buyer_phone, status, currency,
    total_amount_cents, idempotency_key, request_fingerprint, expires_at
  ) values (
    v_order_id, trim(p_buyer_name), lower(trim(p_buyer_email)), nullif(trim(p_buyer_phone), ''),
    'PENDING_PAYMENT', 'ARS', v_total_cents, p_idempotency_key, v_fingerprint, v_expires_at
  );

  for v_item in
    select x.ticket_type_id, x.quantity
    from jsonb_to_recordset(p_items) as x(ticket_type_id uuid, quantity integer)
    order by x.ticket_type_id
  loop
    select * into v_tt from public.ticket_types where id = v_item.ticket_type_id;

    insert into public.order_items (order_id, ticket_type_id, quantity, unit_price_cents)
      values (v_order_id, v_item.ticket_type_id, v_item.quantity, v_tt.price_cents);

    insert into public.stock_reservations (order_id, ticket_type_id, quantity, status, expires_at)
      values (v_order_id, v_item.ticket_type_id, v_item.quantity, 'ACTIVE', v_expires_at);

    update public.ticket_types
      set reserved = reserved + v_item.quantity
      where id = v_item.ticket_type_id;
  end loop;

  return query select v_order_id, 'PENDING_PAYMENT'::public.order_status, v_total_cents, true;
end;
$$;

-- ---------------------------------------------------------------------
-- expire_stale_reservations
--
-- Libera reservas ACTIVE vencidas y expira las órdenes PENDING_PAYMENT
-- correspondientes. Idempotente: correrla dos veces en simultáneo es
-- seguro porque el UPDATE solo afecta filas todavía en estado ACTIVE.
-- Pensada para ejecutarse cada 1 minuto vía pg_cron.
-- ---------------------------------------------------------------------

create function public.expire_stale_reservations()
returns integer
language plpgsql
set search_path = public, extensions
as $$
declare
  v_count integer := 0;
  r record;
begin
  for r in
    select id, order_id, ticket_type_id, quantity
    from public.stock_reservations
    where status = 'ACTIVE' and expires_at < now()
    order by ticket_type_id
  loop
    update public.stock_reservations
      set status = 'EXPIRED', released_at = now()
      where id = r.id and status = 'ACTIVE';

    if found then
      update public.ticket_types
        set reserved = greatest(reserved - r.quantity, 0)
        where id = r.ticket_type_id;

      update public.orders
        set status = 'EXPIRED'
        where id = r.order_id and status = 'PENDING_PAYMENT';

      v_count := v_count + 1;
    end if;
  end loop;

  if v_count > 0 then
    insert into public.admin_audit_logs (action, entity_type, metadata)
      values ('expire_stale_reservations', 'stock_reservations', jsonb_build_object('expired_count', v_count));
  end if;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- release_reservation_for_order
--
-- Libera de inmediato la reserva de una orden (pago rechazado/cancelado
-- informado por Mercado Pago, o cancelación manual de un admin), sin
-- esperar el vencimiento del TTL.
-- ---------------------------------------------------------------------

create function public.release_reservation_for_order(p_order_id uuid)
returns void
language plpgsql
set search_path = public, extensions
as $$
declare
  r record;
begin
  for r in
    select id, ticket_type_id, quantity
    from public.stock_reservations
    where order_id = p_order_id and status = 'ACTIVE'
    order by ticket_type_id
  loop
    update public.stock_reservations
      set status = 'RELEASED', released_at = now()
      where id = r.id and status = 'ACTIVE';

    if found then
      update public.ticket_types
        set reserved = greatest(reserved - r.quantity, 0)
        where id = r.ticket_type_id;
    end if;
  end loop;

  update public.orders
    set status = 'CANCELLED'
    where id = p_order_id and status = 'PENDING_PAYMENT';
end;
$$;

-- ---------------------------------------------------------------------
-- _try_issue_tickets_for_order (interna)
--
-- Intenta asegurar capacidad y emitir las entradas de una orden a
-- partir de sus `order_items` (fuente de verdad de qué se compró, no de
-- `stock_reservations`, que puede estar vencida). Se ejecuta en dos
-- pasadas dentro de la misma transacción del caller: primero verifica
-- factibilidad de TODOS los ítems (todo o nada), y solo si alcanza para
-- todos, consume capacidad y genera las entradas. No decide el estado
-- de la orden: eso lo hace la función que la invoca.
--
-- Devuelve true si se emitieron entradas, false si no había capacidad
-- suficiente (y no modifica nada en ese caso).
-- ---------------------------------------------------------------------

create function public._try_issue_tickets_for_order(p_order_id uuid)
returns boolean
language plpgsql
set search_path = public, extensions
as $$
declare
  v_item record;
  v_tt record;
  v_available integer;
  v_feasible boolean := true;
  v_reservation_id uuid;
  i integer;
begin
  -- Pasada 1: bloquear ticket_types involucrados (orden estable) y
  -- verificar que haya capacidad para cada ítem.
  for v_item in
    select oi.ticket_type_id, oi.quantity
    from public.order_items oi
    where oi.order_id = p_order_id
    order by oi.ticket_type_id
  loop
    select * into v_tt from public.ticket_types where id = v_item.ticket_type_id for update;

    -- Si ya existe una reserva ACTIVE de esta orden para este ticket_type,
    -- esa cantidad ya está contemplada en `reserved` y no debe exigirse
    -- de nuevo contra la capacidad disponible.
    v_available := v_tt.capacity - v_tt.sold - (
      v_tt.reserved - coalesce((
        select sum(sr.quantity) from public.stock_reservations sr
        where sr.order_id = p_order_id and sr.ticket_type_id = v_item.ticket_type_id and sr.status = 'ACTIVE'
      ), 0)
    );

    if v_available < v_item.quantity then
      v_feasible := false;
      exit;
    end if;
  end loop;

  if not v_feasible then
    return false;
  end if;

  -- Pasada 2: consumir capacidad y emitir entradas.
  for v_item in
    select oi.id as order_item_id, oi.ticket_type_id, oi.quantity
    from public.order_items oi
    where oi.order_id = p_order_id
    order by oi.ticket_type_id
  loop
    select id into v_reservation_id
      from public.stock_reservations
      where order_id = p_order_id and ticket_type_id = v_item.ticket_type_id and status = 'ACTIVE'
      limit 1;

    if v_reservation_id is not null then
      update public.stock_reservations
        set status = 'CONVERTED', converted_at = now()
        where id = v_reservation_id;

      update public.ticket_types
        set reserved = greatest(reserved - v_item.quantity, 0), sold = sold + v_item.quantity
        where id = v_item.ticket_type_id;
    else
      -- Pago tardío: la reserva original ya no existe (venció o nunca se
      -- llegó a crear), pero pasada 1 confirmó que hay capacidad real
      -- disponible ahora mismo. Se registra igual como reserva CONVERTED
      -- para que `stock_reservations` sea el libro completo de consumo
      -- de capacidad, con o sin paso por ACTIVE.
      insert into public.stock_reservations (order_id, ticket_type_id, quantity, status, expires_at, converted_at)
        values (p_order_id, v_item.ticket_type_id, v_item.quantity, 'CONVERTED', now(), now());

      update public.ticket_types
        set sold = sold + v_item.quantity
        where id = v_item.ticket_type_id;
    end if;

    for i in 1..v_item.quantity loop
      insert into public.tickets (
        order_id, order_item_id, event_id, ticket_type_id, public_token, short_code, status
      )
      select
        p_order_id,
        v_item.order_item_id,
        tt.event_id,
        v_item.ticket_type_id,
        encode(extensions.gen_random_bytes(32), 'hex'),
        upper(encode(extensions.gen_random_bytes(5), 'hex')),
        'VALID'
      from public.ticket_types tt
      where tt.id = v_item.ticket_type_id;
    end loop;
  end loop;

  return true;
end;
$$;

-- ---------------------------------------------------------------------
-- record_payment_and_confirm_order
--
-- Punto de entrada único, agnóstico al proveedor, al recibir un hecho de
-- pago ya verificado contra la API del proveedor correspondiente (nunca
-- se confía únicamente en el contenido de un webhook — ver SECURITY.md).
-- La capa de integración (`lib/payments/`, Fase 3) es responsable de
-- normalizar el estado y los datos del proveedor antes de llamar a esta
-- función; acá adentro no se conoce ningún detalle específico de
-- Mercado Pago ni de ningún otro proveedor.
--
-- Registra el hecho de pago en `payments` (upsert idempotente por
-- `(provider, external_payment_id)`, seguro ante reintentos de webhook)
-- y decide atómicamente, según `p_status` y el estado actual de la
-- orden:
--
--   APPROVED  y la orden todavía no está resuelta (PENDING_PAYMENT,
--             EXPIRED o CANCELLED) -> intenta emitir tickets (rescata
--             un pago tardío si hace falta, igual que antes); si no
--             alcanza la capacidad, PAID_REQUIRES_REVIEW.
--   APPROVED  pero la orden YA está PAID/PAID_REQUIRES_REVIEW/REFUNDED
--             con un pago aprobado *distinto* -> doble pago real: se
--             marca este `payments.reconciliation_status =
--             DUPLICATE_REQUIRES_REFUND` y se audita, sin tocar la
--             orden ni emitir tickets de más (ver DECISIONS.md,
--             "Política de doble pago").
--   REJECTED / CANCELLED -> libera la reserva de inmediato si la orden
--             seguía pendiente; si la orden ya está pagada por otro
--             intento, no cambia nada.
--   REFUNDED / CHARGED_BACK -> si la orden estaba PAID, la mueve a
--             REFUNDED y cancela las entradas todavía VALID (nunca las
--             ya USED).
--   PENDING / IN_PROGRESS -> solo deja registrado el hecho de pago.
--
-- Idempotente ante reintentos del webhook: un mismo
-- `(provider, external_payment_id)` que vuelve a llegar actualiza la
-- fila existente y no reprocesa la orden dos veces.
-- ---------------------------------------------------------------------

create function public.record_payment_and_confirm_order(
  p_order_id uuid,
  p_payment_attempt_id uuid,
  p_provider text,
  p_external_payment_id text,
  p_status public.payment_status,
  p_raw_provider_status text,
  p_amount_cents bigint,
  p_currency text,
  p_payment_method_type public.payment_method_type,
  p_external_reference text,
  p_approved_at timestamptz
)
returns table (
  payment_id uuid,
  order_status public.order_status,
  tickets_issued boolean,
  reconciliation_status public.payment_reconciliation_status
)
language plpgsql
set search_path = public, extensions
as $$
declare
  v_order record;
  v_payment_id uuid;
  v_prior_approved_id uuid;
  v_issued boolean := false;
  v_reconciliation public.payment_reconciliation_status := 'NORMAL';
  v_final_status public.order_status;
begin
  if p_provider is null or length(trim(p_provider)) = 0 then
    raise exception 'INVALID_REQUEST: provider is required';
  end if;

  select id into v_payment_id
    from public.payments
    where provider = p_provider and external_payment_id = p_external_payment_id;

  if found then
    update public.payments
      set status = p_status,
          raw_provider_status = p_raw_provider_status,
          approved_at = coalesce(p_approved_at, approved_at),
          updated_at = now()
      where id = v_payment_id;
  else
    insert into public.payments (
      order_id, payment_attempt_id, provider, external_payment_id, status,
      raw_provider_status, amount_cents, currency, payment_method_type,
      external_reference, approved_at
    ) values (
      p_order_id, p_payment_attempt_id, p_provider, p_external_payment_id, p_status,
      p_raw_provider_status, p_amount_cents, p_currency, p_payment_method_type,
      p_external_reference, p_approved_at
    )
    returning id into v_payment_id;
  end if;

  if p_payment_attempt_id is not null and p_status <> 'PENDING' and p_status <> 'IN_PROGRESS' then
    update public.payment_attempts
      set status = 'RESOLVED', updated_at = now()
      where id = p_payment_attempt_id;
  end if;

  select * into v_order from public.orders where id = p_order_id for update;

  if not found then
    raise exception 'ORDER_NOT_FOUND: %', p_order_id;
  end if;

  if p_status = 'APPROVED' then
    if v_order.status in ('PAID', 'PAID_REQUIRES_REVIEW') then
      -- ¿Es un pago aprobado genuinamente distinto del que ya había
      -- resuelto la orden, o es un reintento de webhook del mismo pago?
      select p.id into v_prior_approved_id
        from public.payments p
        where p.order_id = p_order_id
          and p.status = 'APPROVED'
          and p.id <> v_payment_id
          and p.reconciliation_status = 'NORMAL'
        limit 1;

      if v_prior_approved_id is not null then
        update public.payments set reconciliation_status = 'DUPLICATE_REQUIRES_REFUND' where id = v_payment_id;
        v_reconciliation := 'DUPLICATE_REQUIRES_REFUND';

        insert into public.admin_audit_logs (action, entity_type, entity_id, metadata)
          values (
            'duplicate_payment_detected', 'payments', v_payment_id,
            jsonb_build_object(
              'order_id', p_order_id,
              'prior_payment_id', v_prior_approved_id,
              'provider', p_provider,
              'external_payment_id', p_external_payment_id
            )
          );
      end if;
      v_issued := v_order.status = 'PAID';

    elsif v_order.status = 'REFUNDED' then
      -- Pago aprobado llegando después de un reembolso ya sincronizado:
      -- caso anómalo, se registra para revisión, nunca se re-emite nada.
      update public.payments set reconciliation_status = 'DUPLICATE_REQUIRES_REFUND' where id = v_payment_id;
      v_reconciliation := 'DUPLICATE_REQUIRES_REFUND';

      insert into public.admin_audit_logs (action, entity_type, entity_id, metadata)
        values ('payment_after_refund', 'payments', v_payment_id, jsonb_build_object('order_id', p_order_id));

    else
      -- PENDING_PAYMENT, EXPIRED o CANCELLED: camino normal o rescate de
      -- pago tardío (igual que antes de esta corrección).
      v_issued := public._try_issue_tickets_for_order(p_order_id);

      if v_issued then
        update public.orders
          set status = 'PAID', paid_at = now(), requires_review_reason = null
          where id = p_order_id;
      else
        update public.orders
          set status = 'PAID_REQUIRES_REVIEW',
              requires_review_reason = 'Pago aprobado sin capacidad disponible al momento de la confirmación'
          where id = p_order_id;

        insert into public.admin_audit_logs (action, entity_type, entity_id, metadata)
          values ('payment_requires_review', 'orders', p_order_id, jsonb_build_object('reason', 'insufficient_capacity'));
      end if;
    end if;

  elsif p_status in ('REJECTED', 'CANCELLED') then
    if v_order.status in ('PENDING_PAYMENT', 'EXPIRED') then
      perform public.release_reservation_for_order(p_order_id);
    end if;
    -- Si la orden ya está PAID por otro intento, un rechazo de este no
    -- cambia nada: queda solo registrado en `payments`.

  elsif p_status in ('REFUNDED', 'CHARGED_BACK') then
    if v_order.status = 'PAID' then
      update public.orders set status = 'REFUNDED' where id = p_order_id;

      update public.tickets set status = 'REFUNDED'
        where order_id = p_order_id and status = 'VALID';

      insert into public.admin_audit_logs (action, entity_type, entity_id, metadata)
        values (
          'order_refunded_by_provider', 'orders', p_order_id,
          jsonb_build_object('provider', p_provider, 'external_payment_id', p_external_payment_id)
        );
    end if;
  end if;
  -- PENDING / IN_PROGRESS: sin acción adicional, solo queda registrado
  -- el hecho de pago (ya hecho arriba).

  select status into v_final_status from public.orders where id = p_order_id;

  return query select v_payment_id, v_final_status, v_issued, v_reconciliation;
end;
$$;

-- ---------------------------------------------------------------------
-- issue_tickets_after_review
--
-- Resolución manual (admin, fases posteriores) de una orden
-- PAID_REQUIRES_REVIEW cuando se liberó capacidad. Reutiliza la misma
-- lógica de emisión; si todavía no hay capacidad, no hace nada y
-- devuelve tickets_issued = false para que el admin elija otra
-- resolución (ej. reembolsar).
-- ---------------------------------------------------------------------

create function public.issue_tickets_after_review(p_order_id uuid)
returns table (order_status public.order_status, tickets_issued boolean)
language plpgsql
set search_path = public, extensions
as $$
declare
  v_order record;
  v_issued boolean;
begin
  select * into v_order from public.orders where id = p_order_id for update;

  if not found then
    raise exception 'ORDER_NOT_FOUND: %', p_order_id;
  end if;

  if v_order.status <> 'PAID_REQUIRES_REVIEW' then
    raise exception 'INVALID_ORDER_STATUS: expected PAID_REQUIRES_REVIEW, got %', v_order.status;
  end if;

  v_issued := public._try_issue_tickets_for_order(p_order_id);

  if v_issued then
    update public.orders
      set status = 'PAID', paid_at = coalesce(paid_at, now()), requires_review_reason = null
      where id = p_order_id;

    return query select 'PAID'::public.order_status, true;
  else
    return query select 'PAID_REQUIRES_REVIEW'::public.order_status, false;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- validate_ticket
--
-- Validación atómica de QR en /scan. El UPDATE condicional
-- (`WHERE status = 'VALID'`) es la operación atómica: de dos escaneos
-- concurrentes del mismo token, Postgres garantiza que como máximo uno
-- tenga éxito. Registra siempre un access_log, sea cual sea el
-- resultado.
-- ---------------------------------------------------------------------

create function public.validate_ticket(
  p_public_token text,
  p_scanner_id uuid,
  p_device text default null
)
returns table (
  result public.access_result,
  ticket_id uuid,
  event_id uuid,
  ticket_type_name text,
  buyer_name text,
  used_at timestamptz
)
language plpgsql
set search_path = public, extensions
as $$
declare
  v_updated record;
  v_existing record;
  v_result public.access_result;
  v_ticket_id uuid;
  v_event_id uuid;
  v_type_name text;
  v_buyer_name text;
  v_used_at timestamptz;
begin
  update public.tickets t
    set status = 'USED', used_at = now(), validated_by = p_scanner_id, validation_device = p_device
    where t.public_token = p_public_token and t.status = 'VALID'
    returning t.id, t.event_id, t.ticket_type_id, t.order_id, t.used_at
    into v_updated;

  if found then
    select tt.name, o.buyer_name
      into v_type_name, v_buyer_name
      from public.ticket_types tt
      join public.orders o on o.id = v_updated.order_id
      where tt.id = v_updated.ticket_type_id;

    v_result := 'GRANTED';
    v_ticket_id := v_updated.id;
    v_event_id := v_updated.event_id;
    v_used_at := v_updated.used_at;
  else
    select t.id, t.event_id, t.status, t.used_at, tt.name, o.buyer_name
      into v_existing
      from public.tickets t
      join public.ticket_types tt on tt.id = t.ticket_type_id
      join public.orders o on o.id = t.order_id
      where t.public_token = p_public_token;

    if not found then
      v_result := 'DENIED_INVALID';
      v_ticket_id := null;
      v_event_id := null;
    elsif v_existing.status = 'USED' then
      v_result := 'DENIED_USED';
      v_ticket_id := v_existing.id;
      v_event_id := v_existing.event_id;
      v_used_at := v_existing.used_at;
      v_type_name := v_existing.name;
      v_buyer_name := v_existing.buyer_name;
    else
      -- CANCELLED o REFUNDED
      v_result := 'DENIED_CANCELLED';
      v_ticket_id := v_existing.id;
      v_event_id := v_existing.event_id;
      v_type_name := v_existing.name;
      v_buyer_name := v_existing.buyer_name;
    end if;
  end if;

  insert into public.access_logs (
    ticket_id, event_id, scanner_user_id, result, scanner_device, attempted_token
  ) values (
    v_ticket_id, v_event_id, p_scanner_id, v_result, p_device, p_public_token
  );

  return query select v_result, v_ticket_id, v_event_id, v_type_name, v_buyer_name, v_used_at;
end;
$$;

-- ---------------------------------------------------------------------
-- Privilegios: estas funciones solo se invocan desde el servidor con la
-- service role key. Se revoca EXECUTE del rol PUBLIC (otorgado por
-- defecto en Postgres) para que anon/authenticated no puedan invocarlas
-- vía RPC de PostgREST.
-- ---------------------------------------------------------------------

revoke execute on function public.create_order_with_reservation(text, text, text, text, jsonb, integer) from public;
revoke execute on function public.expire_stale_reservations() from public;
revoke execute on function public.release_reservation_for_order(uuid) from public;
revoke execute on function public._try_issue_tickets_for_order(uuid) from public;
revoke execute on function public.record_payment_and_confirm_order(uuid, uuid, text, text, public.payment_status, text, bigint, text, public.payment_method_type, text, timestamptz) from public;
revoke execute on function public.issue_tickets_after_review(uuid) from public;
revoke execute on function public.validate_ticket(text, uuid, text) from public;

grant execute on function public.create_order_with_reservation(text, text, text, text, jsonb, integer) to service_role;
grant execute on function public.expire_stale_reservations() to service_role;
grant execute on function public.release_reservation_for_order(uuid) to service_role;
grant execute on function public._try_issue_tickets_for_order(uuid) to service_role;
grant execute on function public.record_payment_and_confirm_order(uuid, uuid, text, text, public.payment_status, text, bigint, text, public.payment_method_type, text, timestamptz) to service_role;
grant execute on function public.issue_tickets_after_review(uuid) to service_role;
grant execute on function public.validate_ticket(text, uuid, text) to service_role;
