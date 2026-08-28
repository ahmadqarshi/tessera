import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // DB-backed tests connect to the docker-compose Postgres; give them room to spin up.
    setupFiles: ["./test/setup-env.ts"],
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
});
