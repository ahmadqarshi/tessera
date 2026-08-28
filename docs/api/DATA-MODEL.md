# Tessera data model

The Postgres schema, one table per Prisma model. Source of truth:
[`apps/api/prisma/schema.prisma`](../../apps/api/prisma/schema.prisma). The indexer imports the
client generated from that one schema — there is no second schema.

Two conventions hold everywhere and are called out where they matter below:

- **Addresses** are stored as **lowercase 0x-hex**. Prisma does not enforce this at the column
  level, so writers normalise via `lowerAddress()` from `@tessera/shared` before persisting.
- **Amounts are `Decimal(78,0)`** — exact base-unit integers. A token amount is a uint256; it does
  not fit in a 32-bit `Int` and it silently loses precision above 2^53 as a `Float`/`Number`. 78
  digits is the width of `2^256 − 1`, so the widest possible balance round-trips exactly. Amounts
  are `bigint` in memory and decimal strings on the wire.

---

## Ownership

Single-writer, no exceptions. Each table has exactly one writer; the other side only reads.

| Table | Writer |
| --- | --- |
| `investors` | API |
| `claims` | API |
| `kyc_sessions` | API |
| `aml_screenings` | API |
| `offerings` | API |
| `siwe_nonces` | API |
| `admin_actions` | API |
| `claim_chain_state` | Indexer |
| `chain_events` | Indexer |
| `transfers` | Indexer |
| `holdings` | Indexer |
| `holder_counts` | Indexer |
| `token_state` | Indexer |
| `indexer_checkpoint` | Indexer |
| `indexed_blocks` | Indexer |
| `watched_contracts` | Indexer |
| `reorgs` | Indexer |

### Why `claims` and `claim_chain_state` are separate

`claims` is written **only** by the API; `claim_chain_state` is written **only** by the indexer.
There is deliberately no foreign key between them — they are joined on `(claimId, identityAddress)`
at read time. The reason is reorg rollback: the indexer must be able to delete and rebuild every
row it owns without knowing which columns belong to someone else. A single shared table would force
the rollback path to preserve the API's `PENDING_SUBMISSION` and expiry state column by column,
which is exactly the kind of coupling that makes rollback logic subtly and silently wrong.

The two tables also answer different questions, and the enum split reflects that. `claims.status`
tracks what the **operator** did: signed it, saw it submitted, let it lapse. `claim_chain_state`
tracks what the **chain** says: present, removed, revoked. Nothing writes `REVOKED` to
`claims.status` — revocation is *observed*, not *asserted*. `claims.revocationRequestedAt` and
`revocationTxHash` record that the API **asked**; `claim_chain_state.revoked` records that it
**happened**. The two are reconciled through the single `effectiveClaimStatus()` resolver in
`@tessera/shared`, whose precedence is: no chain row → `PENDING_SUBMISSION`; revoked → `REVOKED`;
not present → `REMOVED`; `expiresAt` passed → `EXPIRED`; otherwise `ACTIVE`.

### Why `claims.expiresAt` exists off-chain

ERC-735 has **no on-chain expiry field**. A claim on an identity is either present or not; the
chain has no notion of it lapsing. Expiry is therefore an off-chain concept: the API records
`expiresAt` and enforces it by requesting issuer-side `revokeClaim` when the time comes (Finding
4). The column is required to exist precisely because the chain cannot carry it — dropping it would
leave nowhere to express a time-boxed KYC/AML claim. `null` means the claim never expires.

---

## Enums

| Enum | Values | Purpose |
| --- | --- | --- |
| `ClaimStatus` | `PENDING_SUBMISSION`, `SUBMITTED`, `EXPIRED` | API-side off-chain claim lifecycle. No `REVOKED` — revocation is observed on chain. |
| `KycStatus` | `PENDING`, `APPROVED`, `DECLINED` | KYC provider session outcome. |
| `AdminActionStatus` | `PENDING`, `CONFIRMED`, `FAILED` | Lifecycle of a privileged agent operation. |
| `WatchedKind` | `TOKEN`, `IDENTITY_REGISTRY`, `IDENTITY_REGISTRY_STORAGE`, `MODULAR_COMPLIANCE`, `MAX_INVESTORS_MODULE`, `CLAIM_TOPICS_REGISTRY`, `TRUSTED_ISSUERS_REGISTRY`, `CLAIM_ISSUER`, `INVESTOR_IDENTITY` | Role of a watched contract, selecting the indexer's handlers. |
| `TransferKind` | `MINT`, `BURN`, `TRANSFER`, `FORCED` | Classification of a token movement. |

---

## Identity & compliance domain

### `investors` — API

| Column | Type | Purpose |
| --- | --- | --- |
| `wallet` | String (PK) | Investor wallet, lowercase hex. |
| `onchainId` | String? | ONCHAINID contract address; null until deployed. |
| `country` | Int | ISO-3166-1 numeric country code. |
| `displayName` | String | Human label for the investor. |
| `email` | String? | Contact email; optional. |
| `createdAt` | DateTime | Row creation time. |
| `updatedAt` | DateTime | Last update time. |

### `claims` — API

The off-chain claim lifecycle only. Unique on `(identityAddress, topic, issuerAddress)`.

| Column | Type | Purpose |
| --- | --- | --- |
| `id` | String (PK, cuid) | Surrogate key. |
| `identityAddress` | String | Investor identity bound in the signed digest; lowercase hex. |
| `topic` | Int | ONCHAINID claim topic (1 = KYC, 2 = AML). |
| `issuerAddress` | String | ClaimIssuer bound in the `claimId`; lowercase hex. |
| `claimId` | String | bytes32 hex = `keccak256(abi.encode(issuer, topic))`. |
| `signature` | String | ERC-735 scheme-1 signature, hex. |
| `data` | String | Raw claim payload bytes as hex (the pinned per-topic label). |
| `uri` | String | Claim URI. |
| `status` | ClaimStatus | Off-chain lifecycle; never `REVOKED`. |
| `issuedAt` | DateTime | When the API signed the claim. |
| `expiresAt` | DateTime? | Off-chain expiry; null = never. **Exists off-chain because ERC-735 has no expiry field (Finding 4).** |
| `submittedTxHash` | String? | Tx in which the investor submitted `addClaim`. |
| `revocationRequestedAt` | DateTime? | When the API asked for revocation. |
| `revocationTxHash` | String? | Owner-signed `revokeClaim` tx the API sent. |

### `claim_chain_state` — Indexer

Chain reality for a claim, fully rebuildable on rollback. Composite PK `(claimId, identityAddress)`.

| Column | Type | Purpose |
| --- | --- | --- |
| `claimId` | String (PK) | bytes32 hex as emitted on chain. |
| `identityAddress` | String (PK) | Identity the claim lives on; lowercase hex. |
| `topic` | Int | Claim topic. |
| `issuerAddress` | String | Issuer address; lowercase hex. |
| `present` | Boolean | `ClaimAdded`/`ClaimChanged` → true, `ClaimRemoved` → false. |
| `revoked` | Boolean | Set by the ClaimIssuer's revocation event. |
| `signature` | String | Signature as recorded on chain, hex. |
| `data` | String | Data as recorded on chain, hex. |
| `addedBlock` | BigInt | Block of the first `ClaimAdded`. |
| `addedTxHash` | String | Tx of the first `ClaimAdded`. |
| `addedLogIndex` | Int | Log index of the first `ClaimAdded`. |
| `removedBlock` | BigInt? | Block of the `ClaimRemoved` that cleared `present`. |
| `revokedBlock` | BigInt? | Block of the revocation event. |
| `lastBlock` | BigInt | Highest block applied to this row. |

### `kyc_sessions` — API

Unique on `(provider, sessionRef)`.

| Column | Type | Purpose |
| --- | --- | --- |
| `id` | String (PK, cuid) | Surrogate key. |
| `investorWallet` | String | Investor wallet; lowercase hex. |
| `provider` | String | Provider name (`mock`, `persona`, …). |
| `sessionRef` | String | Provider-side session identifier. |
| `status` | KycStatus | Session outcome. |
| `redirectUrl` | String? | Hosted-flow redirect, when applicable. |
| `createdAt` | DateTime | Row creation time. |
| `updatedAt` | DateTime | Last update time. |

### `aml_screenings` — API

| Column | Type | Purpose |
| --- | --- | --- |
| `id` | String (PK, cuid) | Surrogate key. |
| `investorWallet` | String | Investor wallet; lowercase hex. |
| `provider` | String | Provider name. |
| `clear` | Boolean | True if no sanctions match. |
| `matches` | Json | Provider hit list `[{ list, score }]`; `[]` when clear. |
| `screenedAt` | DateTime | When the screening ran. |

---

## Token / offering domain

### `offerings` — API

Off-chain offering metadata. Live pause/supply come from `token_state` or a view call, not here.

| Column | Type | Purpose |
| --- | --- | --- |
| `tokenAddress` | String (PK) | Token address; lowercase hex. |
| `chainId` | Int | Chain of record. |
| `name` | String | Token name. |
| `symbol` | String | Token symbol. |
| `decimals` | Int | Token decimals. |
| `complianceAddress` | String | ModularCompliance address; lowercase hex. |
| `tokenOnchainId` | String | Token's ONCHAINID address; lowercase hex. |
| `propertyName` | String | Property display name. |
| `propertyAddress` | String | Postal address of the property (not an EVM address). |
| `backingValue` | Decimal(78,0) | Appraised backing value, minor units of `currency`. |
| `currency` | String | ISO-4217 code for `backingValue`. |
| `tranche` | Json | Tranche metadata (sizes, class labels). |
| `createdAt` | DateTime | Row creation time. |
| `updatedAt` | DateTime | Last update time. |

---

## Auth & audit

### `siwe_nonces` — API

| Column | Type | Purpose |
| --- | --- | --- |
| `nonce` | String (PK) | Single-use SIWE nonce. |
| `address` | String? | Signer address; lowercase hex, set at verify time. |
| `domain` | String | Domain the nonce is bound to. |
| `issuedAt` | DateTime | Issue time. |
| `expiresAt` | DateTime | Expiry; short TTL. |
| `consumedAt` | DateTime? | Set once; a second use is rejected. |

### `admin_actions` — API

Written `PENDING` before broadcast so the row survives a mid-flight crash; settled after.

| Column | Type | Purpose |
| --- | --- | --- |
| `id` | String (PK, cuid) | Surrogate key. |
| `actorWallet` | String | Agent wallet that acted; lowercase hex. |
| `action` | String | Dotted verb, e.g. `token.mint`. |
| `targetAddress` | String? | Primary subject; lowercase hex. |
| `params` | Json | Action params; amounts as decimal strings, never numbers. |
| `txHash` | String? | Broadcast transaction hash. |
| `status` | AdminActionStatus | Lifecycle state. |
| `failureReason` | String? | Reason on `FAILED`. |
| `createdAt` | DateTime | When the action was recorded (before broadcast). |
| `confirmedAt` | DateTime? | When it settled. |

---

## Indexer domain

### `indexer_checkpoint` — Indexer

| Column | Type | Purpose |
| --- | --- | --- |
| `name` | String (PK) | Logical stream name, e.g. `main`. |
| `lastIndexedBlock` | BigInt | Highest block processed. |
| `safeHead` | BigInt | Confirmed head (`latest − CONFIRMATIONS`). |
| `updatedAt` | DateTime | Last checkpoint update. |

### `indexed_blocks` — Indexer

| Column | Type | Purpose |
| --- | --- | --- |
| `blockNumber` | BigInt (PK) | Processed block number. |
| `blockHash` | String | Block hash. |
| `parentHash` | String | Parent hash, for reorg detection. |
| `indexedAt` | DateTime | When the block was indexed. |

### `watched_contracts` — Indexer

| Column | Type | Purpose |
| --- | --- | --- |
| `address` | String (PK) | Contract address; lowercase hex. |
| `kind` | WatchedKind | Contract role (selects handlers). |
| `deployBlock` | BigInt | Conservative backfill floor. |
| `backfilledFromBlock` | BigInt? | Lowest block already backfilled. |
| `backfillComplete` | Boolean | Whether backfill has finished. |
| `discoveredAtBlock` | BigInt? | Block a runtime-discovered contract was first seen. |
| `active` | Boolean | Whether the indexer still watches it. |
| `createdAt` | DateTime | Row creation time. |

### `chain_events` — Indexer

Raw event log. Unique on `(txHash, logIndex)` — the idempotency key. Indexed on `blockNumber` and
`(contractAddress, eventName)`.

| Column | Type | Purpose |
| --- | --- | --- |
| `id` | String (PK, cuid) | Surrogate key. |
| `txHash` | String | Transaction hash. |
| `logIndex` | Int | Log index within the tx. |
| `blockNumber` | BigInt | Block number. |
| `blockHash` | String | Block hash. |
| `contractAddress` | String | Emitting contract; lowercase hex. |
| `eventName` | String | Decoded event name. |
| `args` | Json | Decoded args; all bigints as strings. |
| `createdAt` | DateTime | When the event was recorded. |

### `transfers` — Indexer

Derived token-movement ledger. Composite PK `(txHash, logIndex)` — the idempotency key. Indexed on
`(tokenAddress, fromAddress)` and `(tokenAddress, toAddress)`.

| Column | Type | Purpose |
| --- | --- | --- |
| `txHash` | String (PK) | Transaction hash. |
| `logIndex` | Int (PK) | Log index within the tx. |
| `blockNumber` | BigInt | Block number. |
| `blockHash` | String | Block hash. |
| `tokenAddress` | String | Token; lowercase hex. |
| `fromAddress` | String | Sender; lowercase hex (0x0 for mint). |
| `toAddress` | String | Recipient; lowercase hex (0x0 for burn). |
| `value` | Decimal(78,0) | Amount, base units. |
| `kind` | TransferKind | Movement classification. |
| `timestamp` | DateTime | Block timestamp. |

### `holdings` — Indexer

Derived per-holder balances. Composite PK `(tokenAddress, walletAddress)`.

| Column | Type | Purpose |
| --- | --- | --- |
| `tokenAddress` | String (PK) | Token; lowercase hex. |
| `walletAddress` | String (PK) | Holder; lowercase hex. |
| `balance` | Decimal(78,0) | Current balance, base units. |
| `frozenTokens` | Decimal(78,0) | Partially frozen amount, base units. |
| `addressFrozen` | Boolean | Whole-address freeze flag. |
| `lastBlock` | BigInt | Highest block applied (stale-guard). |

### `holder_counts` — Indexer

| Column | Type | Purpose |
| --- | --- | --- |
| `complianceAddress` | String (PK) | ModularCompliance; lowercase hex. |
| `count` | Int | Distinct-holder count from `HolderCountChanged`. |
| `lastBlock` | BigInt | Highest block applied. |

### `token_state` — Indexer

| Column | Type | Purpose |
| --- | --- | --- |
| `tokenAddress` | String (PK) | Token; lowercase hex. |
| `paused` | Boolean | Current pause state. |
| `totalSupply` | Decimal(78,0) | Total supply, base units. |
| `lastBlock` | BigInt | Highest block applied. |

### `reorgs` — Indexer

Audit trail of chain reorganisations: one row each time the indexer rewinds the chain-derived
tables. Indexed on `detectedAt`. Written only by the indexer (Phase 3); defined now so the
single-migration story holds.

| Column | Type | Purpose |
| --- | --- | --- |
| `id` | String (PK, cuid) | Surrogate key. |
| `detectedAt` | DateTime | Wall-clock instant the reorg was detected. |
| `detectedAtBlock` | BigInt | Chain head at detection. |
| `commonAncestor` | BigInt | Last block shared by both branches (the rollback floor). |
| `depth` | Int | Blocks rewound (`detectedAtBlock − commonAncestor`). |
| `eventsRemoved` | Int | `chain_events` rows deleted during rollback. |
| `derivedKeysRecomputed` | Int? | Derived read-model keys rebuilt; null until computed. |
| `createdAt` | DateTime | Row creation time. |
