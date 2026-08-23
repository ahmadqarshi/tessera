import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { seedManifestSchema, type SeedManifest, type ChainEnv } from "./schemas";

// Node-only entry point. Import from "@tessera/shared/seed-manifest" (never the browser
// bundle) — Phase 2/3 e2e tests read the seed manifest that contracts/script/Seed.s.sol writes.

// Compiled to dist/seed-manifest.js; the JSON files sit at the package root, one level up.
const PACKAGE_ROOT = join(__dirname, "..");

/** Absolute path to the seed manifest for a chain environment. */
export function seedManifestPath(env: ChainEnv): string {
  return join(PACKAGE_ROOT, `seed.${env}.json`);
}

/**
 * Load and validate the seed manifest for a chain environment. Throws if the file is missing
 * (e.g. before the seed script has run) so callers fail loudly rather than reading stale state.
 */
export function loadSeedManifest(env: ChainEnv): SeedManifest {
  const path = seedManifestPath(env);
  if (!existsSync(path)) {
    throw new Error(
      `Seed manifest not found for env "${env}" at ${path}. Run the seed script to generate it.`,
    );
  }
  const raw = JSON.parse(readFileSync(path, "utf-8")) as unknown;
  return seedManifestSchema.parse(raw);
}

/** Like {@link loadSeedManifest} but returns `undefined` instead of throwing when absent. */
export function tryLoadSeedManifest(env: ChainEnv): SeedManifest | undefined {
  return existsSync(seedManifestPath(env)) ? loadSeedManifest(env) : undefined;
}
