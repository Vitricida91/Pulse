-- Programa expire_stale_reservations() cada 1 minuto vía Supabase
-- Cron / pg_cron (Fase 0.1, decisión aprobada).
--
-- pg_cron no está disponible en todos los entornos de Postgres (no
-- existe, por ejemplo, en una instalación local sin el módulo
-- precompilado). Esta migración detecta si la extensión está
-- disponible y, si no lo está, se omite con un aviso en vez de romper
-- el resto de las migraciones.
--
-- PASO MANUAL DOCUMENTADO: en algunos proyectos de Supabase, habilitar
-- pg_cron por primera vez puede requerir hacerlo desde el Dashboard
-- (Database > Extensions) si el rol usado para correr las migraciones
-- no tiene privilegio para crear la extensión. Si esta migración no
-- logra crear el cron job automáticamente, habilitar "pg_cron" desde el
-- Dashboard y volver a aplicar esta migración.

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron with schema pg_catalog';

    perform cron.schedule(
      'expire-stale-reservations',
      '* * * * *',
      $job$ select public.expire_stale_reservations(); $job$
    );
  else
    raise notice 'pg_cron no está disponible en este entorno de Postgres; se omite la programación automática. Ver DECISIONS.md.';
  end if;
end;
$$;
