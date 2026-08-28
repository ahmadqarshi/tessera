// Test-run environment bootstrap. Two responsibilities, in order:
//
//   1. Load the monorepo-root `.env` into `process.env`. Prisma's CLI auto-loads it, but a plain
//      `new PrismaClient()` at test runtime does not — so populate it here, filling only variables
//      that are not already set, and defaulting DATABASE_URL to the docker-compose Postgres.
//   2. Validate the resulting environment through the SAME Zod schema the app boots with
//      (`validateEnv` / `envSchema` in src/config). There is deliberately no second list of required
//      variables here: if the schema requires JWT_SECRET or the two signing keys, the test run must
//      fail on their absence exactly as `pnpm dev` would — otherwise a test could pass against an
//      environment the application would reject at boot, and the gap would surface only in prod.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { validateEnv } from "../src/config/env.validation";

const DEFAULT_DATABASE_URL = "postgresql://rwa:rwa@localhost:5432/rwa?schema=public";

function loadRootEnv(): void {
  const envPath = resolve(__dirname, "../../../.env");
  try {
    const raw = readFileSync(envPath, "utf8");
    for (const line of raw.split("\n")) {
      const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
      if (!match) continue;
      const [, key, rawValue] = match;
      if (process.env[key] !== undefined) continue;
      process.env[key] = rawValue.replace(/^["']|["']$/g, "");
    }
  } catch {
    // No root .env on this machine — fall through to the default below.
  }
}

loadRootEnv();

if (process.env.DATABASE_URL === undefined || process.env.DATABASE_URL === "") {
  process.env.DATABASE_URL = DEFAULT_DATABASE_URL;
}

// Single source of truth for "what env the app requires". Throws a readable, aggregated error and
// aborts the test run on any missing or malformed variable — the same failure the app raises at boot.
validateEnv(process.env);
