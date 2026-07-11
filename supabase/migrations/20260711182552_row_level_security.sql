-- RLS deny-by-default en todas las tablas (Fase 1, sección "RLS" del
-- encargo aprobado).
--
-- Decisión de arquitectura: en este proyecto NINGUNA tabla se consulta
-- directamente desde el navegador con la anon key. Toda la lectura y
-- escritura de datos de negocio pasa por Server Components, Server
-- Actions o Route Handlers usando la service role key (que bypassea RLS
-- por diseño de Supabase). La sesión de Supabase Auth (login de
-- admin/scanner) usa la anon key solo para el flujo de autenticación en
-- sí (`auth.*`), no para leer estas tablas.
--
-- Por lo tanto: se habilita RLS en cada tabla y NO se define ninguna
-- policy para `anon` ni `authenticated`. Sin policies, el resultado es
-- denegar todo acceso a esos roles — exactamente el comportamiento
-- buscado. `service_role` no está sujeto a RLS.
--
-- Se agrega además un REVOKE explícito de privilegios de tabla sobre
-- `anon`/`authenticated`, como segunda capa independiente de RLS: si en
-- el futuro alguien agrega una policy permisiva por error, el REVOKE
-- igual bloquea el acceso hasta que se otorgue un GRANT explícito y
-- deliberado junto con esa policy.
--
-- Si en una fase posterior se decide que el navegador debe leer datos
-- públicos (ej. listado de eventos) directamente vía Supabase en lugar
-- de vía Server Components, esa decisión debe registrarse en
-- DECISIONS.md y agregar acá una policy explícita y acotada (por
-- ejemplo, solo SELECT sobre `events` con `status = 'published'`).

do $$
declare
  t text;
begin
  for t in
    select unnest(array[
      'profiles',
      'events',
      'ticket_types',
      'orders',
      'stock_reservations',
      'order_items',
      'payment_attempts',
      'payments',
      'tickets',
      'access_logs',
      'webhook_events',
      'recovery_tokens',
      'email_logs',
      'admin_audit_logs'
    ])
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    -- Explícito y no solo asumido: en Supabase (cloud o `supabase start`
    -- local) `service_role` ya tiene privilegios completos sobre
    -- `public` por configuración de la plataforma. Se otorgan igual acá
    -- de forma explícita para que las migraciones sean reproducibles
    -- desde cero también en un Postgres self-hosted que no incluya ese
    -- bootstrapping de plataforma.
    execute format('grant all on public.%I to service_role', t);
  end loop;
end;
$$;

grant usage on schema public to service_role;
grant usage on schema extensions to service_role;

alter default privileges in schema public grant all on tables to service_role;
