/**
 * Database seed. Populated in later phases with demo investors, offerings, and claims
 * (see docs/TASKS.md). No-op for the scaffold pass.
 */
import { PrismaClient } from "@prisma/client";

const prisma = new PrismaClient();

async function main(): Promise<void> {
  console.log("No seed data for the scaffold pass — nothing to do.");
}

main()
  .catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  })
  .finally(() => {
    void prisma.$disconnect();
  });
