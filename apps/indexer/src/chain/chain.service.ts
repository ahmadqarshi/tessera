import { Injectable, Logger } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { createPublicClient, http, type PublicClient } from "viem";
import { foundry, polygonAmoy } from "viem/chains";
import type { ChainEnv } from "@tessera/shared";
import type { Env } from "../config/env.validation";

/**
 * Read-only viem public client for the configured chain. The indexer only ever reads chain
 * state (logs, blocks); it holds no signing keys.
 */
@Injectable()
export class ChainService {
  private readonly logger = new Logger(ChainService.name);
  readonly client: PublicClient;

  constructor(private readonly config: ConfigService<Env, true>) {
    const env = this.config.get("CHAIN_ENV", { infer: true }) as ChainEnv;
    const chain = env === "amoy" ? polygonAmoy : foundry;
    const rpcUrl =
      env === "amoy"
        ? this.config.get("RPC_URL_AMOY", { infer: true })
        : this.config.get("RPC_URL_LOCAL", { infer: true });

    this.client = createPublicClient({ chain, transport: http(rpcUrl) });
    this.logger.log(`Chain client ready: ${env} (${chain.id}) via ${rpcUrl}`);
  }
}
