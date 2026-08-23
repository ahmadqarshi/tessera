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
 * Truncate an address 6/4 for display (`0x7A3f9B…9C21`), matching the design system's
 * address chip. Display only — never persist or compare the truncated form.
 */
export function shortenAddress(value: Address, lead = 6, tail = 4): string {
  if (value.length <= lead + tail) {
    return value;
  }
  return `${value.slice(0, lead)}…${value.slice(-tail)}`;
}
