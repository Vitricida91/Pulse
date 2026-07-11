-- Esquema definitivo aprobado en la Fase 0.1.
--
-- Convención monetaria (ver DECISIONS.md): todos los importes se guardan
-- como enteros en la unidad mínima de la moneda ("centavos"), nunca como
-- `numeric`/`float`. Evita cualquier ambigüedad de redondeo entre Postgres,
-- TypeScript y la API de cualquier proveedor de pagos. Columnas
-- terminadas en `_cents`.
--
-- Este esquema es agnóstico al proveedor de pagos (ver DECISIONS.md:
-- "Arquitectura de pagos agnóstica al proveedor"): ninguna tabla del
-- dominio (`orders`, `tickets`, etc.) tiene columnas específicas de
-- Mercado Pago ni de ningún otro proveedor. Esa relación vive
-- exclusivamente en `payment_attempts` y `payments`.

-- ---------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------

create type public.profile_role as enum ('admin', 'scanner');

create type public.event_status as enum ('draft', 'published', 'unpublished', 'cancelled');

create type public.ticket_type_status as enum ('active', 'inactive');

create type public.reservation_status as enum ('ACTIVE', 'RELEASED', 'EXPIRED', 'CONVERTED');

-- Máquina de estados definitiva de `orders` (Fase 0.1, sección 3).
create type public.order_status as enum (
  'PENDING_PAYMENT',
  'PAID',
  'PAID_REQUIRES_REVIEW',
  'CANCELLED',
  'EXPIRED',
  'REFUNDED'
);

-- Estados internos de pago, normalizados y agnósticos al proveedor (ver
-- DECISIONS.md: "Arquitectura de pagos agnóstica al proveedor"). Cada
-- adapter concreto (MercadoPagoProvider, futuros BankTransferProvider,
-- etc.) traduce su propio vocabulario de estados a este conjunto; nunca
-- se usan acá nombres de estados específicos de un proveedor.
create type public.payment_status as enum (
  'PENDING',
  'IN_PROGRESS',
  'APPROVED',
  'REJECTED',
  'CANCELLED',
  'REFUNDED',
  'CHARGED_BACK'
);

-- Estado del intento/sesión de pago iniciado con un proveedor (la
-- "preferencia" de Mercado Pago es un caso particular de esto, no el
-- concepto en sí). Independiente de `payment_status`: un intento puede
-- resolverse en cero, uno o -en teoría- más de un hecho de pago.
create type public.payment_attempt_status as enum (
  'CREATED',
  'AWAITING_PAYMENT',
  'RESOLVED',
  'EXPIRED'
);

-- Categoría genérica del medio de pago, para reportes/analítica
-- independientes del proveedor. Cada adapter mapea su propio detalle
-- (ej. el `payment_type_id` de Mercado Pago) a uno de estos valores.
create type public.payment_method_type as enum (
  'credit_card',
  'debit_card',
  'digital_wallet',
  'bank_transfer',
  'cash',
  'other'
);

-- Resultado de la conciliación de un hecho de pago contra el estado de
-- la orden. `DUPLICATE_REQUIRES_REFUND` marca un pago aprobado
-- genuinamente distinto del que ya había resuelto la orden (ver
-- DECISIONS.md: política de doble pago). No confundir con un reintento
-- de webhook del mismo pago, que es idempotente y no genera esta marca.
create type public.payment_reconciliation_status as enum (
  'NORMAL',
  'DUPLICATE_REQUIRES_REFUND'
);

create type public.ticket_status as enum ('VALID', 'USED', 'CANCELLED', 'REFUNDED');

create type public.access_result as enum ('GRANTED', 'DENIED_USED', 'DENIED_INVALID', 'DENIED_CANCELLED');

create type public.webhook_processing_status as enum ('pending', 'processed', 'failed', 'ignored');

create type public.recovery_token_status as enum ('ACTIVE', 'USED', 'EXPIRED');

create type public.email_type as enum ('purchase_confirmation', 'ticket_delivery', 'recovery_link');

create type public.email_status as enum ('queued', 'sent', 'failed');

-- ---------------------------------------------------------------------
-- profiles — únicamente staff (admin / scanner). Los compradores nunca
-- requieren fila acá (checkout como invitado, ver DECISIONS.md).
-- ---------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null,
  email text not null,
  role public.profile_role not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- events — cada función/fecha es un evento independiente (sin entidad
-- `show`/`production` superior por ahora; se puede agregar después sin
-- romper este modelo).
-- ---------------------------------------------------------------------

create table public.events (
  id uuid primary key default extensions.gen_random_uuid(),
  title text not null,
  slug text not null,
  description text,
  venue text not null,
  city text not null,
  event_date timestamptz not null,
  doors_open timestamptz,
  image_url text,
  status public.event_status not null default 'draft',
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index events_slug_key on public.events (slug);
create index events_status_idx on public.events (status);

-- ---------------------------------------------------------------------
-- ticket_types — configurables desde el panel admin, no hardcodeados.
-- `reserved` y `sold` son contadores derivados de `stock_reservations` y
-- `tickets` respectivamente, mantenidos por las funciones RPC dentro de
-- la misma transacción que su fuente de verdad (ver rpc_functions.sql).
-- ---------------------------------------------------------------------

create table public.ticket_types (
  id uuid primary key default extensions.gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  name text not null,
  description text,
  price_cents integer not null check (price_cents >= 0),
  capacity integer not null check (capacity >= 0),
  reserved integer not null default 0 check (reserved >= 0),
  sold integer not null default 0 check (sold >= 0),
  max_per_order integer not null default 6 check (max_per_order > 0),
  sales_start timestamptz,
  sales_end timestamptz,
  status public.ticket_type_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ticket_types_capacity_ck check (reserved + sold <= capacity),
  constraint ticket_types_sales_window_ck check (
    sales_start is null or sales_end is null or sales_start < sales_end
  )
);

create index ticket_types_event_id_idx on public.ticket_types (event_id);

-- ---------------------------------------------------------------------
-- orders — máquina de estados definida en DECISIONS.md.
--
-- Deliberadamente SIN ningún campo de un proveedor de pagos específico
-- (ver DECISIONS.md: "Arquitectura de pagos agnóstica al proveedor"). La
-- relación de una orden con sus intentos de pago vive enteramente en
-- `payment_attempts`/`payments`, referenciando `order_id` — nunca al
-- revés.
-- ---------------------------------------------------------------------

create table public.orders (
  id uuid primary key default extensions.gen_random_uuid(),
  buyer_name text not null,
  buyer_email text not null,
  buyer_phone text,
  status public.order_status not null default 'PENDING_PAYMENT',
  currency text not null default 'ARS',
  total_amount_cents bigint not null check (total_amount_cents >= 0),
  idempotency_key text not null,
  request_fingerprint text not null,
  requires_review_reason text,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  paid_at timestamptz
);

create unique index orders_idempotency_key_key on public.orders (idempotency_key);
create index orders_status_created_at_idx on public.orders (status, created_at);
create index orders_status_expires_at_idx on public.orders (status, expires_at);
create index orders_buyer_email_idx on public.orders (buyer_email);

-- ---------------------------------------------------------------------
-- stock_reservations — fuente de verdad de la reserva temporal de stock
-- (Fase 0.1, sección 1: modelo híbrido).
-- ---------------------------------------------------------------------

create table public.stock_reservations (
  id uuid primary key default extensions.gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  ticket_type_id uuid not null references public.ticket_types (id),
  quantity integer not null check (quantity > 0),
  status public.reservation_status not null default 'ACTIVE',
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  released_at timestamptz,
  converted_at timestamptz
);

create index stock_reservations_ticket_type_status_idx
  on public.stock_reservations (ticket_type_id, status);
create index stock_reservations_status_expires_at_idx
  on public.stock_reservations (status, expires_at);
create index stock_reservations_order_id_idx on public.stock_reservations (order_id);

-- ---------------------------------------------------------------------
-- order_items — precio congelado al momento de compra.
-- ---------------------------------------------------------------------

create table public.order_items (
  id uuid primary key default extensions.gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  ticket_type_id uuid not null references public.ticket_types (id),
  quantity integer not null check (quantity > 0),
  unit_price_cents integer not null check (unit_price_cents >= 0),
  created_at timestamptz not null default now()
);

create index order_items_order_id_idx on public.order_items (order_id);

-- ---------------------------------------------------------------------
-- payment_attempts — sesión/intento de pago iniciado con un proveedor
-- (equivalente genérico a una "preferencia" de Mercado Pago, una
-- "payment intent" de una tarjeta, o la referencia generada para una
-- transferencia bancaria). Se crea ANTES de que exista cualquier hecho
-- de pago confirmado. Una orden puede tener más de un intento (ej. un
-- primer intento abandonado y un segundo con otro proveedor).
--
-- `provider` es `text` a propósito, no un enum: agregar un proveedor
-- nuevo (adapter en `lib/payments/`) no debe requerir una migración que
-- extienda un tipo enum de Postgres. La validación del conjunto de
-- proveedores soportados vive en el código (ver DECISIONS.md).
-- ---------------------------------------------------------------------

create table public.payment_attempts (
  id uuid primary key default extensions.gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  provider text not null check (provider <> ''),
  external_session_id text,
  status public.payment_attempt_status not null default 'CREATED',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index payment_attempts_provider_session_key
  on public.payment_attempts (provider, external_session_id)
  where external_session_id is not null;
create index payment_attempts_order_id_idx on public.payment_attempts (order_id);

-- ---------------------------------------------------------------------
-- payments — un hecho de pago real reportado por un proveedor,
-- normalizado y agnóstico (ver DECISIONS.md: "Arquitectura de pagos
-- agnóstica al proveedor"). `raw_provider_status`/`payment_method_type`/
-- `external_reference` son campos genéricos y acotados; cada adapter es
-- responsable de traducir el vocabulario específico de su proveedor a
-- estos campos. Nunca se guarda acá el payload completo de un proveedor
-- (eso, cuando corresponde, es responsabilidad de `webhook_events`).
--
-- `external_reference` es el identificador que le pasamos al proveedor
-- al crear el intento de pago para que nos lo devuelva intacto junto al
-- hecho de pago (en general, el propio `order_id`); es el mecanismo
-- preferido y agnóstico para resolver a qué orden pertenece un pago. No
-- todos los proveedores lo soportan de la misma manera, por eso también
-- existe `payment_attempt_id` como mecanismo alternativo de enlace.
-- ---------------------------------------------------------------------

create table public.payments (
  id uuid primary key default extensions.gen_random_uuid(),
  order_id uuid not null references public.orders (id) on delete cascade,
  payment_attempt_id uuid references public.payment_attempts (id),
  provider text not null check (provider <> ''),
  external_payment_id text not null,
  external_reference text,
  status public.payment_status not null,
  raw_provider_status text,
  amount_cents bigint not null check (amount_cents >= 0),
  currency text not null default 'ARS',
  payment_method_type public.payment_method_type,
  reconciliation_status public.payment_reconciliation_status not null default 'NORMAL',
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  updated_at timestamptz not null default now()
);

create unique index payments_provider_external_id_key
  on public.payments (provider, external_payment_id);
create index payments_order_id_idx on public.payments (order_id);
create index payments_payment_attempt_id_idx on public.payments (payment_attempt_id);

-- ---------------------------------------------------------------------
-- tickets — el QR solo contiene `public_token` (token opaco aleatorio,
-- ver DECISIONS.md). Nunca datos personales, precio ni IDs incrementales.
-- ---------------------------------------------------------------------

create table public.tickets (
  id uuid primary key default extensions.gen_random_uuid(),
  order_id uuid not null references public.orders (id),
  order_item_id uuid references public.order_items (id),
  event_id uuid not null references public.events (id),
  ticket_type_id uuid not null references public.ticket_types (id),
  public_token text not null,
  short_code text not null,
  status public.ticket_status not null default 'VALID',
  issued_at timestamptz not null default now(),
  used_at timestamptz,
  validated_by uuid references public.profiles (id),
  validation_device text,
  created_at timestamptz not null default now()
);

create unique index tickets_public_token_key on public.tickets (public_token);
create unique index tickets_short_code_key on public.tickets (short_code);
create index tickets_event_id_status_idx on public.tickets (event_id, status);
create index tickets_order_id_idx on public.tickets (order_id);

-- ---------------------------------------------------------------------
-- access_logs — un registro por cada intento de validación en /scan,
-- exitoso o no.
-- ---------------------------------------------------------------------

create table public.access_logs (
  id uuid primary key default extensions.gen_random_uuid(),
  ticket_id uuid references public.tickets (id),
  event_id uuid references public.events (id),
  scanner_user_id uuid references public.profiles (id),
  result public.access_result not null,
  scanner_device text,
  attempted_token text,
  created_at timestamptz not null default now()
);

create index access_logs_event_id_created_at_idx on public.access_logs (event_id, created_at);
create index access_logs_ticket_id_idx on public.access_logs (ticket_id);

-- ---------------------------------------------------------------------
-- webhook_events — auditoría e idempotencia de notificaciones entrantes.
-- El constraint único es la base real de la idempotencia ante reintentos
-- o duplicados del proveedor.
-- ---------------------------------------------------------------------

create table public.webhook_events (
  id uuid primary key default extensions.gen_random_uuid(),
  provider text not null default 'mercadopago',
  external_event_id text not null,
  event_type text not null,
  payload jsonb not null,
  signature_valid boolean not null,
  processing_status public.webhook_processing_status not null default 'pending',
  attempts integer not null default 0,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);

create unique index webhook_events_provider_external_id_key
  on public.webhook_events (provider, external_event_id);
create index webhook_events_processing_status_idx on public.webhook_events (processing_status);

-- ---------------------------------------------------------------------
-- recovery_tokens — enlaces de recuperación de entradas. Se guarda el
-- hash del token, nunca el token en texto plano (igual que un reset de
-- contraseña), para que un volcado de la base no permita reutilizarlos.
-- ---------------------------------------------------------------------

create table public.recovery_tokens (
  id uuid primary key default extensions.gen_random_uuid(),
  token_hash text not null,
  buyer_email text not null,
  status public.recovery_token_status not null default 'ACTIVE',
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  used_at timestamptz
);

create unique index recovery_tokens_token_hash_key on public.recovery_tokens (token_hash);
create index recovery_tokens_buyer_email_idx on public.recovery_tokens (buyer_email);

-- ---------------------------------------------------------------------
-- email_logs — trazabilidad de envíos (confirmación, entrega de
-- entrada, enlace de recuperación), necesaria para poder reenviar y
-- para debug de entregabilidad con el proveedor.
-- ---------------------------------------------------------------------

create table public.email_logs (
  id uuid primary key default extensions.gen_random_uuid(),
  order_id uuid references public.orders (id),
  ticket_id uuid references public.tickets (id),
  type public.email_type not null,
  recipient text not null,
  provider_message_id text,
  status public.email_status not null default 'queued',
  created_at timestamptz not null default now()
);

create index email_logs_order_id_idx on public.email_logs (order_id);

-- ---------------------------------------------------------------------
-- admin_audit_logs — acciones administrativas (distinto de access_logs,
-- que es sobre validación de entradas en la puerta).
-- ---------------------------------------------------------------------

create table public.admin_audit_logs (
  id uuid primary key default extensions.gen_random_uuid(),
  actor_id uuid references public.profiles (id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index admin_audit_logs_entity_idx on public.admin_audit_logs (entity_type, entity_id);
