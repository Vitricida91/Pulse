# Seguridad

## Secretos y variables de entorno

Nunca se envían al navegador:

- `SUPABASE_SERVICE_ROLE_KEY`
- `MERCADOPAGO_ACCESS_TOKEN`
- `MERCADOPAGO_WEBHOOK_SECRET`
- `RESEND_API_KEY`

Ninguna de estas variables lleva el prefijo `NEXT_PUBLIC_`. Se leen
exclusivamente a través de `lib/config/env.ts`, importado solo desde
código server-only.

`lib/data/supabase-admin.ts` (el único punto de la app que usa la
service role key) importa el paquete [`server-only`](https://www.npmjs.com/package/server-only):
si algún día se importa, directa o indirectamente, desde un Client
Component, el build de Next.js falla explícitamente en vez de filtrar
el secreto al bundle del navegador.

`.env.local` está en `.gitignore`. Solo `.env.example` (sin secretos
reales, con nombres de variable y placeholders) se commitea.

## Control de acceso a datos: RLS deny-by-default

Todas las tablas tienen Row Level Security habilitado y **ninguna**
tiene policies para `anon`/`authenticated` — el resultado por diseño es
denegar todo acceso a esos roles. Además hay un `REVOKE ALL` explícito
como segunda capa independiente de RLS. El acceso real a datos de
negocio ocurre siempre server-side con la service role key.

Las funciones RPC críticas (`create_order_with_reservation`,
`record_payment_and_confirm_order`, `validate_ticket`, etc.) tienen
`EXECUTE` revocado de `PUBLIC` y otorgado únicamente a `service_role` —
no son invocables por el cliente vía PostgREST.

Ver el razonamiento completo en `ARCHITECTURE.md` y en `DECISIONS.md`.

## Control de acceso por rol (aplicación)

- **Admin** y **scanner** son cuentas individuales de Supabase Auth
  (`profiles.role`). El personal de acceso nunca comparte una
  contraseña entre dispositivos.
- Las rutas `/admin/*` y `/scan` requieren sesión válida y el rol
  correspondiente, verificado del lado del servidor (no solo ocultando
  UI en el cliente). Se implementa en la Fase 2.

## Tokens

### QR de las entradas (`tickets.public_token`)

Token opaco aleatorio de 256 bits (`gen_random_bytes(32)` codificado en
hex), sin ninguna estructura ni dato embebido. El QR **no contiene**
nombre, email, precio ni un ID incremental — solo este token, que sirve
para buscar el estado de la entrada en el servidor. No es un JWT ni un
token firmado: ver la justificación en `DECISIONS.md`.

### Enlaces de recuperación de entradas (`recovery_tokens`)

Se guarda el **hash** del token (no el token en texto plano), igual que
un reset de contraseña: si la base de datos se filtra, los enlaces ya
emitidos no sirven para nada. Los tokens son de un solo uso y expiran.
El endpoint de recuperación responde siempre el mismo mensaje neutral
("si existen entradas asociadas a ese correo, vas a recibir un
enlace"), para no permitir enumerar qué emails tienen compras. Rate
limiting sobre este endpoint se agrega en la Fase 6, antes de exponerlo
en producción.

## Pagos: agnóstico al proveedor, datos sanitizados, sin datos de tarjeta

La aplicación nunca recibe ni almacena número completo de tarjeta, CVV,
ni ninguna credencial de billetera virtual — esos datos los procesa
exclusivamente el proveedor de pagos (Mercado Pago u otro). El dominio
de la ticketera solo conoce: qué orden se pagó, por qué monto, en qué
moneda, el estado normalizado, el proveedor, el tipo general de medio
de pago (`payment_method_type`: tarjeta de crédito/débito, billetera
virtual, transferencia, efectivo, otro) y el identificador externo
necesario para conciliación. Ver el contrato `PaymentProvider` en
`lib/payments/types.ts` y "Arquitectura de pagos agnóstica al
proveedor" en `ARCHITECTURE.md`.

`payments` guarda únicamente campos genéricos y acotados
(`external_payment_id`, `status`, `raw_provider_status`, monto, moneda,
`payment_method_type`, `external_reference`) — nunca el payload
completo de un pago como blob, y nunca un campo con el nombre de una
API de un proveedor específico. `webhook_events.payload` sí guarda el
payload completo de la notificación recibida (necesario para auditoría
e idempotencia de webhooks de cualquier proveedor), pero es un registro
interno de infraestructura, no expuesto a ningún rol de cliente (mismo
RLS deny-by-default) y candidato a política de retención/purga cuando
se implementen los webhooks reales en la Fase 3.

## Doble pago de una misma orden

Si dos hechos de pago **distintos** (mismo proveedor dos veces, o dos
proveedores diferentes) resultan aprobados para la misma orden,
`record_payment_and_confirm_order` detecta que la orden ya fue resuelta
por un pago anterior, marca el segundo pago
`reconciliation_status = 'DUPLICATE_REQUIRES_REFUND'` y lo audita en
`admin_audit_logs` — nunca emite entradas de más ni cambia el estado de
la orden. La resolución (reembolsar el pago duplicado) es manual desde
el panel admin. Ver el detalle de la política y por qué en
`DECISIONS.md`.

## Verificación de webhooks (Fase 3)

Cada proveedor tiene su propia ruta de webhook
(`/api/webhooks/[provider]`), su propia verificación de firma/autenticación
y su propio parser — la normalización a `NormalizedPaymentFact` y todo
lo posterior (`record_payment_and_confirm_order`) es común. Para
Mercado Pago específicamente: firma del header `x-signature` (`ts` +
`v1`, HMAC-SHA256 con `MERCADOPAGO_WEBHOOK_SECRET`) antes de procesar
cualquier notificación. El estado del pago **siempre** se re-confirma
contra la API del proveedor (`GET /v1/payments/{id}` en el caso de
Mercado Pago) — nunca se confía únicamente en el contenido del webhook
ni en que el navegador haya vuelto a una URL de éxito. Idempotencia
garantizada por el constraint único `(provider, external_event_id)` en
`webhook_events` (a nivel de notificación) y `(provider,
external_payment_id)` en `payments` (a nivel de hecho de pago).

## Minimización de datos personales

Datos obligatorios del comprador: nombre y email. Teléfono es opcional.
No se solicita DNI, dirección ni fecha de nacimiento. `access_logs` no
guarda IP de los asistentes.

## Rate limiting (Fase 6)

Pendiente de implementar sobre: creación de orden, webhook de Mercado
Pago, recuperación de entradas y validación de QR. Elección de
herramienta y justificación en `DECISIONS.md`.

## Auditoría

- `admin_audit_logs`: acciones administrativas (crear/editar evento,
  cancelar entrada, resolución de `PAID_REQUIRES_REVIEW`, corridas del
  job de expiración con conteo).
- `access_logs`: cada intento de validación de QR en la puerta,
  exitoso o no, con el resultado y quién/qué dispositivo lo hizo.
- `webhook_events`: cada notificación entrante de Mercado Pago, válida
  o no, procesada o no.
