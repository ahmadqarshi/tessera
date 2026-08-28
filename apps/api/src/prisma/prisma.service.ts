import { Injectable, Logger, type OnModuleDestroy, type OnModuleInit } from "@nestjs/common";
import { PrismaClient } from "@prisma/client";

/**
 * Prisma client wired into the Nest lifecycle. Connects on module init and disconnects on
 * shutdown (via `app.enableShutdownHooks()` in main.ts, which drives `onModuleDestroy`) so
 * connections are released cleanly.
 *
 * Address normalisation: every address-typed column is stored lowercased. Prisma cannot enforce
 * this at the column level, so writers normalise with `lowerAddress()` from `@tessera/shared`
 * before persisting — the rule lives at the call site, not in a fragile client extension that
 * would need to know which of every model's string fields happen to be addresses.
 */
@Injectable()
export class PrismaService extends PrismaClient implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(PrismaService.name);

  async onModuleInit(): Promise<void> {
    await this.$connect();
    this.logger.log("Prisma connected");
  }

  async onModuleDestroy(): Promise<void> {
    await this.$disconnect();
  }
}
