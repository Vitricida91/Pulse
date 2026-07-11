-- Revisión Arquitectónica 1.1: una orden pertenece a un único evento.
--
-- `create_order_with_reservation` cambia de firma (se agrega
-- `p_event_id`), por eso se hace DROP + CREATE en vez de CREATE OR
-- REPLACE (Postgres identifica funciones por nombre + tipos de
-- parámetros; cambiar la lista de parámetros crea un overload nuevo en
-- vez de reemplazar la función existente).
--
-- Nueva validación server-side, dentro de la misma transacción que ya
-- bloquea y valida cada `ticket_type` (no se confía en que el frontend
-- envíe datos correctos):
--   - El evento declarado (`p_event_id`) debe existir.
--   - Cada `ticket_type_id` recibido debe pertenecer a ESE evento.
-- Esto rechaza tanto una orden que mezcle tipos de entrada de dos
-- eventos distintos como una orden cuyo `p_event_id` declarado no
-- coincide con el evento real del `ticket_type_id` recibido — es la
-- misma comprobación cubriendo ambos casos.

drop function if exists public.create_order_with_reservation(text, text, text, text, jsonb, integer);

create function public.create_order_with_reservation(
  p_buyer_name text,
  p_buyer_email text,
  p_buyer_phone text,
  p_event_id uuid,
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

  if not exists (select 1 from public.events where id = p_event_id) then
    raise exception 'EVENT_NOT_FOUND: %', p_event_id;
  end if;

  -- Representación canónica para el fingerprint: evento + comprador
  -- normalizado + ítems ordenados por ticket_type_id. Reusar la misma
  -- idempotency_key con un event_id distinto cambia el fingerprint y
  -- se rechaza como IDEMPOTENCY_KEY_CONFLICT, igual que un cambio de
  -- ítems o de comprador.
  select jsonb_agg(jsonb_build_object(
           'ticket_type_id', x.ticket_type_id,
           'quantity', x.quantity
         ) order by x.ticket_type_id)
    into v_normalized_items
    from jsonb_to_recordset(p_items) as x(ticket_type_id uuid, quantity integer);

  v_fingerprint := encode(
    digest(
      jsonb_build_object(
        'event_id', p_event_id,
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

    if v_tt.event_id <> p_event_id then
      raise exception 'TICKET_TYPE_EVENT_MISMATCH: ticket_type % belongs to event %, expected %',
        v_item.ticket_type_id, v_tt.event_id, p_event_id;
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
    id, buyer_name, buyer_email, buyer_phone, event_id, status, currency,
    total_amount_cents, idempotency_key, request_fingerprint, expires_at
  ) values (
    v_order_id, trim(p_buyer_name), lower(trim(p_buyer_email)), nullif(trim(p_buyer_phone), ''), p_event_id,
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

revoke execute on function public.create_order_with_reservation(text, text, text, uuid, text, jsonb, integer) from public;
grant execute on function public.create_order_with_reservation(text, text, text, uuid, text, jsonb, integer) to service_role;
