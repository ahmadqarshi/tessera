import "reflect-metadata";
import { Logger } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { NestFactory } from "@nestjs/core";
import { AppModule } from "./app.module";
import type { Env } from "./config/env.validation";

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule);
  app.enableShutdownHooks();
  app.enableCors();

  const config = app.get(ConfigService<Env, true>);
  const port = config.get("API_PORT", { infer: true });
  await app.listen(port);

  Logger.log(`Tessera API listening on http://localhost:${port}`, "Bootstrap");
}

void bootstrap();
