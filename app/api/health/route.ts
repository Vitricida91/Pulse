import { NextResponse } from "next/server";

import { checkDatabaseConnection } from "@/lib/data/health";

export async function GET() {
  const database = await checkDatabaseConnection();

  const body = {
    status: database.ok ? "ok" : "error",
    timestamp: new Date().toISOString(),
    checks: { database },
  } as const;

  return NextResponse.json(body, { status: database.ok ? 200 : 503 });
}
