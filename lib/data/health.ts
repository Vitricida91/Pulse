import "server-only";

import { getSupabaseAdminClient } from "@/lib/data/supabase-admin";

export type DatabaseHealth =
  | { ok: true; latencyMs: number }
  | { ok: false; error: string };

/**
 * Verifica conectividad real contra Supabase (no solo que las env vars
 * existan). Se apoya en `events` porque ya existe desde esta fase y una
 * consulta `head: true` no transfiere filas.
 */
export async function checkDatabaseConnection(): Promise<DatabaseHealth> {
  const startedAt = Date.now();

  try {
    const supabase = getSupabaseAdminClient();
    const { error } = await supabase.from("events").select("id", { count: "exact", head: true });

    if (error) {
      return { ok: false, error: error.message };
    }

    return { ok: true, latencyMs: Date.now() - startedAt };
  } catch (caught) {
    const message = caught instanceof Error ? caught.message : "Error desconocido";
    return { ok: false, error: message };
  }
}
