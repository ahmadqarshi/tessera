-- CreateSchema
CREATE SCHEMA IF NOT EXISTS "public";

-- CreateEnum
CREATE TYPE "ClaimStatus" AS ENUM ('PENDING_SUBMISSION', 'SUBMITTED', 'EXPIRED');

-- CreateEnum
CREATE TYPE "KycStatus" AS ENUM ('PENDING', 'APPROVED', 'DECLINED');

-- CreateEnum
CREATE TYPE "AdminActionStatus" AS ENUM ('PENDING', 'CONFIRMED', 'FAILED');

-- CreateEnum
CREATE TYPE "WatchedKind" AS ENUM ('TOKEN', 'IDENTITY_REGISTRY', 'IDENTITY_REGISTRY_STORAGE', 'MODULAR_COMPLIANCE', 'MAX_INVESTORS_MODULE', 'CLAIM_TOPICS_REGISTRY', 'TRUSTED_ISSUERS_REGISTRY', 'CLAIM_ISSUER', 'INVESTOR_IDENTITY');

-- CreateEnum
CREATE TYPE "TransferKind" AS ENUM ('MINT', 'BURN', 'TRANSFER', 'FORCED');

-- CreateTable
CREATE TABLE "investors" (
    "wallet" TEXT NOT NULL,
    "onchain_id" TEXT,
    "country" INTEGER NOT NULL,
    "display_name" TEXT NOT NULL,
    "email" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "investors_pkey" PRIMARY KEY ("wallet")
);

-- CreateTable
CREATE TABLE "claims" (
    "id" TEXT NOT NULL,
    "identity_address" TEXT NOT NULL,
    "topic" INTEGER NOT NULL,
    "issuer_address" TEXT NOT NULL,
    "claim_id" TEXT NOT NULL,
    "signature" TEXT NOT NULL,
    "data" TEXT NOT NULL,
    "uri" TEXT NOT NULL,
    "status" "ClaimStatus" NOT NULL DEFAULT 'PENDING_SUBMISSION',
    "issued_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expires_at" TIMESTAMP(3),
    "submitted_tx_hash" TEXT,
    "revocation_requested_at" TIMESTAMP(3),
    "revocation_tx_hash" TEXT,

    CONSTRAINT "claims_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "claim_chain_state" (
    "claim_id" TEXT NOT NULL,
    "identity_address" TEXT NOT NULL,
    "topic" INTEGER NOT NULL,
    "issuer_address" TEXT NOT NULL,
    "present" BOOLEAN NOT NULL,
    "revoked" BOOLEAN NOT NULL DEFAULT false,
    "signature" TEXT NOT NULL,
    "data" TEXT NOT NULL,
    "added_block" BIGINT NOT NULL,
    "added_tx_hash" TEXT NOT NULL,
    "added_log_index" INTEGER NOT NULL,
    "removed_block" BIGINT,
    "revoked_block" BIGINT,
    "last_block" BIGINT NOT NULL,

    CONSTRAINT "claim_chain_state_pkey" PRIMARY KEY ("claim_id","identity_address")
);

-- CreateTable
CREATE TABLE "kyc_sessions" (
    "id" TEXT NOT NULL,
    "investor_wallet" TEXT NOT NULL,
    "provider" TEXT NOT NULL,
    "session_ref" TEXT NOT NULL,
    "status" "KycStatus" NOT NULL DEFAULT 'PENDING',
    "redirect_url" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "kyc_sessions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "aml_screenings" (
    "id" TEXT NOT NULL,
    "investor_wallet" TEXT NOT NULL,
    "provider" TEXT NOT NULL,
    "clear" BOOLEAN NOT NULL,
    "matches" JSONB NOT NULL,
    "screened_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "aml_screenings_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "offerings" (
    "token_address" TEXT NOT NULL,
    "chain_id" INTEGER NOT NULL,
    "name" TEXT NOT NULL,
    "symbol" TEXT NOT NULL,
    "decimals" INTEGER NOT NULL,
    "compliance_address" TEXT NOT NULL,
    "token_onchain_id" TEXT NOT NULL,
    "property_name" TEXT NOT NULL,
    "property_address" TEXT NOT NULL,
    "backing_value" DECIMAL(78,0) NOT NULL,
    "currency" TEXT NOT NULL,
    "tranche" JSONB NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "offerings_pkey" PRIMARY KEY ("token_address")
);

-- CreateTable
CREATE TABLE "siwe_nonces" (
    "nonce" TEXT NOT NULL,
    "address" TEXT,
    "domain" TEXT NOT NULL,
    "issued_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expires_at" TIMESTAMP(3) NOT NULL,
    "consumed_at" TIMESTAMP(3),

    CONSTRAINT "siwe_nonces_pkey" PRIMARY KEY ("nonce")
);

-- CreateTable
CREATE TABLE "admin_actions" (
    "id" TEXT NOT NULL,
    "actor_wallet" TEXT NOT NULL,
    "action" TEXT NOT NULL,
    "target_address" TEXT,
    "params" JSONB NOT NULL,
    "tx_hash" TEXT,
    "status" "AdminActionStatus" NOT NULL DEFAULT 'PENDING',
    "failure_reason" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "confirmed_at" TIMESTAMP(3),

    CONSTRAINT "admin_actions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "indexer_checkpoint" (
    "name" TEXT NOT NULL,
    "last_indexed_block" BIGINT NOT NULL,
    "safe_head" BIGINT NOT NULL,
    "updated_at" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "indexer_checkpoint_pkey" PRIMARY KEY ("name")
);

-- CreateTable
CREATE TABLE "indexed_blocks" (
    "block_number" BIGINT NOT NULL,
    "block_hash" TEXT NOT NULL,
    "parent_hash" TEXT NOT NULL,
    "indexed_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "indexed_blocks_pkey" PRIMARY KEY ("block_number")
);

-- CreateTable
CREATE TABLE "watched_contracts" (
    "address" TEXT NOT NULL,
    "kind" "WatchedKind" NOT NULL,
    "deploy_block" BIGINT NOT NULL,
    "backfilled_from_block" BIGINT,
    "backfill_complete" BOOLEAN NOT NULL DEFAULT false,
    "discovered_at_block" BIGINT,
    "active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "watched_contracts_pkey" PRIMARY KEY ("address")
);

-- CreateTable
CREATE TABLE "chain_events" (
    "id" TEXT NOT NULL,
    "tx_hash" TEXT NOT NULL,
    "log_index" INTEGER NOT NULL,
    "block_number" BIGINT NOT NULL,
    "block_hash" TEXT NOT NULL,
    "contract_address" TEXT NOT NULL,
    "event_name" TEXT NOT NULL,
    "args" JSONB NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "chain_events_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "transfers" (
    "tx_hash" TEXT NOT NULL,
    "log_index" INTEGER NOT NULL,
    "block_number" BIGINT NOT NULL,
    "block_hash" TEXT NOT NULL,
    "token_address" TEXT NOT NULL,
    "from_address" TEXT NOT NULL,
    "to_address" TEXT NOT NULL,
    "value" DECIMAL(78,0) NOT NULL,
    "kind" "TransferKind" NOT NULL,
    "timestamp" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "transfers_pkey" PRIMARY KEY ("tx_hash","log_index")
);

-- CreateTable
CREATE TABLE "holdings" (
    "token_address" TEXT NOT NULL,
    "wallet_address" TEXT NOT NULL,
    "balance" DECIMAL(78,0) NOT NULL,
    "frozen_tokens" DECIMAL(78,0) NOT NULL,
    "address_frozen" BOOLEAN NOT NULL DEFAULT false,
    "last_block" BIGINT NOT NULL,

    CONSTRAINT "holdings_pkey" PRIMARY KEY ("token_address","wallet_address")
);

-- CreateTable
CREATE TABLE "holder_counts" (
    "compliance_address" TEXT NOT NULL,
    "count" INTEGER NOT NULL,
    "last_block" BIGINT NOT NULL,

    CONSTRAINT "holder_counts_pkey" PRIMARY KEY ("compliance_address")
);

-- CreateTable
CREATE TABLE "token_state" (
    "token_address" TEXT NOT NULL,
    "paused" BOOLEAN NOT NULL DEFAULT false,
    "total_supply" DECIMAL(78,0) NOT NULL,
    "last_block" BIGINT NOT NULL,

    CONSTRAINT "token_state_pkey" PRIMARY KEY ("token_address")
);

-- CreateTable
CREATE TABLE "reorgs" (
    "id" TEXT NOT NULL,
    "detected_at" TIMESTAMP(3) NOT NULL,
    "detected_at_block" BIGINT NOT NULL,
    "common_ancestor" BIGINT NOT NULL,
    "depth" INTEGER NOT NULL,
    "events_removed" INTEGER NOT NULL,
    "derived_keys_recomputed" INTEGER,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "reorgs_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "claims_identity_address_topic_issuer_address_key" ON "claims"("identity_address", "topic", "issuer_address");

-- CreateIndex
CREATE UNIQUE INDEX "kyc_sessions_provider_session_ref_key" ON "kyc_sessions"("provider", "session_ref");

-- CreateIndex
CREATE INDEX "chain_events_block_number_idx" ON "chain_events"("block_number");

-- CreateIndex
CREATE INDEX "chain_events_contract_address_event_name_idx" ON "chain_events"("contract_address", "event_name");

-- CreateIndex
CREATE UNIQUE INDEX "chain_events_tx_hash_log_index_key" ON "chain_events"("tx_hash", "log_index");

-- CreateIndex
CREATE INDEX "transfers_token_address_from_address_idx" ON "transfers"("token_address", "from_address");

-- CreateIndex
CREATE INDEX "transfers_token_address_to_address_idx" ON "transfers"("token_address", "to_address");

-- CreateIndex
CREATE INDEX "reorgs_detected_at_idx" ON "reorgs"("detected_at");

