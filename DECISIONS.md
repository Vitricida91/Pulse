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

## Corrección post-Fase 1: arquitectura de pagos agnóstica al proveedor

**Contexto:** el modelo de la Fase 1 acopló `orders` directamente a
Mercado Pago (`orders.mercado_pago_preference_id`) y usó un
`payment_status` que era literalmente el vocabulario de estados de la
API de pagos de Mercado Pago. Esto es incorrecto: Mercado Pago es el
primer proveedor integrado, no el único que la plataforma va a soportar
nunca. Se corrige antes de construir Fase 2/3 sobre esa base, editando
directamente las migraciones de la Fase 1 (no apilando una migración
correctiva) porque, a la fecha de esta corrección, ningún entorno real
las tiene aplicadas todavía — ver la nota de verificación sin Docker más
arriba. Si en el futuro hiciera falta corregir algo ya aplicado a un
proyecto real, el camino correcto sería una migración nueva, no editar
una ya aplicada.

### `PaymentProvider`: contrato agnóstico, no una interfaz rígida

**Decisión:** `lib/payments/types.ts` define el contrato que cualquier
adapter de proveedor debe cumplir (`createPaymentSession`,
`getPaymentStatus`, `verifyWebhookSignature`, `parseWebhookEvent`) más
un objeto `capabilities` (`instantConfirmation`, `refundNotifications`,
`programmaticRefunds`) y un método opcional (`initiateRefund`, solo
si `programmaticRefunds` es `true`). La lógica de negocio nunca importa
un SDK de proveedor concreto; solo estos tipos.

**Motivo de no unificar todo en una interfaz rígida:** proveedores
reales difieren de forma genuina, no solo en detalles de implementación.
Una transferencia bancaria no tiene "sesión" en el sentido de Mercado
Pago, no confirma instantáneamente y no tiene webhook real. Forzar a
todos los adapters a implementar exactamente lo mismo hubiese llevado a
métodos vacíos o a mentir sobre capacidades que un proveedor no tiene.
Las diferencias conocidas/previstas entre `MercadoPagoProvider` (Fase 3)
y un futuro `BankTransferProvider` (no implementado) están documentadas
en los comentarios de `lib/payments/types.ts`.

### Modelo de datos: `payment_attempts` + `payments`, no acoplado a ningún proveedor

**Decisión:** dos tablas con responsabilidades distintas:

- **`payment_attempts`**: la sesión/intento iniciado con un proveedor
  (equivalente genérico a una "preferencia" de Mercado Pago), creada
  *antes* de que exista cualquier pago confirmado. `provider` es
  `text`, no un enum, para que agregar un proveedor nuevo no requiera
  una migración que extienda un tipo de Postgres. `external_session_id`
  es nullable porque no todos los proveedores tienen concepto de
  sesión (ej. una transferencia bancaria).
- **`payments`**: el hecho de pago normalizado ya reportado por un
  proveedor (aprobado, rechazado, reembolsado, etc.), con
  `payment_attempt_id` nullable (un pago puede llegar sin que hayamos
  registrado antes su sesión) y `external_reference` (el identificador
  que le pasamos al proveedor para que nos lo devuelva intacto —
  en general el propio `order_id` — mecanismo agnóstico preferido para
  resolver a qué orden pertenece un pago).

**Alternativas consideradas:**
- **A. `payment_sessions` separada de `payments`, sin más:** válida,
  pero no distinguía claramente el caso de un pago que llega sin sesión
  previa conocida (por eso `payment_attempt_id` es nullable en vez de
  obligatorio).
- **B. Incorporar la sesión dentro de `payments`:** mezcla dos
  conceptos con ciclos de vida distintos (una sesión puede no derivar
  nunca en un pago; un pago siempre referencia, cuando existe, la
  sesión de la que vino) en una sola fila, complicando el modelo de
  estados de ambos.
- **C. `payment_attempts` + `payments` (elegida):** separa "intención de
  pago" de "hecho de pago", cada una con su propia máquina de estados
  (`payment_attempt_status` vs `payment_status`), y permite que un pago
  se resuelva sin depender de haber trackeado su sesión.

`orders` no gana ningún campo nuevo por esto — sigue sin conocer nada
de pagos, tal como estaba pensado desde la Fase 0.1, solo que ahora esa
separación es real y no rota por `mercado_pago_preference_id`.

### Estados normalizados de pago

**Decisión:** `payment_status` pasa a ser un enum genérico —
`PENDING`, `IN_PROGRESS`, `APPROVED`, `REJECTED`, `CANCELLED`,
`REFUNDED`, `CHARGED_BACK` — en vez del vocabulario literal de Mercado
Pago. Cada adapter normaliza su propio estado a uno de estos. Mapeo
documentado para `MercadoPagoProvider` (a implementar en la Fase 3):

| Estado de Mercado Pago | Estado interno |
|---|---|
| `pending` | `PENDING` |
| `in_process` | `IN_PROGRESS` |
| `authorized` | `IN_PROGRESS` |
| `in_mediation` | `IN_PROGRESS` (el detalle se conserva en `raw_provider_status`) |
| `approved` | `APPROVED` |
| `rejected` | `REJECTED` |
| `cancelled` | `CANCELLED` |
| `refunded` | `REFUNDED` |
| `charged_back` | `CHARGED_BACK` |

### Política de doble pago

**Decisión:** `record_payment_and_confirm_order` es el único punto de
entrada para registrar un hecho de pago y decidir qué hacer con la
orden. Si llega un pago `APPROVED` para una orden que **ya** está
`PAID`/`PAID_REQUIRES_REVIEW`, la función distingue dos casos:

1. **Reintento del mismo pago** (mismo `(provider, external_payment_id)`,
   ej. reintento de webhook): `INSERT ... ON CONFLICT`-equivalente
   idempotente, no pasa nada más. No es un doble pago.
2. **Un pago genuinamente distinto** (otro `external_payment_id`, del
   mismo proveedor o de uno diferente): se marca ese pago
   `reconciliation_status = 'DUPLICATE_REQUIRES_REFUND'`, se registra en
   `admin_audit_logs` (acción `duplicate_payment_detected`, con el
   pago anterior referenciado), y **no** se emiten entradas de más ni se
   cambia el estado de la orden (la orden ya estaba correctamente
   cumplida por el primer pago). La resolución (reembolsar el pago
   duplicado) queda para un admin, vía el proveedor correspondiente —
   consistente con la decisión de la Fase 0.1 de no automatizar
   reembolsos en el MVP.

**Por qué a nivel de `payments` y no de `orders`:** una orden con un
pago duplicado sigue absolutamente bien desde el punto de vista de
cumplimiento (el comprador tiene sus entradas); lo que está mal es
puramente financiero (se le cobró de más). Mezclar esto con el estado
de `orders` (pensado para el ciclo de vida de cumplimiento:
pendiente/pagada/requiere revisión/cancelada/reembolsada) hubiese
confundido dos preguntas distintas ("¿la orden está resuelta?" vs
"¿hay un excedente de dinero que reconciliar?").

**Verificado:** contra Postgres real — un pago aprobado de Mercado Pago
seguido de un segundo pago aprobado de un proveedor distinto
(`bank_transfer`) para la misma orden. Resultado: 1 sola entrada
emitida, segundo pago marcado `DUPLICATE_REQUIRES_REFUND`, entrada en
`admin_audit_logs`. También se verificó el reintento idempotente del
mismo pago (no duplica entradas) y la sincronización de un reembolso
reportado por el proveedor sobre una orden ya `PAID` (cascada a
`REFUNDED` en la orden y en las entradas todavía `VALID`, sin tocar
entradas ya `USED`).

### `provider` como `text`, no enum

**Decisión:** tanto `payment_attempts.provider` como `payments.provider`
son `text` con `check (provider <> '')`, no un tipo enum de Postgres.

**Motivo:** agregar un proveedor nuevo (un adapter nuevo en
`lib/payments/`) no debería requerir una migración de base de datos
que extienda un enum — la validación del conjunto de proveedores
soportados vive en el código (el tipo `ProviderId` de
`lib/payments/types.ts`), no en una constraint de Postgres que hay que
migrar cada vez.
