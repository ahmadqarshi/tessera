import { afterAll, describe, expect, it } from "vitest";
import { PrismaClient } from "@prisma/client";

// Proves the amount-handling invariant end to end: a value far larger than Number.MAX_SAFE_INTEGER
// round-trips through a Decimal(78,0) column as an EXACT decimal string, with no float rounding.
// This is why amounts are Decimal(78,0) and never Float/Int — a uint256 does not survive a Number.
describe("Decimal(78,0) exact round-trip", () => {
  const prisma = new PrismaClient();
  // A 30-digit value: ~7 orders of magnitude beyond 2^53, and a near-uint256-max value.
  const bigAmount = "123456789012345678901234567890";
  const uint256Max = "115792089237316195423570985008687907853269984665640564039457584007913129639935";
  const token = "0xdecdecdecdecdecdecdecdecdecdecdecdecdec0";

  afterAll(async () => {
    await prisma.tokenState.deleteMany({ where: { tokenAddress: token } });
    await prisma.$disconnect();
  });

  it("stores and returns a value beyond Number.MAX_SAFE_INTEGER without precision loss", async () => {
    expect(Number(bigAmount)).toBeGreaterThan(Number.MAX_SAFE_INTEGER);

    const written = await prisma.tokenState.create({
      data: { tokenAddress: token, paused: false, totalSupply: bigAmount, lastBlock: 1n },
    });
    expect(written.totalSupply.toFixed()).toBe(bigAmount);

    const read = await prisma.tokenState.findUniqueOrThrow({ where: { tokenAddress: token } });
    expect(read.totalSupply.toFixed()).toBe(bigAmount);
    // The bigint <-> string boundary is exact too.
    expect(BigInt(read.totalSupply.toFixed())).toBe(BigInt(bigAmount));
  });

  it("stores the full uint256 max exactly (fits within Decimal(78,0))", async () => {
    const updated = await prisma.tokenState.update({
      where: { tokenAddress: token },
      data: { totalSupply: uint256Max },
    });
    expect(updated.totalSupply.toFixed()).toBe(uint256Max);
    expect(uint256Max).toHaveLength(78);
  });
});
