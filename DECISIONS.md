# Registro de decisiones de arquitectura

Formato: decisión, contexto, alternativas consideradas, motivo. Se
agregan entradas nuevas al final de la sección de la fase
correspondiente; no se reescribe el historial.

## Fase 0

### Stack

Next.js (App Router) + TypeScript estricto + Tailwind CSS + Supabase
(Postgres + Auth) + Mercado Pago Checkout Pro + Resend + Vercel. Sin
alternativa significativamente mejor identificada para el tamaño y
plazo de este proyecto; ver análisis completo en la respuesta de
Fase 0.

### Arquitectura: monolito Next.js, no microservicios

**Decisión:** una única aplicación Next.js sirve frontend y backend
(Route Handlers, Server Actions), organizada en capas (`lib/domain`,
`lib/data`, `lib/payments`, `lib/tickets`, `lib/email`, `lib/auth`)
dentro del mismo proceso/deploy.

**Motivo:** el volumen esperado (cientos a pocos miles de entradas por
evento) no justifica la complejidad operativa de microservicios.
Separar por capas (no por proceso) da la mayoría del beneficio de
mantenibilidad sin el costo de infraestructura distribuida, y no cierra
la puerta a extraer un servicio después si hiciera falta.

### Cada función/fecha es un `event` independiente

**Decisión:** no existe todavía una entidad `show`/`production`
superior. Cada fecha concreta (ej. Córdoba 10/10, Mendoza 15/11) es un
`event` independiente con su propio `slug`, capacidad y tipos de
entrada.

**Motivo:** simplicidad para el MVP (un solo show, fechas todavía no
confirmadas más allá de la primera). El modelo no impide agregar una
tabla `productions` en el futuro con `events.production_id` opcional.

## Fase 0.1

### Modelo de reservas de stock: híbrido

**Decisión:** `stock_reservations` es la fuente de verdad de cada
reserva individual (una fila por orden/tipo de entrada, con estados
`ACTIVE`/`RELEASED`/`EXPIRED`/`CONVERTED`). `ticket_types.reserved` y
`ticket_types.sold` son contadores **derivados**, mantenidos en la
misma transacción que su fuente, nunca escritos de forma independiente.

**Alternativas consideradas:**
- **A. Solo un contador `reserved` en `ticket_types`:** simple pero
  impide saber de qué orden es cada porción reservada, lo que a su vez
  impide liberar exactamente lo vencido y auditar inconsistencias sin
  terminar reconstruyendo, en los hechos, una tabla de reservas mal
  modelada.
- **B. Solo la tabla `stock_reservations`, sin contador cacheado:**
  correcto pero obliga a un `SUM()` en cada lectura de disponibilidad.
- **C. Híbrido (elegido):** trazabilidad completa + lecturas rápidas.

**Mecanismo de concurrencia:** `SELECT ... FOR UPDATE` sobre la fila
del `ticket_type` durante la creación/conversión de una reserva (lee un
agregado y decide antes de escribir, necesita el lock); `UPDATE`
relativo simple para liberaciones/expiraciones (no necesita lock
explícito, Postgres lo serializa por fila).

### Política de "pago aprobado después de expirar una reserva" (late payment)

**Decisión:** al confirmar un pago aprobado, si la reserva original ya
expiró, el sistema intenta "rescatar" la conversión verificando
capacidad real en ese momento (`capacity - reserved - sold`). Si hay
capacidad, emite las entradas normalmente. Si no la hay, la orden pasa
a `PAID_REQUIRES_REVIEW`, no se emite ninguna entrada, y el caso queda
registrado en `admin_audit_logs` para resolución manual. El pago
siempre se registra en `payments`, nunca se pierde.

**Motivo:** cumplir los cuatro principios acordados — un pago aprobado
nunca se pierde ni se ignora; una entrada nunca se emite sin capacidad
real verificada; el caso queda auditado; el sistema distingue
`PAID` de `PAID_REQUIRES_REVIEW`.

**Implementación:** `confirm_order_paid()` e `issue_tickets_after_review()`
comparten la lógica de intento de emisión (`_try_issue_tickets_for_order`,
interna, no expuesta vía RPC), que recalcula la factibilidad a partir de
`order_items` (qué se compró realmente) en vez de depender de que la
reserva siga viva.

### Máquina de estados de `orders`

**Decisión:** `PENDING_PAYMENT → {PAID, PAID_REQUIRES_REVIEW, CANCELLED, EXPIRED}`;
`EXPIRED → {PAID, PAID_REQUIRES_REVIEW}` (pago tardío); `PAID_REQUIRES_REVIEW → {PAID, REFUNDED}`
(resolución manual); `PAID → REFUNDED`. `CANCELLED` y `REFUNDED` son
terminales.

**Motivo de separar `CANCELLED` de `EXPIRED`:** `CANCELLED` es una señal
explícita (rechazo/cancelación informado por Mercado Pago, o
cancelación manual) que libera la reserva de inmediato, sin esperar el
TTL. `EXPIRED` es la vía pasiva (nadie informó nada, venció el tiempo).
Separarlos mejora la experiencia (el stock vuelve antes) y la
trazabilidad.

### `payments` como tabla independiente de `orders`

**Decisión:** los datos de Mercado Pago (`external_payment_id`,
`status`, `amount_cents`, etc.) viven en una tabla `payments`
independiente, no como columnas de `orders`. `orders` conserva
`mercado_pago_preference_id` (1:1 con la orden, se crea antes de que
exista cualquier pago).

**Alternativas consideradas:**
- **A. Campos de Mercado Pago directamente en `orders`:** solo puede
  representar el último intento de pago; pierde el historial si hay un
  rechazo seguido de un reintento.
- **B. Tabla `payments` (elegida):** una orden puede tener cero, uno o
  varios intentos de pago a lo largo del tiempo. Permite que un
  `payment` esté `approved` mientras la `order` está
  `PAID_REQUIRES_REVIEW` — exactamente la distinción que necesita la
  política de pago tardío. También separa `order`/`payment` de un
  eventual `invoice` futuro (facturación, fuera de alcance del MVP pero
  sin bloquear su incorporación posterior).

### Región de Supabase

**Decisión:** São Paulo, identificador real `sa-east-1` (verificado
contra la documentación oficial de regiones de Supabase, no asumido).

### Expiración de reservas: `pg_cron`, cada 1 minuto

**Decisión:** `expire_stale_reservations()` programada con Supabase
Cron / `pg_cron` en vez de un cron externo (ej. Vercel Cron) golpeando
un endpoint HTTP.

**Motivo:** corre dentro de Postgres, sin necesidad de exponer ni
autenticar un endpoint público solo para esto, sin latencia de red
adicional, y sin depender de que un servicio externo dispare la
invocación a tiempo.

### Máximo de entradas por orden: configurable, default 6

**Decisión:** `ticket_types.max_per_order`, columna configurable por
tipo de entrada desde el panel admin, con default `6`. No hardcodeado
como valor universal en la lógica de negocio.

### Teléfono del comprador: opcional

**Decisión:** `orders.buyer_phone` nullable. Único uso previsto: que un
admin pueda contactar al comprador en un caso `PAID_REQUIRES_REVIEW`.
Fuera de ese caso, no se usa. No se solicita DNI, dirección ni fecha de
nacimiento.

## Fase 1

### Idempotencia de `create_order_with_reservation`: fingerprint canónico, no solo la clave del cliente

**Decisión:** además de la `idempotency_key` (única, provista por el
cliente), el servidor calcula un `request_fingerprint`
(`sha256` sobre una representación canónica y normalizada de
comprador + ítems, ordenados). Un reintento con la misma clave y el
mismo fingerprint devuelve la orden existente; la misma clave con un
fingerprint distinto se rechaza como conflicto
(`IDEMPOTENCY_KEY_CONFLICT`).

**Motivo:** una `idempotency_key` sola no protege contra un bug de
cliente (o un intento malicioso) que reutilice la misma clave para una
compra distinta. El fingerprint se calcula en el servidor a partir de
datos ya validados server-side, nunca de un total enviado por el
cliente.

**Verificado:** ver informe de cierre de la Fase 1 — prueba con la
misma clave y mismo payload (devuelve la orden existente) y con la
misma clave y payload distinto (rechaza con conflicto).

### Precio siempre server-side

**Decisión:** `create_order_with_reservation` recibe `ticket_type_id` +
`quantity` por ítem, nunca un precio. `unit_price_cents` y
`total_amount_cents` se calculan leyendo `ticket_types.price_cents` en
el momento, dentro de la misma transacción que valida stock.

### Dinero: enteros en centavos, no `numeric` ni `float`

**Decisión:** todas las columnas monetarias son enteros en la unidad
mínima de la moneda (`price_cents`, `unit_price_cents`,
`total_amount_cents`, `amount_cents`), tipo `integer`/`bigint`.

**Alternativas consideradas:**
- `numeric(12,2)` en Postgres: exacto, pero exige una estrategia
  paralela y disciplinada en TypeScript para no introducir errores de
  redondeo al convertir hacia/desde la API de Mercado Pago (que trabaja
  con decimales).
- `float`/`number` de punto flotante para cálculos: descartado de
  entrada, es exactamente lo que se pidió evitar.
- **Enteros en centavos (elegido):** aritmética exacta en ambas capas
  (Postgres y TypeScript) sin ambigüedad de redondeo. La conversión
  a/desde el formato decimal de la API de Mercado Pago ocurre en un
  único punto de la capa `lib/payments/` (Fase 3), no dispersa por el
  código.

### Datos de Mercado Pago guardados: campos sanitizados, no el payload completo

**Decisión:** `payments` guarda solo campos reales y acotados de la API
de pagos (`external_payment_id`, `status`, `status_detail`,
`amount_cents`, `currency`, `payment_method`, `external_reference`),
nunca el objeto de pago completo. El payload completo de la
**notificación del webhook** sí se guarda en `webhook_events.payload`
(jsonb), porque ahí su propósito es auditoría/idempotencia de
infraestructura, con RLS deny-by-default y sin exposición a ningún rol
de cliente.

**Motivo:** minimización de datos (evitar guardar campos redundantes o
irrelevantes de la respuesta de Mercado Pago) sin perder lo necesario
para auditoría, debugging, conciliación y soporte.

### RLS deny-by-default + acceso exclusivamente server-side

**Decisión:** RLS habilitado en las 13 tablas, sin policies para
`anon`/`authenticated` (denegación por ausencia de policy) más un
`REVOKE ALL` explícito como segunda capa. Toda la app lee/escribe con
`service_role` desde el servidor.

**Motivo:** ninguna pantalla de este MVP necesita que el navegador
consulte Supabase directamente — todo pasa por Server Components/Route
Handlers. Evita depender de policies RLS bien escritas para cada caso
de uso público; si en el futuro se necesita lectura directa desde el
cliente, es una decisión explícita a registrar acá, no el default.

**Verificado:** ver informe de cierre — `anon` recibe `permission
denied` tanto sobre tablas como sobre las funciones RPC; `service_role`
accede con normalidad.

### Operaciones críticas como funciones PL/pgSQL (RPC), no transacciones simuladas desde JS

**Decisión:** `create_order_with_reservation`, `expire_stale_reservations`,
`release_reservation_for_order`, `confirm_order_paid`,
`issue_tickets_after_review` y `validate_ticket` son funciones
PostgreSQL, invocadas vía RPC. Nunca se implementan como una secuencia
de llamadas independientes del SDK cliente de Supabase desde
TypeScript.

**Motivo:** el SDK cliente de Supabase no soporta transacciones
multi-statement seguras. Las funciones PL/pgSQL corren dentro de una
única transacción de Postgres con los locks que necesitan.

### Token del QR: opaco, aleatorio, sin datos embebidos (confirma decisión previa)

**Decisión final:** `gen_random_bytes(32)` codificado en hex (256 bits
de entropía), sin estructura, sin JWT, sin datos personales ni precio
ni ID incremental. Se eligió hex (64 caracteres) sobre una codificación
más corta (base62/base58) por simplicidad de implementación sin
dependencias adicionales y porque el tamaño resultante es intrascendente
para la capacidad de un QR.

### Enlaces de recuperación: se guarda el hash del token, no el token

**Decisión:** `recovery_tokens.token_hash` guarda un hash, nunca el
token en texto plano — mismo criterio que un reset de contraseña. Es
una decisión distinta a la del token del QR a propósito: el QR es un
bearer token físico escaneado en la puerta (un volcado de base de datos
ya sería catastrófico para ambos casos por igual), mientras que el
enlace de recuperación viaja por email y tiene un modelo de amenaza más
cercano al de un reset de contraseña.

### Verificación de migraciones sin Docker

**Contexto:** este entorno de ejecución no tiene acceso al daemon de
Docker, por lo que `supabase start` y `supabase gen types` (ambos
dependen de contenedores) no están disponibles.

**Decisión:** se instaló Postgres 16 directamente en el entorno y se
construyó un mock mínimo de roles (`anon`, `authenticated`,
`service_role`) y del esquema `auth.users` que Supabase provee de
fábrica, únicamente para poder aplicar las migraciones reales
(sin modificarlas) y ejecutar pruebas funcionales reales: creación de
orden, idempotencia (mismo payload / payload distinto), sold-out,
expiración de reservas, pago tardío sin stock disponible
(`PAID_REQUIRES_REVIEW`), resolución manual tras liberar stock, y doble
escaneo concurrente del mismo QR con dos procesos `psql` en paralelo.

`lib/data/database.types.ts` se escribió a mano a partir de las
migraciones, en vez de generarse con `supabase gen types` (que también
requiere Docker). Debe regenerarse apenas exista un proyecto Supabase
real vinculado.

**Pendiente para el usuario:** correr `npx supabase start` (con Docker
disponible) o crear un proyecto Supabase real y correr
`npx supabase db push` / vincular el proyecto, para validar en el stack
real de Supabase (incluyendo `pg_cron`, que tampoco está disponible en
un Postgres genérico sin el módulo precompilado).
