import { checkDatabaseConnection } from "@/lib/data/health";

export const dynamic = "force-dynamic";

export default async function EstadoPage() {
  const database = await checkDatabaseConnection();

  return (
    <div className="flex flex-1 items-center justify-center px-6 py-24">
      <div className="w-full max-w-md space-y-4 rounded-lg border border-border bg-surface p-8">
        <p className="text-xs font-medium tracking-widest text-accent uppercase">
          Estado del sistema
        </p>
        <div className="flex items-center gap-3">
          <span
            className={`h-2.5 w-2.5 rounded-full ${database.ok ? "bg-emerald-500" : "bg-red-500"}`}
            aria-hidden
          />
          <span className="text-sm font-medium text-foreground">
            Base de datos (Supabase):{" "}
            {database.ok ? `conectada (${database.latencyMs} ms)` : "sin conexión"}
          </span>
        </div>
        {!database.ok ? (
          <p className="text-sm text-muted">
            {database.error} — Configurá <code>NEXT_PUBLIC_SUPABASE_URL</code> y{" "}
            <code>SUPABASE_SERVICE_ROLE_KEY</code> en <code>.env.local</code> (ver{" "}
            <code>.env.example</code>).
          </p>
        ) : null}
      </div>
    </div>
  );
}
