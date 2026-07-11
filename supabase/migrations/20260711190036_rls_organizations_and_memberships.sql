-- RLS deny-by-default para las tablas nuevas de la Revisión
-- Arquitectónica 1.1, mismo patrón que
-- `20260711182552_row_level_security.sql`: RLS habilitado, sin policies
-- para `anon`/`authenticated` (deny-by-default), `REVOKE ALL` explícito
-- como segunda capa, y `GRANT` explícito a `service_role`.
--
-- No se crea ninguna policy permisiva: el hecho de que ahora exista
-- `organization_memberships` no cambia el principio de acceso
-- server-side exclusivo establecido en la Fase 1. La autorización
-- contextual (organización + membresía activa + rol) se implementa en
-- código de aplicación en la Fase 2, no como policies de Postgres
-- todavía — ver ARCHITECTURE.md, "Aislamiento de datos (futuro)".

do $$
declare
  t text;
begin
  for t in
    select unnest(array[
      'organizations',
      'organization_memberships'
    ])
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end;
$$;
