import "server-only";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { getSupabaseServiceRoleKey, getSupabaseUrl } from "@/lib/config/env";
import type { Database } from "@/lib/data/database.types";

let cachedClient: SupabaseClient<Database> | null = null;

/**
 * Cliente de Supabase con la service role key: bypassea RLS.
 *
 * `import "server-only"` hace que Next.js falle el build si este módulo
 * se importa, directa o indirectamente, desde código que termina en el
 * bundle del navegador. Es la única forma en que la app debería acceder
 * a datos de negocio (ver DECISIONS.md: RLS deny-by-default).
 */
export function getSupabaseAdminClient(): SupabaseClient<Database> {
  if (cachedClient) {
    return cachedClient;
  }

  cachedClient = createClient<Database>(getSupabaseUrl(), getSupabaseServiceRoleKey(), {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  return cachedClient;
}
