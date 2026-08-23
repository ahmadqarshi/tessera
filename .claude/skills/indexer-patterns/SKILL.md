---
name: indexer-patterns
description: Use when working on apps/indexer or anything touching chain event ingestion, block cursors, reorg handling, idempotent event writes, or the Postgres read models (holdings, transfers, holder counts) derived from chain events.
---

# Reorg-safe chain indexing

The indexer is the repo's headline correctness artifact. Every change must preserve four
guarantees.

## The four guarantees

| # | Guarantee | Mechanism |
| --- | --- | --- |
| 1 | **No gaps** | persisted cursor in `indexer_checkpoint`; resume from `last_block` |
| 2 | **No unconfirmed state** | never index past `safeHead = latest - CONFIRMATIONS` |
| 3 | **No duplicates** | unique `(tx_hash, log_index)`; all writes idempotent upserts |
| 4 | **Reorg-safe** | hashes in `indexed_blocks`; on mismatch roll back `>= forkPoint` |

Together: **exactly-once effective processing across restarts and reorgs.**

## Non-negotiables

- **Poll `getLogs` over bounded ranges.** Websocket subscriptions drop events on reconnect and
  must never be the source of truth. (They may only trigger an earlier poll.)
- **One DB transaction per batch** — events, block hashes, and the checkpoint advance together
  or not at all. A partial batch is a correctness bug.
- Backfill starts at `deploy_block` from the address book.
- `CONFIRMATIONS` is config (`1` local, `32` Amoy). Never hardcode.
- Derived read models are rebuilt from events only. The API never writes them directly.

## Loop

```ts
const latest = await client.getBlockNumber();
const safeHead = latest - CONFIRMATIONS;
let from = checkpoint.lastBlock + 1n;
if (from > safeHead) { await sleep(POLL_MS); return; }

if (await reorgDetected(checkpoint)) { await rollbackFrom(forkPoint); return; }

const to = min(from + BATCH - 1n, safeHead);
const logs = await client.getLogs({ address: tokens, fromBlock: from, toBlock: to, events });

await db.transaction(async (t) => {
  for (const log of decode(logs)) await applyEvent(t, log);   // idempotent upsert
  await recordBlockHashes(t, from, to);
  await setCheckpoint(t, to, blockHashAt(to));
});
```

### Reorg detection & rollback

Compare the stored hash for the checkpoint block against the chain. On mismatch, walk back
through `indexed_blocks` to find the fork point, then in one transaction: delete events with
`block_number >= forkPoint`, rebuild affected derived rows, delete those `indexed_blocks`, and
reset the cursor to `forkPoint - 1`.

## Events

`Transfer` · `AddressFrozen` · `TokensFrozen` / `TokensUnfrozen` · `Paused` / `Unpaused` ·
`IdentityRegistered` / `IdentityRemoved` · claim-topic & trusted-issuer changes ·
`ModularCompliance` module add/remove · `RecoverySuccess`

## Derived read models

`holdings(token, holder, balance, frozen, holder_since)` · per-token `holder_count` ·
`transfers` · `compliance_events`. These are what the portals read.

Amounts are `bigint` in TS and `numeric` in Postgres — never float.

## Required tests

- **Idempotency** — process a range twice → zero duplicates, identical state.
- **Reorg** — fork below a processed block (Anvil snapshot / `anvil_reorg`) → rollback and
  re-index converge to correct final state.
- **Restart** — kill mid-range, restart → no gaps, no double-counting.

Do not merge indexer changes without all three passing.
