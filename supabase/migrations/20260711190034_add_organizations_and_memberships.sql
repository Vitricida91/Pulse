-- Revisión Arquitectónica 1.1 — SaaS-ready (no SaaS-yet).
--
-- Introduce `organizations` como raíz de pertenencia organizacional y
-- `organization_memberships` como fuente de verdad de rol/autorización,
-- reemplazando `profiles.role` (global, sin ámbito). Ver DECISIONS.md
-- para el análisis completo y las alternativas consideradas.
--
-- Esta es una migración NUEVA e incremental: no se editan las
-- migraciones de la Fase 1 ni de la corrección de pagos, ya publicadas.

-- ---------------------------------------------------------------------
-- organizations
--
-- Modelo mínimo para el MVP (principio de minimización): no incluye
-- todavía `legal_name`, `contact_email` ni `logo_url` — se agregan
-- cuando exista una necesidad funcional concreta (branding de
-- organización, Horizonte 2), como columnas nuevas nullable, sin
-- romper nada de lo que sigue.
-- ---------------------------------------------------------------------

create type public.organization_status as enum ('active', 'inactive');

create table public.organizations (
  id uuid primary key default extensions.gen_random_uuid(),
  name text not null,
  slug text not null,
  status public.organization_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index organizations_slug_key on public.organizations (slug);

create trigger organizations_set_updated_at
  before update on public.organizations
  for each row
  execute function public.set_updated_at();

-- Bootstrap idempotente de la primera organización real. No es una
-- constante del dominio: es una fila de datos, igual que cualquier otra
-- organización que se cargue después. `on conflict` sobre el `slug`
-- único hace que aplicar esta migración más de una vez (ej. en un
-- `db reset` local) no duplique la fila. Ninguna lógica de aplicación
-- (RPC, TypeScript) referencia este nombre ni este slug — el dominio
-- obtiene la organización desde la base de datos, no desde una
-- constante en el código (ver DECISIONS.md, "Estrategia de seed").
insert into public.organizations (name, slug, status)
values ('The Pulse Project', 'the-pulse-project', 'active')
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------
-- events.organization_id
--
-- Se agrega nullable, se hace un backfill explícito y recién después se
-- exige NOT NULL — el patrón seguro de migración aunque, a la fecha de
-- esta migración, no exista ningún dato real en ningún entorno (ver
-- DECISIONS.md). El backfill asigna los eventos existentes (si los
-- hubiera) a la organización sembrada arriba: es la única asignación
-- razonable posible sin más información, no una asunción de que
-- siempre habrá una sola organización.
-- ---------------------------------------------------------------------

alter table public.events add column organization_id uuid references public.organizations (id);

update public.events
  set organization_id = (select id from public.organizations where slug = 'the-pulse-project')
  where organization_id is null;

alter table public.events alter column organization_id set not null;

create index events_organization_id_idx on public.events (organization_id);

-- ---------------------------------------------------------------------
-- orders.event_id
--
-- Cierra un hueco de integridad de la Fase 1: `create_order_with_reservation`
-- nunca exigió que los `ticket_type_id` de una orden pertenecieran al
-- mismo evento. El backfill deriva el evento de los `order_items`
-- existentes (si los hubiera) en vez de asumir una organización fija —
-- funciona igual con 0 o con N órdenes históricas.
-- ---------------------------------------------------------------------

alter table public.orders add column event_id uuid references public.events (id);

update public.orders o
  set event_id = (
    select tt.event_id
    from public.order_items oi
    join public.ticket_types tt on tt.id = oi.ticket_type_id
    where oi.order_id = o.id
    limit 1
  )
  where o.event_id is null;

alter table public.orders alter column event_id set not null;

create index orders_event_id_idx on public.orders (event_id);

-- ---------------------------------------------------------------------
-- organization_memberships
--
-- Fuente de verdad de autorización: profile -> organization_membership
-- -> organization. Roles acotados estrictamente al MVP (`admin`,
-- `scanner`); OWNER/MANAGER/VIEWER quedan documentados como extensión
-- futura de este mismo enum, no implementados. `status` solo contempla
-- `active`/`inactive`: no hay todavía flujo de invitación/onboarding
-- que justifique estados intermedios.
--
-- IMPORTANTE (ver SECURITY.md): `role = 'admin'` significa
-- "administrador de ESTA organización", nunca "administrador global de
-- la plataforma". Una futura administración de plataforma (Horizonte 2)
-- debe modelarse aparte de esta tabla, no reutilizando una membresía
-- como mecanismo de acceso global.
-- ---------------------------------------------------------------------

create type public.organization_role as enum ('admin', 'scanner');

create type public.membership_status as enum ('active', 'inactive');

create table public.organization_memberships (
  id uuid primary key default extensions.gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  role public.organization_role not null,
  status public.membership_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index organization_memberships_org_profile_key
  on public.organization_memberships (organization_id, profile_id);
create index organization_memberships_profile_id_idx on public.organization_memberships (profile_id);

create trigger organization_memberships_set_updated_at
  before update on public.organization_memberships
  for each row
  execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- Eliminación de profiles.role (Fase 0.1 lo introdujo como rol global;
-- esta revisión lo reemplaza por organization_memberships.role antes de
-- que exista ningún código de aplicación construido sobre el campo
-- global — no hay backfill de datos porque la Fase 2 de autenticación
-- todavía no está implementada y no hay perfiles reales).
-- ---------------------------------------------------------------------

alter table public.profiles drop column role;
drop type public.profile_role;
