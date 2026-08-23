import { isAddress, type Address } from "viem";
import { z } from "zod";

/** An EVM address, validated with viem's `isAddress`. */
export const addressSchema = z.custom<Address>((value) => typeof value === "string" && isAddress(value), {
  message: "Invalid EVM address",
});

/**
 * Token amounts cross the wire as decimal integer strings (base units), never JS numbers.
 * Parse to `bigint` at the boundary with `BigInt(value)`.
 */
export const amountStringSchema = z
  .string()
  .regex(/^\d+$/, "Amount must be a non-negative integer string (base units)");

/** Chain of record: local Anvil or Polygon Amoy. */
export const chainEnvSchema = z.enum(["local", "amoy"]);
export type ChainEnv = z.infer<typeof chainEnvSchema>;

/**
 * ONCHAINID claim topics. 1 = KYC, 2 = AML/sanctions, 3 = Accredited (stretch),
 * 10 = Jurisdiction (stretch). See contracts/CLAUDE.md.
 */
export const claimTopicSchema = z.union([
  z.literal(1),
  z.literal(2),
  z.literal(3),
  z.literal(10),
]);
export type ClaimTopic = z.infer<typeof claimTopicSchema>;

/**
 * Transfer pre-check result. When blocked, `reason` is written in language an operator
 * could repeat to a regulator and is rendered verbatim by the UI — never paraphrased.
 */
export const transferPrecheckSchema = z.discriminatedUnion("allowed", [
  z.object({ allowed: z.literal(true) }),
  z.object({ allowed: z.literal(false), reason: z.string().min(1) }),
]);
export type TransferPrecheck = z.infer<typeof transferPrecheckSchema>;

/**
 * The on-chain address book for a given chain environment. `deployBlock` seeds the
 * indexer backfill; `contracts` maps a logical name to a deployed address.
 */
export const addressBookSchema = z.object({
  chainId: z.number().int().positive(),
  deployBlock: z.number().int().nonnegative(),
  contracts: z.record(z.string(), addressSchema),
});
export type AddressBook = z.infer<typeof addressBookSchema>;

/**
 * One seeded investor in the seed manifest. `identity` is the investor's ONCHAINID contract
 * (the zero address for the unverified negative fixture, which has none). `country` is an ISO
 * 3166-1 numeric code (0 for the fixture). `balance` is base units as a decimal string.
 */
export const seedInvestorSchema = z.object({
  label: z.string().min(1),
  wallet: addressSchema,
  identity: addressSchema,
  country: z.number().int().nonnegative().max(65535),
  verified: z.boolean(),
  balance: amountStringSchema,
});
export type SeedInvestor = z.infer<typeof seedInvestorSchema>;

/**
 * The seed manifest for a chain environment (packages/shared/seed.<env>.json), written by
 * contracts/script/Seed.s.sol. Gives Phase 2/3 e2e tests the seeded wallets, their ONCHAINID
 * contracts, and the exact distributed balances without re-deriving them from chain.
 */
export const seedManifestSchema = z.object({
  chainId: z.number().int().positive(),
  token: addressSchema,
  investors: z.record(z.string(), seedInvestorSchema),
});
export type SeedManifest = z.infer<typeof seedManifestSchema>;
