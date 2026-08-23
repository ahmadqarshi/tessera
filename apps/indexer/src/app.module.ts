import { Module } from "@nestjs/common";
import { ConfigModule } from "@nestjs/config";
import { join } from "node:path";
import { validateEnv } from "./config/env.validation";
import { ChainService } from "./chain/chain.service";
import { IndexerService } from "./indexer/indexer.service";

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      cache: true,
      validate: validateEnv,
      envFilePath: [join(process.cwd(), ".env"), join(process.cwd(), "../../.env")],
    }),
  ],
  providers: [ChainService, IndexerService],
})
export class AppModule {}
