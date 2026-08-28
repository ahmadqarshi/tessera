import { describe, expect, it } from "vitest";
import { lowercaseAddressSchema } from "@tessera/shared";

// lowercaseAddressSchema is the DTO-boundary guard that makes "addresses are stored and compared
// lowercased" structural: it validates with isAddress and TRANSFORMS to lowercase on parse. These
// tests pin both halves — rejection of non-addresses and normalisation of valid ones — so a future
// edit that drops the transform (reintroducing the silent-forgotten-lowercasing bug) fails here.
// Imports from the package entry ("@tessera/shared" → dist) so it exercises the shipped artifact.
describe("lowercaseAddressSchema", () => {
  // A canonical EIP-55 checksummed address (from the EIP-55 spec) and its lowercase form. viem's
  // `isAddress` is strict — it validates the checksum of any mixed-case input — so the accepted
  // inputs are exactly a valid checksummed address or an all-lowercase one, matching lowerAddress().
  const checksummed = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
  const lowered = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";

  it("normalises a checksummed address to lowercase on parse", () => {
    expect(lowercaseAddressSchema.parse(checksummed)).toBe(lowered);
  });

  it("passes an already-lowercase address through unchanged", () => {
    expect(lowercaseAddressSchema.parse(lowered)).toBe(lowered);
  });

  it("normalises a second checksummed address to lowercase", () => {
    expect(lowercaseAddressSchema.parse("0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359")).toBe(
      "0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359",
    );
  });

  it("rejects a mixed-case address with an invalid EIP-55 checksum", () => {
    // Same hex as `lowered` but with one nibble upper-cased — not a valid checksum.
    expect(lowercaseAddressSchema.safeParse("0x5Aaeb6053f3e94c9b9a09f33669435e7ef1beaed").success).toBe(false);
  });

  it("rejects a non-address string", () => {
    expect(lowercaseAddressSchema.safeParse("not-an-address").success).toBe(false);
  });

  it("rejects a hex string of the wrong length", () => {
    expect(lowercaseAddressSchema.safeParse("0x1234").success).toBe(false);
  });

  it("rejects a non-string input", () => {
    expect(lowercaseAddressSchema.safeParse(1234).success).toBe(false);
  });
});
