import { afterAll, describe, expect, it } from "vitest";
import { PrismaService } from "../src/prisma/prisma.service";

// Boots the real PrismaService against the docker-compose Postgres and asserts the Nest
// lifecycle hooks connect and disconnect cleanly. Requires `docker compose up -d` + a migrated DB.
describe("PrismaService lifecycle", () => {
  const prisma = new PrismaService();

  afterAll(async () => {
    // Ensure the connection is released even if an assertion above threw.
    await prisma.$disconnect();
  });

  it("connects on module init and answers a query", async () => {
    await prisma.onModuleInit();
    const rows = await prisma.$queryRaw<Array<{ ok: number }>>`SELECT 1 AS ok`;
    expect(rows[0]?.ok).toBe(1);
  });

  it("disconnects on module destroy", async () => {
    await expect(prisma.onModuleDestroy()).resolves.toBeUndefined();
  });
});
