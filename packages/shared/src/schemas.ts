import { isAddress, type Address } from "viem";
import { z } from "zod";

/**
 * The single EVM-address schema. Validates with viem's strict `isAddress` (which checks the EIP-55
 * checksum of any mixed-case input), then TRANSFORMS to the lowercase 0x-hex form and brands the
 * result. Use it everywhere an address is parsed — request DTOs from Phase 2.2 onward, and the
 * file-backed loaders below — so a raw or checksummed string can never reach a query or a stored
 * row without first being normalised. This makes the "addresses are stored and compared lowercased,
 * without exception" invariant structural at the parse boundary rather than a call-site convention
 * that can be silently forgotten.
 *
 * The brand means a plain `string` is not assignable to `LowercaseAddress`: a value only earns the
 * type by parsing through this schema, so the compiler flags any address-typed field that skipped
 * it. For non-DTO imperative paths — decoded event args, chain reads — use `lowerAddress()` from
 * "./address", which performs the same normalisation without Zod.
 *
 * There is deliberately NO second, non-normalising address schema. Two schemas differing only by
 * whether they lowercase are a silent-failure footgun: pick the wrong one and a mixed-case address
 * reaches a query, matches nothing, and returns an empty result instead of an error.
 */
export const lowercaseAddressSchema = z
  .string()
  .refine((value) => isAddress(value), { message: "Invalid EVM address" })
  // Rebuilding the string (rather than `.toLowerCase()` alone) preserves the `0x${string}` = Address
  // type with no cast — TS cannot infer that `.toLowerCase()` keeps the 0x prefix.
  .transform((value): Address => `0x${value.slice(2).toLowerCase()}`)
  .brand<"LowercaseAddress">();

/** A validated, lowercase-normalised EVM address. Only obtainable by parsing through
 * {@link lowercaseAddressSchema}; a raw `string` is not assignable to it. */
export type LowercaseAddress = z.infer<typeof lowercaseAddressSchema>;

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
  contracts: z.record(z.string(), lowercaseAddressSchema),
});
export type AddressBook = z.infer<typeof addressBookSchema>;

/**
 * One seeded investor in the seed manifest. `identity` is the investor's ONCHAINID contract
 * (the zero address for the unverified negative fixture, which has none). `country` is an ISO
 * 3166-1 numeric code (0 for the fixture). `balance` is base units as a decimal string.
 */
export const seedInvestorSchema = z.object({
  label: z.string().min(1),
  wallet: lowercaseAddressSchema,
  identity: lowercaseAddressSchema,
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
  token: lowercaseAddressSchema,
  investors: z.record(z.string(), seedInvestorSchema),
});
export type SeedManifest = z.infer<typeof seedManifestSchema>;
