# Arquitectura

## Visión general

Aplicación única (monolito) en Next.js App Router: un mismo proyecto
sirve la UI y el backend (Route Handlers, Server Actions). No hay
microservicios ni despliegues separados para el MVP — la separación es
por capas dentro del mismo proyecto, no por proceso.

```
app/            UI + Route Handlers (público, /admin, /scan, /api)
lib/domain/     Lógica de negocio pura, sin I/O, testeable sin infraestructura
lib/data/       Acceso a datos (Supabase, server-only, service role)
lib/payments/   Contrato PaymentProvider agnóstico + adapters por proveedor
lib/tickets/    Generación de QR y tokens
lib/email/      Envío de emails detrás de una interfaz EmailProvider
lib/auth/       Sesión y control de roles
lib/logging/    Logging estructurado
lib/config/     Lectura validada de variables de entorno
```

## Base de datos: Supabase / Postgres

- Región: São Paulo (`sa-east-1`), la más cercana a Argentina disponible en Supabase.
- Esquema versionado en `supabase/migrations/`, aplicado en orden por nombre (timestamp + descripción).
- Extensión `pgcrypto` (schema `extensions`) para `gen_random_uuid()` y `gen_random_bytes()`.

### Modelo de datos

Ver las migraciones en `supabase/migrations/20260711182551_schema_core.sql`
para el detalle completo de columnas, constraints e índices. Resumen de
tablas:

`profiles`, `events`, `ticket_types`, `orders`, `stock_reservations`,
`order_items`, `payment_attempts`, `payments`, `tickets`, `access_logs`,
`webhook_events`, `recovery_tokens`, `email_logs`, `admin_audit_logs`.

`orders` no tiene **ningún** campo específico de un proveedor de pagos
(ver "Arquitectura de pagos agnóstica al proveedor" más abajo y
DECISIONS.md). Esa relación vive en `payment_attempts` (la
sesión/intento iniciado con un proveedor) y `payments` (el hecho de
pago normalizado, ya confirmado o rechazado por el proveedor),
referenciando siempre `order_id`.

Decisiones de modelado no triviales están documentadas en `DECISIONS.md`
(reservas de stock, máquina de estados de `orders`, separación
`payment_attempts`/`payments`, dinero en centavos, tokens, política de
doble pago).

### Arquitectura de pagos agnóstica al proveedor

La lógica de dominio (órdenes, stock, reservas, entradas, QR, accesos)
no conoce Mercado Pago ni ningún otro proveedor de pagos concreto. El
único punto de contacto es el contrato `PaymentProvider` en
`lib/payments/types.ts`:

- `createPaymentSession` — inicia una sesión/preferencia/intento de pago.
- `getPaymentStatus` — re-consulta el estado real contra la API del proveedor (nunca se confía solo en un webhook).
- `verifyWebhookSignature` / `parseWebhookEvent` — validación y parseo específicos de cada proveedor.
- `initiateRefund` (opcional) — solo si `capabilities.programmaticRefunds` es `true`; ningún adapter del MVP lo implementa (los reembolsos son manuales, decisión de la Fase 0.1).

`MercadoPagoProvider` (Fase 3) será el primer adapter concreto — el
único lugar del código que importa el SDK de Mercado Pago. Un futuro
`BankTransferProvider` (no implementado, arquitectura preparada)
tendría `capabilities.instantConfirmation = false`: una orden pagada
por transferencia queda pendiente de verificación manual, no se asume
que todo pago es instantáneo. Ver el detalle de capacidades
obligatorias/opcionales y las diferencias documentadas entre
proveedores en los comentarios de `lib/payments/types.ts`.

Rutas de webhook por proveedor (Fase 3): `/api/webhooks/[provider]`.
Cada proveedor valida su propia firma/autenticación y parsea su propio
formato; la lógica posterior (normalización → `record_payment_and_confirm_order`)
es común a todos.

### Acceso a datos: RLS deny-by-default + service role

**Ninguna tabla se consulta directamente desde el navegador.** Todo el
acceso a datos de negocio pasa por Server Components, Server Actions o
Route Handlers usando `SUPABASE_SERVICE_ROLE_KEY` (que bypassea RLS).
Supabase Auth (login de `admin`/`scanner`) usa la anon key solo para el
flujo de autenticación en sí, no para leer tablas de negocio.

Por eso: RLS está habilitado en todas las tablas y no existen policies
para `anon`/`authenticated` (sin policies = acceso denegado). Además hay
un `REVOKE ALL` explícito sobre esos roles como segunda capa
independiente de RLS. Ver `supabase/migrations/20260711182552_row_level_security.sql`
y el detalle de amenaza/mitigación en `SECURITY.md`.

Si en una fase futura se decide leer datos públicos directamente desde
el navegador (ej. listado de eventos sin pasar por SSR), esa es una
decisión de arquitectura que debe registrarse en `DECISIONS.md` y
requiere agregar una policy explícita y acotada — no relajar el default.

### Operaciones atómicas críticas: funciones PostgreSQL (RPC), no transacciones desde JS

El SDK cliente de Supabase (`@supabase/supabase-js`) no ofrece una forma
segura de ejecutar una transacción multi-statement desde JavaScript
(cada `.from(...).select()/.insert()/.update()` es una llamada HTTP
independiente). Operaciones como "reservar stock", "convertir una
reserva en entradas" o "expirar reservas vencidas" necesitan leer,
decidir y escribir sobre varias tablas de forma atómica. Por eso están
implementadas como funciones PL/pgSQL en
`supabase/migrations/20260711182555_rpc_functions.sql`, invocadas desde
el backend vía RPC (`supabase.rpc(...)`) con la service role key. **Esta
lógica nunca se simula con múltiples llamadas independientes desde
TypeScript.**

Funciones RPC expuestas (`GRANT EXECUTE` solo a `service_role`):

| Función | Uso |
|---|---|
| `create_order_with_reservation` | Crea la orden + reserva stock de forma atómica. Precios siempre leídos server-side. Idempotente (ver DECISIONS.md). |
| `expire_stale_reservations` | Libera reservas `ACTIVE` vencidas y expira las órdenes correspondientes. Pensada para correr cada 1 min vía `pg_cron`. |
| `release_reservation_for_order` | Libera de inmediato la reserva de una orden (pago rechazado/cancelado, o cancelación manual). |
| `record_payment_and_confirm_order` | Punto de entrada único y agnóstico al proveedor al recibir un hecho de pago ya normalizado y verificado. Registra el pago (idempotente), implementa la política de "pago tardío", detecta doble pago y sincroniza reembolsos/chargebacks (ver DECISIONS.md). |
| `issue_tickets_after_review` | Resolución manual (fases posteriores) de una orden `PAID_REQUIRES_REVIEW` cuando se liberó capacidad. |
| `validate_ticket` | Validación atómica de QR en `/scan`. Un `UPDATE ... WHERE status = 'VALID'` garantiza que, ante dos escaneos concurrentes del mismo token, como máximo uno tenga éxito. |

Mecanismo de concurrencia: `SELECT ... FOR UPDATE` sobre la fila del
`ticket_type` involucrado, en un orden estable (por `id`) cuando hay
varios, para evitar deadlocks entre compras concurrentes. Para
decrementos/incrementos simples (liberar reservas, contador `reserved`)
se usa `UPDATE` relativo (`SET reserved = reserved - x`), que Postgres
serializa correctamente por fila sin necesidad de un lock explícito
adicional.

Estas funciones fueron verificadas manualmente contra un Postgres real
(ver nota sobre el entorno de desarrollo más abajo), incluyendo una
prueba de concurrencia real con dos procesos `psql` simultáneos
validando el mismo QR.

### Job programado: `pg_cron`

`expire_stale_reservations()` se programa cada 1 minuto vía Supabase
Cron / `pg_cron` (`supabase/migrations/20260711182557_pg_cron_expire_reservations.sql`),
no vía un cron externo pegándole a un endpoint HTTP. Corre dentro de
Postgres, sin necesidad de exponer ni autenticar un endpoint público
para esto.

## Dinero: enteros en centavos

Todos los importes se guardan como enteros en la unidad mínima de la
moneda (columnas `*_cents`, `integer`/`bigint`), nunca `numeric` ni
`float`. Se evita cualquier ambigüedad de redondeo entre Postgres,
TypeScript y la API de cualquier proveedor de pagos. El precio se lee siempre de
`ticket_types.price_cents` en el servidor al crear la orden — nunca se
confía en un precio enviado por el cliente.

## Variables de entorno

Centralizadas en `lib/config/env.ts`: cada variable se valida de forma
perezosa (recién al usarse), para que un subsistema no usado todavía
(ej. Mercado Pago en esta fase) no rompa el arranque de la app. Nunca se
lee `process.env` directamente fuera de ese módulo. Ver `.env.example`
para la lista completa y `SECURITY.md` para qué nunca debe llevar
`NEXT_PUBLIC_`.

## Nota sobre el entorno de desarrollo de esta fase

Este entorno de ejecución no tiene acceso al daemon de Docker, por lo
que no se pudo correr `supabase start` (el stack local completo de
Supabase) ni `supabase gen types typescript --db-url ...` (que también
depende de Docker). Para validar igualmente el esquema y las funciones
RPC de forma real (no solo revisión de sintaxis), se usó un Postgres 16
instalado directamente en el entorno, con un mock mínimo de los roles
(`anon`, `authenticated`, `service_role`) y el esquema `auth.users` que
Supabase provee de fábrica. Sobre esa base se aplicaron las migraciones
reales tal cual quedaron en `supabase/migrations/` y se ejecutaron
pruebas funcionales (creación de orden, idempotencia, sold-out,
expiración, pago tardío sin stock, doble escaneo concurrente, pago
rechazado con liberación inmediata, doble pago real de dos proveedores
distintos para la misma orden, sincronización de reembolso con cascada
a las entradas). El resultado de esas pruebas está en los informes de
cierre de la Fase 1 y de su corrección posterior.

`lib/data/database.types.ts` se escribió a mano a partir de las
migraciones por el mismo motivo (no se pudo generar con el CLI). Debe
regenerarse con `supabase gen types typescript --linked` en cuanto
exista un proyecto Supabase real vinculado.
