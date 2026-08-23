import { Injectable, Logger, type OnApplicationBootstrap, type OnModuleDestroy } from "@nestjs/common";
import { ConfigService } from "@nestjs/config";
import { ChainService } from "../chain/chain.service";
import type { Env } from "../config/env.validation";

/**
 * The polling worker. Scaffold pass: prints the resolved configuration and holds the
 * process open. The real loop — persisted cursor, confirmations buffer, hash-tracked reorg
 * rollback, single-transaction batches, idempotent upserts — lands in Phase 3
 * (see apps/indexer/CLAUDE.md and the indexer-patterns skill).
 */
@Injectable()
export class IndexerService implements OnApplicationBootstrap, OnModuleDestroy {
  private readonly logger = new Logger(IndexerService.name);
  private heartbeat?: NodeJS.Timeout;

  constructor(
    private readonly config: ConfigService<Env, true>,
    private readonly chain: ChainService,
  ) {}

  onApplicationBootstrap(): void {
    const confirmations = this.config.get("CONFIRMATIONS", { infer: true });
    const pollMs = this.config.get("INDEXER_POLL_MS", { infer: true });
    const batch = this.config.get("INDEXER_BATCH_SIZE", { infer: true });
    const chainId = this.chain.client.chain?.id ?? "unknown";

    this.logger.log(
      `Indexer configured for chain ${chainId} ` +
        `(confirmations=${confirmations}, pollMs=${pollMs}, batch=${batch}). ` +
        "Polling loop not implemented yet (scaffold).",
    );

    // Keep the worker process alive until a real poll loop replaces this.
    this.heartbeat = setInterval(() => {
      this.logger.debug("idle — awaiting Phase 3 poll loop");
    }, pollMs);
  }

  onModuleDestroy(): void {
    if (this.heartbeat) {
      clearInterval(this.heartbeat);
    }
  }
}
