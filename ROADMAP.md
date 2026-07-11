# Roadmap

## Fase 0 — Análisis y arquitectura ✅

Análisis crítico de requisitos, stack definitivo, modelo de datos
inicial, estructura del proyecto, definición del MVP. Aprobada.

## Fase 0.1 — Revisión de reservas, pagos y máquina de estados ✅

Modelo definitivo de reservas de stock (híbrido: `stock_reservations`
como fuente de verdad + contadores derivados en `ticket_types`),
política de "pago aprobado después de expirar una reserva", máquina de
estados de `orders`, decisión de crear `payments` como tabla
independiente, modelo de datos definitivo, flujo transaccional exacto.
Aprobada.

## Fase 1 — Inicialización del proyecto ✅

Proyecto Next.js + TypeScript estricto + Tailwind + ESLint. Estructura
de carpetas. `.env.example` y manejo de configuración. Migraciones SQL
completas (esquema, RLS deny-by-default, funciones RPC atómicas,
`pg_cron`). Cliente Supabase server-only. Página de verificación de
salud. Documentación inicial. Ver informe de cierre para el detalle.

## Fase 1.1 — Arquitectura de pagos agnóstica al proveedor ✅

Eliminación del acoplamiento directo con Mercado Pago del modelo de
dominio. `payment_attempts`/`payments` provider-agnósticas, estados de
pago normalizados, detección de doble pago, contrato TypeScript
`PaymentProvider` sin importar ningún SDK concreto. Ver DECISIONS.md.

## Fase 1.2 — Revisión Arquitectónica 1.1 (SaaS-ready, no SaaS-yet) ✅

`organizations` como raíz de pertenencia, `events.organization_id` y
`orders.event_id` obligatorios (con la integridad de "una orden, un
evento" garantizada server-side), `organization_memberships` como
fuente de verdad de autorización reemplazando el rol global
`profiles.role`. Sin ninguna funcionalidad multi-organizador real
todavía — ver "Future Product Evolution" más abajo. Ver DECISIONS.md.

## Fase 1.5 — Primer preview deployment ✅

Proyecto conectado a Vercel y desplegado desde la rama
`claude/event-ticketing-platform-3h0ki3`, sin ninguna variable de
entorno configurada (no hacía falta ninguna para este alcance). Página
temporal de verificación en `/`. Confirmado accesible y correcto por el
usuario en su navegador: https://22954534.vercel.app/

Nota para antes de la Fase 3/7: no pude verificar la URL de forma
independiente desde este entorno (tanto el proxy de red de este entorno
como la herramienta de fetch propia recibieron `403 Forbidden` al
intentar acceder de forma anónima). Es compatible con que Vercel tenga
activada la protección de deployment (SSO/contraseña) por defecto en
previews, lo cual bloquearía a cualquiera sin sesión en la cuenta de
Vercel del proyecto — hay que confirmarlo y, si corresponde,
desactivarlo específicamente para el entorno de Producción antes de la
Fase 7, ya que los webhooks de Mercado Pago necesitan poder alcanzar la
URL sin autenticación de Vercel de por medio.

## Fase 2 — Eventos y administración (próxima)

- Autenticación (Supabase Auth) y control de acceso por rol server-side.
- Panel administrativo: CRUD de eventos, tipos de entrada.
- Gestión de cuentas de personal de acceso (scanner).

## Fase 3 — Compra y Mercado Pago

- Formulario de compra (guest checkout).
- Integración con Checkout Pro (SDK oficial de Mercado Pago).
- Webhook verificado, idempotente, con confirmación server-side del pago.
- Resolución de casos `PAID_REQUIRES_REVIEW` desde el panel admin.

## Fase 4 — Entradas digitales

- Emisión de entradas y generación de QR.
- Envío de email (Resend): confirmación de compra, entrega de entrada.
- `/entradas`: recuperación de entradas por email (enlace de un solo uso).

## Fase 5 — Control de acceso

- `/scan`: lectura de QR desde cámara del navegador.
- Integración con `validate_ticket`, feedback visual claro por resultado.
- Panel de accesos en tiempo real para el admin.

## Fase 6 — Pruebas y seguridad

- Suite de tests (Vitest + Playwright) para los flujos críticos definidos en la Fase 0.
- Rate limiting (Upstash) sobre endpoints sensibles.
- Error tracking (Sentry).
- Pruebas de concurrencia adicionales bajo carga.

## Fase 7 — Deploy

- Proyecto Supabase de producción, variables de entorno en Vercel.
- Mercado Pago en producción (credenciales reales, webhook de producción).
- Dominio propio, checklist previo al lanzamiento.

---

# Future Product Evolution

El proyecto nació para The Pulse Project y seguirá siendo su primer
caso de uso real — el entorno donde se valida con ventas y accesos
reales. La arquitectura, sin embargo, no debe cerrar la puerta a que en
el futuro otros organizadores (bandas, productores, teatros, festivales,
etc.) usen la misma plataforma. Regla rectora: **SaaS-ready, no
SaaS-yet** — el modelo de datos se prepara para esa evolución, pero
ninguna funcionalidad comercial de plataforma se construye antes de que
haga falta.

## Horizonte 1 — MVP real (objetivo actual)

Vender entradas para un evento real de The Pulse Project. Una
organización, uno o varios eventos, tipos de entrada, guest checkout,
primer proveedor de pagos sobre una arquitectura de pagos multiproveedor,
reservas de stock, entradas digitales con QR, scanner, panel
administrativo, emails, recuperación de entradas, auditoría, seguridad,
deploy de producción. La arquitectura de pagos agnóstica (Fase 1.1) y el
modelo mínimo de organizaciones/membresías (Fase 1.2) ya están
resueltos; el resto es lo que cubren las Fases 2 a 7.

## Horizonte 2 — Multi-organizador (futuro)

Alta de organizaciones, miembros por organización con roles más allá de
`admin`/`scanner` (`OWNER`/`MANAGER`/`VIEWER`), invitación de miembros,
aislamiento completo de datos con RLS activo por organización, dashboard
y branding por organización, configuración de pagos por organización
(credenciales propias por organizador, nunca en texto plano — requiere
un sistema de secretos/credenciales cifradas, no variables de entorno
globales como en el MVP), y administración global de plataforma
(`super_admin`) separada de `organization_memberships`. Solo están
implementadas hoy las estructuras mínimas de datos que lo permiten
(`organizations`, `organization_memberships`) — nada de esta lista está
construido todavía.

También queda documentada, sin implementar, la distinción entre
**organización** (quién produce eventos — ej. The Pulse Project) y una
futura entidad `production` (un espectáculo reutilizable en varias
fechas/ciudades — ej. "Echoes Through Time Tour"), de la cual cada
`event` colgaría opcionalmente. Hoy cada evento es independiente, sin
entidad `production` superior.

## Horizonte 3 — Producto comercial (futuro)

Comisiones de plataforma, suscripciones, planes, facturación a
organizadores, analytics avanzados, códigos promocionales, listas de
invitados, preventas, waiting list, integraciones externas. El modelo de
pagos actual ya distingue monto bruto de la orden (`orders.total_amount_cents`)
de lo confirmado por el proveedor (`payments.amount_cents`), lo cual
deja espacio para agregar más adelante columnas como comisión de
plataforma o monto neto del organizador sin romper nada existente — no
se agregan todavía porque no existe ningún modelo comercial que las
necesite.

## Horizonte 4 — Ticketing avanzado (futuro)

Asientos numerados (requiere un dominio nuevo: venue, seating map,
section, row, seat, seat hold — separado del inventario por tipo de
entrada que usa el MVP), mapas de salas, escaneo offline y sincronización
de dispositivos, Apple Wallet, Google Wallet, QR dinámicos, anti-fraude
avanzado, API pública, webhooks para organizadores.

**Escaneo offline, específicamente, no se implementa en el MVP a
propósito**: introduce problemas reales de consistencia (dos
dispositivos offline podrían aceptar el mismo ticket antes de
sincronizar; la revocación de una entrada no se propaga de inmediato;
los estados requieren reconciliación posterior) que no se resuelven
guardando tickets en el navegador — necesitan un diseño específico
propio. El scanner del MVP requiere conexión.

**QR dinámico tampoco se implementa**: el token opaco estático actual
(ver DECISIONS.md) es adecuado para el primer producto; un QR dinámico
implica rotación de tokens, sincronización temporal y una app o página
activa del lado del comprador — mayor complejidad operativa que no
se justifica todavía.

## Horizonte 5 — Expansión internacional (futuro)

Multi-moneda, multi-idioma, multi-país, proveedores de pago
internacionales, fiscalidad por jurisdicción. El MVP opera en ARS, en
español, en Argentina.

---

Cuando se tome una decisión de arquitectura relevante en cualquier fase,
se registra en [`DECISIONS.md`](./DECISIONS.md).
