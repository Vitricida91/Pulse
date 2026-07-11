/**
 * Acceso centralizado a variables de entorno. Cada getter valida de forma
 * perezosa (recién al invocarse), para que un subsistema no usado todavía
 * (ej. Mercado Pago en la Fase 1) no rompa el arranque de la app por falta
 * de una variable que ese subsistema necesitará recién en fases futuras.
 *
 * Nunca leer `process.env` directamente fuera de este módulo: mantiene un
 * único lugar donde se documenta y valida cada nombre de variable.
 */

function required(name: string): string {
  const value = process.env[name];
  if (!value || value.trim() === "") {
    throw new Error(
      `Falta configurar la variable de entorno "${name}". Ver .env.example.`,
    );
  }
  return value;
}

/** URL pública canónica de la app. Nunca hardcodear el dominio en el código. */
export function getAppUrl(): string {
  return required("NEXT_PUBLIC_APP_URL").replace(/\/+$/, "");
}

export function getSupabaseUrl(): string {
  return required("NEXT_PUBLIC_SUPABASE_URL");
}

export function getSupabaseAnonKey(): string {
  return required("NEXT_PUBLIC_SUPABASE_ANON_KEY");
}

/**
 * Bypassea RLS. Server-only: nunca importar este getter desde un Client
 * Component. `lib/data/supabase-admin.ts` es el único lugar que debería
 * llamarlo.
 */
export function getSupabaseServiceRoleKey(): string {
  return required("SUPABASE_SERVICE_ROLE_KEY");
}
