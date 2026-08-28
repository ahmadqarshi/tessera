# apps/indexer — NestJS chain indexer

Syncs Polygon events into PostgreSQL read models. **This is the repo's headline subsystem** —
it exists to prove reorg-safe, gap-free, exactly-once-effective indexing. Treat correctness
here as non-negotiable and keep the code readable enough to be reviewed as a work sample.

## The four guarantees (every change must preserve all four)

1. **No gaps** — a persisted cursor (`indexer_checkpoint`) resumes exactly where the last run
   stopped. Restart mid-range must never skip blocks.
2. **No unconfirmed state** — never index past `safeHead = latestBlock - CONFIRMATIONS`.
3. **No duplicates** — every event row is unique on `(tx_hash, log_index)`; all writes are
   idempotent upserts. Replaying a range is a no-op.
4. **Reorg-safe** — block hashes are tracked in `indexed_blocks`. On hash mismatch, roll back
   events and derived state for `block_number >= forkPoint`, reset cursor, re-index.

## Non-negotiables

- **Poll `getLogs` over bounded block ranges.** Do not use websocket subscriptions as the
  primary source — they drop events on reconnect. (A websocket may only ever be a latency hint
  that triggers a poll.)
- Each batch is written in **one database transaction**: events + block hashes + checkpoint
  advance together, or not at all. A partial batch is a correctness bug.
- Backfill starts at each contract's `deploy_block` from the address book.
- `CONFIRMATIONS` is config: `1` local, `32` Amoy. Never hardcode.
- Derived read models (`holdings`, holder counts, frozen amounts) are rebuilt from events —
  never written directly by the API.

## Main loop shape

```ts
const latest = await client.getBlockNumber();
const safeHead = latest - CONFIRMATIONS;
let from = checkpoint.lastBlock + 1n;
if (from > safeHead) { await sleep(POLL_MS); return; }
if (await reorgDetected(checkpoint)) { await rollbackFrom(forkPoint); return; }

const to = min(from + BATCH - 1n, safeHead);
const logs = await client.getLogs({ address: tokens, fromBlock: from, toBlock: to, events });

await db.transaction(async (t) => {
  for (const log of decode(logs)) await applyEvent(t, log);  // idempotent
  await recordBlockHashes(t, from, to);
  await setCheckpoint(t, to, blockHashAt(to));
});
```

## Events indexed

`Transfer` · `AddressFrozen` · `TokensFrozen` / `TokensUnfrozen` · `Paused` / `Unpaused` ·
`IdentityRegistered` / `IdentityRemoved` · claim-topic and trusted-issuer changes ·
`ModularCompliance` module add/remove · `RecoverySuccess`

## Required tests (do not merge without these)

- **Idempotency** — process a range twice, assert zero duplicate rows and identical state.
- **Reorg** — fork below a processed block (Anvil snapshot / `anvil_reorg`), assert rollback
  and re-index converge to correct final state.
- **Restart** — kill mid-range, restart, assert no gaps and no double-counting.

## README obligation

Keep this claim accurate and documented in the root README, since it is the artifact reviewers
look for: *confirmations buffer + hash-tracked reorg rollback + `(txHash, logIndex)`
idempotency + persisted cursor = exactly-once effective processing across restarts and reorgs.*

## Non-negotiable invariants

Detail and rationale live in the `tessera-backend-standards` skill. These are restated here
because they must be in context for every session.

- **Four guarantees, each with its own test:** idempotent replay, reorg rollback, restart
  without gaps, dynamic identity discovery. Never weaken one to make another pass.
- **One database transaction per batch** — events, derived rows, block hashes, and the
  checkpoint together or not at all.
- **Idempotency covers derived state, not just events.** An idempotent insert paired with an
  unguarded `balance += value` is still broken.
- **Consume `HolderCountChanged` directly.** Never re-derive holder counts from `Transfer` logs
  — re-derivation drifts after a rollback.
- **Investor identities are a dynamic address set.** Discover via `IdentityRegistered`, backfill
  each from its own deploy block, persist the watch set. Also watch the ClaimIssuer for
  revocation events. A static address list silently produces an empty claims table rather than
  an error.
- **`deployBlock` is the pre-deploy chain tip.** Use it as written; do not optimise it forward.
- **Rollback touches indexer-owned tables only.** It must never read or write `claims`.
- **The indexer writes no API-owned table.** It imports the API's Prisma client and defines no
  schema of its own.
- **Never index above `safeHead = chainHead - CONFIRMATIONS`.**
- **Amounts:** `bigint` in memory, `Decimal(78,0)` in the database, decimal strings in JSON.
  Serialise event args through the shared helper.
- **A watched contract with no code fails loudly at boot**, naming the address.

Stop and report rather than improvising when a change would give a table a second writer, or
when passing a test would require weakening any guarantee above.