import { Module } from "@nestjs/common";
import { AppConfigModule } from "./config/config.module";
import { PrismaModule } from "./prisma/prisma.module";
import { HealthModule } from "./health/health.module";

/**
 * Root module. Feature modules (Auth, Kyc, Aml, ClaimIssuer, Agent, Identity, Token,
 * Compliance, Read) are added in later phases — see apps/api/CLAUDE.md.
 */
@Module({
  imports: [AppConfigModule, PrismaModule, HealthModule],
})
export class AppModule {}
