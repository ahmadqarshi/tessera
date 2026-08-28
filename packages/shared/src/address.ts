import { getAddress, isAddress, type Address } from "viem";

export type { Address };

/** Zero address, typed. */
export const ZERO_ADDRESS: Address = "0x0000000000000000000000000000000000000000";

/** Runtime type guard: is this a syntactically valid EVM address? */
export function isEvmAddress(value: unknown): value is Address {
  return typeof value === "string" && isAddress(value);
}

/**
 * Validate and checksum an address at a trust boundary. Throws on invalid input so bad
 * addresses never propagate into chain calls or the database.
 */
export function assertAddress(value: string): Address {
  if (!isAddress(value)) {
    throw new Error(`Invalid EVM address: ${value}`);
  }
  return getAddress(value);
}

/**
 * Normalise an address to the lowercase 0x-hex form used for every stored and compared address
 * in Tessera. Validates first (throws on a non-address) so a malformed value never reaches the
 * database. This is the single normalisation point every DB writer must call before persisting
 * an address — the schema stores addresses lowercased and Prisma does not enforce it.
 */
export function lowerAddress(value: string): Address {
  if (!isAddress(value)) {
    throw new Error(`Invalid EVM address: ${value}`);
  }
  // A template literal keeps the `0x${string}` type (= Address) with no cast: TS cannot infer
  // that `.toLowerCase()` alone preserves the 0x prefix, but rebuilding the string does.
  return `0x${value.slice(2).toLowerCase()}`;
}

/**
 * Checksum an address to its EIP-55 mixed-case form for HUMAN DISPLAY. Storage and comparison use
 * the lowercase form (`lowerAddress()`, invariant #5); presentation is the opposite concern — the
 * mixed-case checksum is what makes a mistyped address visually detectable, and the design system's
 * address chip is drawn against it. Validates first (throws on a non-address). Never persist or
 * compare this form. Pair with {@link shortenAddress} for the 6/4 chip:
 * `shortenAddress(toDisplayAddress(addr))`.
 */
export function toDisplayAddress(value: string): Address {
  return getAddress(value);
}

/**
 * Truncate an address 6/4 for display (`0x7A3f9B…9C21`), matching the design system's
 * address chip. Display only — never persist or compare the truncated form. Feed it a
 * checksummed value from {@link toDisplayAddress} so the truncated chip stays EIP-55.
 */
export function shortenAddress(value: Address, lead = 6, tail = 4): string {
  if (value.length <= lead + tail) {
    return value;
  }
  return `${value.slice(0, lead)}…${value.slice(-tail)}`;
}
