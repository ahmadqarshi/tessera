import { z } from "zod";

/**
 * Indexer environment. `CONFIRMATIONS` is config, never hardcoded (1 local, 32 Amoy), and
 * the poll interval / batch size bound each `getLogs` sweep.
 */
export const envSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),

  CHAIN_ENV: z.enum(["local", "amoy"]).default("local"),
  CHAIN_ID: z.coerce.number().int().positive().default(31337),
  RPC_URL_LOCAL: z.string().url().default("http://127.0.0.1:8545"),
  RPC_URL_AMOY: z.string().url().default("https://rpc-amoy.polygon.technology"),

  CONFIRMATIONS: z.coerce.number().int().nonnegative().default(1),
  INDEXER_POLL_MS: z.coerce.number().int().positive().default(2000),
  INDEXER_BATCH_SIZE: z.coerce.number().int().positive().default(2000),

  DATABASE_URL: z.string().url(),
});

export type Env = z.infer<typeof envSchema>;

export function validateEnv(config: Record<string, unknown>): Env {
  const result = envSchema.safeParse(config);
  if (!result.success) {
    const issues = result.error.issues
      .map((issue) => `  - ${issue.path.join(".") || "(root)"}: ${issue.message}`)
      .join("\n");
    throw new Error(`Invalid environment configuration:\n${issues}`);
  }
  return result.data;
}
