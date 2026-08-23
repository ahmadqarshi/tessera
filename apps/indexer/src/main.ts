import "reflect-metadata";
import { Logger } from "@nestjs/common";
import { NestFactory } from "@nestjs/core";
import { AppModule } from "./app.module";

/**
 * The indexer is a standalone Nest worker — an application *context*, not an HTTP server.
 * It runs the polling loop in {@link IndexerService}; there is no port to bind.
 */
async function bootstrap(): Promise<void> {
  const app = await NestFactory.createApplicationContext(AppModule);
  app.enableShutdownHooks();
  Logger.log("Tessera indexer worker started", "Bootstrap");
}

void bootstrap();
