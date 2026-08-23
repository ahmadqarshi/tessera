import { z } from "zod";

/**
 * Environment schema for the API. Validated at boot (see {@link validateEnv}); the app
 * refuses to start on a missing or malformed variable rather than failing later at runtime.
 * Mock providers are the default so a fresh clone runs with zero paid accounts.
 */
export const envSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),

  // Chain of record.
  CHAIN_ENV: z.enum(["local", "amoy"]).default("local"),
  CHAIN_ID: z.coerce.number().int().positive().default(31337),
  RPC_URL_LOCAL: z.string().url().default("http://127.0.0.1:8545"),
  RPC_URL_AMOY: z.string().url().default("https://rpc-amoy.polygon.technology"),

  // Two backend signing keys — never merged (see root CLAUDE.md).
  CLAIM_ISSUER_PRIVATE_KEY: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  AGENT_PRIVATE_KEY: z.string().regex(/^0x[0-9a-fA-F]{64}$/),

  // Persistence.
  DATABASE_URL: z.string().url(),

  // Providers — mock is the default and always works offline.
  PROVIDER_KYC: z.string().default("mock"),
  PROVIDER_AML: z.string().default("mock"),
  PERSONA_API_KEY: z.string().optional(),
  PERSONA_WEBHOOK_SECRET: z.string().optional(),
  YENTE_URL: z.string().url().optional().or(z.literal("")),

  // API + auth.
  API_PORT: z.coerce.number().int().positive().default(3001),
  JWT_SECRET: z.string().min(1),
  SIWE_DOMAIN: z.string().min(1).default("localhost:3000"),
  SIWE_SESSION_TTL: z.coerce.number().int().positive().default(3600),
  AGENT_ALLOWLIST: z.string().optional(),
});

export type Env = z.infer<typeof envSchema>;

/** Nest ConfigModule `validate` hook. Throws a readable error on invalid env. */
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
