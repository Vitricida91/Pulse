# The Pulse Project — Plataforma de entradas

Plataforma propia de venta de entradas online, pagos con Mercado Pago y
control de acceso por QR. Nace para los shows de **The Pulse Project —
Tributo a Pink Floyd**, con una arquitectura preparada para soportar
múltiples eventos.

Este repositorio se desarrolla por fases. El estado y la definición de
cada fase están en [`ROADMAP.md`](./ROADMAP.md). Las decisiones de
arquitectura relevantes están registradas en [`DECISIONS.md`](./DECISIONS.md).
El diseño de seguridad está en [`SECURITY.md`](./SECURITY.md) y el
detalle técnico de la arquitectura en [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Stack

- **Next.js** (App Router) + **TypeScript estricto** + **Tailwind CSS**.
- **Supabase** (Postgres + Auth), región São Paulo (`sa-east-1`).
- **Mercado Pago** (Checkout Pro) para pagos — se integra a partir de la Fase 3.
- **Resend** para email transaccional — se integra a partir de la Fase 4.
- Hosting: **Vercel** (app) + **Supabase** (base de datos y auth).

## Requisitos

- Node.js 22+
- npm
- [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) (se invoca vía `npx supabase`, no requiere instalación global)
- Docker, si querés levantar el stack local completo de Supabase (`supabase start`)

## Puesta en marcha

```bash
npm install
cp .env.example .env.local
# completar .env.local con las credenciales de tu proyecto Supabase
npm run dev
```

`.env.local` nunca se commitea. Ver [`.env.example`](./.env.example) para
la lista completa de variables y qué significa cada una.

## Base de datos

El esquema vive como migraciones SQL versionadas en `supabase/migrations/`.

```bash
# Levantar Supabase localmente (requiere Docker)
npx supabase start

# Aplicar las migraciones a la base local
npx supabase db reset
```

Sin Docker disponible, las migraciones igual se pueden validar contra
cualquier Postgres 15+ con `psql -f supabase/migrations/<archivo>.sql`,
en orden. Ver la nota sobre el entorno de desarrollo de este proyecto en
`DECISIONS.md` (sección "Verificación de migraciones sin Docker").

## Scripts

| Script | Qué hace |
|---|---|
| `npm run dev` | Servidor de desarrollo |
| `npm run build` | Build de producción |
| `npm run start` | Sirve el build de producción |
| `npm run lint` | ESLint |
| `npm run typecheck` | `tsc --noEmit` |

## Verificar que todo funciona

Con el servidor corriendo y `.env.local` configurado:

- `GET /api/health` — JSON con el estado de la conexión a Supabase.
- `GET /estado` — misma verificación, en una página.

## Estructura del proyecto

```
app/                  Rutas (App Router): públicas, /admin, /scan, /api
components/           Componentes de UI compartidos
lib/domain/           Lógica de negocio pura (sin I/O)
lib/data/             Acceso a datos (Supabase, server-only)
lib/payments/         Contrato PaymentProvider agnóstico + adapters (Mercado Pago en Fase 3+)
lib/tickets/          Generación de QR y tokens (Fase 4+)
lib/email/            Envío de emails, interfaz EmailProvider (Fase 4+)
lib/auth/             Sesión y roles (Fase 2+)
lib/logging/          Logging estructurado
lib/config/           Lectura validada de variables de entorno
supabase/migrations/  Esquema de base de datos, versionado
```

## Roles del sistema

- **Visitante / comprador**: sin cuenta obligatoria (guest checkout).
- **Admin**: cuenta con Supabase Auth, rol `admin`.
- **Personal de acceso (scanner)**: cuenta individual con Supabase Auth, rol `scanner`, acceso acotado a `/scan`.
