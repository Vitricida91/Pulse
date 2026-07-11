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

Cuando se tome una decisión de arquitectura relevante en cualquier fase,
se registra en [`DECISIONS.md`](./DECISIONS.md).
