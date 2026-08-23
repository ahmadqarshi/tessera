import { Global, Module } from "@nestjs/common";
import { ConfigModule } from "@nestjs/config";
import { join } from "node:path";
import { validateEnv } from "./env.validation";

/**
 * Global configuration module. Reads `.env` (repo root and app-local), validates it with
 * Zod, and exposes a typed `ConfigService` everywhere.
 */
@Global()
@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      cache: true,
      validate: validateEnv,
      envFilePath: [join(process.cwd(), ".env"), join(process.cwd(), "../../.env")],
    }),
  ],
})
export class AppConfigModule {}
