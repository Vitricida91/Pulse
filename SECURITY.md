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
`confirm_order_paid`, `validate_ticket`, etc.) tienen `EXECUTE` revocado
de `PUBLIC` y otorgado únicamente a `service_role` — no son invocables
por el cliente vía PostgREST.

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

## Datos de Mercado Pago: minimización

`payments` guarda únicamente campos reales y acotados de la API de
pagos de Mercado Pago (id externo, estado, detalle de estado, monto,
moneda, medio de pago, referencia externa) — nunca el payload completo
del pago como blob. `webhook_events.payload` sí guarda el payload
completo de la notificación recibida (necesario para auditoría e
idempotencia de webhooks), pero es un registro interno de
infraestructura, no expuesto a ningún rol de cliente (mismo RLS
deny-by-default) y candidato a política de retención/purga cuando se
implementen los webhooks reales en la Fase 3.

## Verificación de webhooks (Fase 3)

Los webhooks de Mercado Pago se verifican con la firma del header
`x-signature` (`ts` + `v1`, HMAC-SHA256 con `MERCADOPAGO_WEBHOOK_SECRET`)
antes de procesar cualquier notificación. El estado del pago **siempre**
se re-confirma contra la API de Mercado Pago (`GET /v1/payments/{id}`)
— nunca se confía únicamente en el contenido del webhook ni en que el
navegador haya vuelto a una URL de éxito. Idempotencia garantizada por
el constraint único `(provider, external_event_id)` en `webhook_events`.

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
