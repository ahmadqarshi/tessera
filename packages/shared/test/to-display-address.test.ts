import { describe, expect, it } from "vitest";
import { lowerAddress, shortenAddress, toDisplayAddress } from "@tessera/shared";

// toDisplayAddress is the presentation counterpart to lowerAddress: the DB stores lowercase, the
// human sees the EIP-55 checksum (which makes a mistyped address visually detectable). These tests
// pin that it checksums a lowercase input back to the canonical mixed case and composes with the
// 6/4 chip truncation. Imports from the package entry ("@tessera/shared" → dist).
describe("toDisplayAddress", () => {
  const lowered = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed";
  const display = toDisplayAddress(lowered); // Address, EIP-55 checksummed

  it("checksums a lowercase (DB) address back to its EIP-55 mixed-case form", () => {
    expect(display).toBe("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed");
  });

  it("round-trips: lowerAddress for storage, toDisplayAddress for the human", () => {
    expect(lowerAddress(display)).toBe(lowered);
    expect(toDisplayAddress(lowerAddress(display))).toBe(display);
  });

  it("keeps the 6/4 chip checksummed (mixed-case), not lowercased", () => {
    const chip = shortenAddress(display);
    expect(chip).toContain("…");
    expect(chip).toMatch(/[A-F]/); // an EIP-55 uppercase nibble survives truncation
    expect(chip).not.toBe(shortenAddress(lowerAddress(display)));
  });

  it("throws on a non-address", () => {
    expect(() => toDisplayAddress("not-an-address")).toThrow();
  });
});
