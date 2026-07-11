-- Mantiene `updated_at` sincronizado automáticamente en cada UPDATE,
-- para las tablas que lo tienen.

create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger events_set_updated_at
  before update on public.events
  for each row
  execute function public.set_updated_at();

create trigger ticket_types_set_updated_at
  before update on public.ticket_types
  for each row
  execute function public.set_updated_at();

create trigger orders_set_updated_at
  before update on public.orders
  for each row
  execute function public.set_updated_at();

create trigger payment_attempts_set_updated_at
  before update on public.payment_attempts
  for each row
  execute function public.set_updated_at();

create trigger payments_set_updated_at
  before update on public.payments
  for each row
  execute function public.set_updated_at();
