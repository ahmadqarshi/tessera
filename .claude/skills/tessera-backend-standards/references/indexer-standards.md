# Indexer standards (`apps/indexer`, Phase 3)

Load alongside the shared invariants in `SKILL.md`. Findings 8, 10, 11, 12 land here.

## Schema

The indexer imports the Prisma client generated from `apps/api/prisma/schema.prisma`. It does
**not** define its own schema and does **not** run its own migrations. A missing column is added
to the API schema and migrated there.

## The four guarantees

Each was added by its own prompt with its own test. Do not merge them, and do not weaken one to
make another pass. The value of this phase is that each correctness property was demonstrated
separately.

1. **Idempotent replay.** Re-indexing any range produces byte-identical database state.
2. **Reorg rollback.** A reorg is detected and fully rolled back — events *and* derived state.
3. **Restart without gaps.** A kill mid-run loses nothing and duplicates nothing.
4. **Dynamic identity discovery.** An identity registered mid-run is discovered, backfilled,
   and indexed without a restart.

`pnpm verify:indexer` demonstrates all four in one run and exits non-zero on any failure.

## Idempotency: absolute versus relative

The rule that makes replay and rollback tractable. Prefer absolute assignment wherever the
event carries an absolute value; where it does not, guard the update so a replay cannot
double-apply.

| Derived field | Source | Update |
| --- | --- | --- |
| `holder_counts.count` | `HolderCountChanged` | **Absolute** — assign, never increment |
| `token_state.paused` | `Paused` / `Unpaused` | **Absolute** |
| `holdings.addressFrozen` | `AddressFrozen` | **Absolute** |
| `claim_chain_state.*` | ERC-735 + revocation events | **Absolute** |
| `holdings.balance` | `Transfer` | Relative — guarded by applied `(txHash, logIndex)` |
| `holdings.frozenTokens` | `TokensFrozen` / `TokensUnfrozen` | Relative — deltas, same guard |
| `token_state.totalSupply` | `Transfer` mints minus burns | Relative — same guard |

An idempotent event insert paired with an unguarded `balance += value` is still broken. The
guard must survive rollback, so design it before the rollback work rather than retrofitting it.

**Never re-derive holder counts from `Transfer` logs.** `HolderCountChanged(compliance,
newCount)` fires on real zero↔non-zero crossings and carries the post-crossing count. Consuming
it directly is not merely faster — re-derivation drifts after a rollback, because rolled-back
transfers must un-count exactly, whereas the event replays idempotently to the same value.
(Finding 10, `NOTES.md` §4.4)

## Transactions

Every batch is **one** `prisma.$transaction`: events, transfers, derived rows, block hashes, the
reorg row if any, and the checkpoint. All of it or none of it. A partial batch is the failure
this phase exists to prevent. A reader mid-batch must see either the pre-batch or post-batch
state, never a torn one.

Set explicit `timeout` and `maxWait` — a large backfill batch exceeds Prisma's 5s default and
the resulting error is confusing.

## Reorgs

- Every indexed block writes `blockNumber`, `blockHash`, `parentHash`.
- Detect on a tip-hash mismatch **and** on a parent-linkage break with a matching tip hash.
- Walk back to the common ancestor, bounded by `INDEXER_MAX_REORG_DEPTH`. Exceeding it **halts
  with a fatal error** rather than guessing — an unbounded reorg is an operator problem.
- Rollback touches **indexer-owned tables only**. It must not read or write `claims`. A claim
  whose `ClaimAdded` is orphaned simply loses its `claim_chain_state` row; the API row is
  untouched and `effectiveClaimStatus` reports `PENDING_SUBMISSION` again, which is accurate —
  the submission genuinely did not survive. Correct behaviour falls out of the schema with no
  special-casing, and that is the point of the split.
- Every reorg writes a `reorgs` row and a structured log: `detectedAtBlock`, `commonAncestor`,
  `depth`, `eventsRemoved`, `derivedKeysRecomputed`.

## Dynamic contract set

Each investor gets their **own** ONCHAINID contract. Those addresses do not exist when the
indexer starts, so `ClaimAdded` / `ClaimChanged` / `ClaimRemoved` come from addresses that
cannot be known in advance. A static address list silently misses every claim event, and the
failure mode is an empty table rather than an error. (Finding 11)

- Discover via `IdentityRegistered` on the IdentityRegistry.
- Find each identity's **own** deploy block — it may predate its registration. Do not assume
  they are the same block.
- Backfill each from its deploy block to the current checkpoint; the main loop covers
  `(checkpoint, safeHead]`. There must be no window between the two, and the boundary is tested,
  not assumed.
- Persist the watch set in the database so it survives restart.
- `IdentityRemoved` sets `active: false` — never delete the row, its historical events remain
  valid.
- Also watch the **ClaimIssuer** for revocation events. An issuer-side `revokeClaim` never
  touches the investor's identity, so it is invisible from the identity contracts alone.
- Chunk the `getLogs` address array; providers cap it.

## Confirmations

`safeHead = chainHead - CONFIRMATIONS`. Never index above it. A tick where `safeHead` is below
the next `fromBlock` is a no-op, not an error. Persist `safeHead` so the API's staleness
contract has real data. `CONFIRMATIONS = 0` is a local-only convenience; the local default
should still be non-zero so the buffer logic is exercised in development.

## Event handling

- One `getLogs` call per range covering all watched addresses and all registered topics — not
  one call per contract.
- Adaptive range reduction: halve on a provider limit error, down to a floor of one block, then
  fail loudly. Log every reduction.
- Serialise event args through one shared helper: bigints to decimal strings, addresses
  lowercased, bytes as `0x`-prefixed hex. A raw bigint throws on `JSON.stringify` and a
  `Number` cast silently loses precision.
- An unrecognised `topic0` is logged at debug and skipped, never thrown.
- `UpdatedTokenInformation` marks its **string** parameters `indexed`, so they arrive as keccak
  hashes. Name and symbol must be read via `name()` / `symbol()` view calls. (`NOTES.md` §4.1)
- Forced transfers emit the **same `Transfer` event** as ordinary ones. If you cannot
  distinguish them from the log alone, say so and default to `TRANSFER`. Do not invent a
  distinction the chain does not provide.

## Reconciliation

`pnpm --filter @tessera/indexer reconcile` reads the chain directly — `balanceOf`,
`getFrozenTokens`, `isFrozen`, `paused`, `totalSupply`, `investorCount`, and per-identity
`getClaim` / `isClaimValid` — and diffs it against the derived tables, **reporting without
fixing**.

This is the correctness oracle. It catches the subtle derived-state bug that unit tests
structurally cannot, because it compares against ground truth rather than against expectations
written by the same person who wrote the bug. `isClaimValid` in particular is the truth that
`present && !revoked` is only approximating; a divergence there is the most valuable thing this
command can surface.

## Testing

- One integration file per guarantee, named for it, each independent and each resetting both
  the database and the chain snapshot.
- Induce failures rather than asserting their absence: `evm_snapshot` / `evm_revert` for
  reorgs, a fault-injection hook for atomicity, a real process kill for restart.
- A stale address book after an Anvil restart — a watched contract with no code — must fail
  **loudly at boot**, naming the address and telling the operator to redeploy. This is the most
  common local-development confusion; make the error do the explaining.