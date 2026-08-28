import { defineConfig } from "vitest/config";

// Mirrors apps/api/vitest.config.ts. Shared has no database-backed tests — these are pure unit
// tests over constants and pure functions — so there is no `setupFiles` DATABASE_URL bootstrap
// here. Tests import from the package entry ("@tessera/shared" → dist), i.e. the SAME built artifact
// the API and indexer consume, not the `src/` TypeScript. The `pretest` script rebuilds `dist` first
// so the tests can never pass against a stale build while the app ships the old code.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
