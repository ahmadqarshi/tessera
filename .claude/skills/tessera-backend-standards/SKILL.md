---
name: tessera-backend-standards
description: Standards, invariants, and per-prompt workflow for the Tessera ERC-3643 backend — the NestJS API (apps/api) and the chain indexer (apps/indexer). Use for any Phase 2 or Phase 3 work: Prisma schema and migrations, viem chain clients, SIWE auth and the agent role guard, ONCHAINID identity and claim issuance, agent token operations, transfer pre-checks, event indexing, reorg handling, and derived read models. Covers key separation, amount handling, table ownership, the required reading list, and the definition of done.
---

# Tessera backend standards

Constraints and workflow for `apps/api` and `apps/indexer`. This skill is the operating manual;
the authority for on-chain behaviour is always the vendored source.

## Load the right reference

Read the shared rules below, then load exactly one:

| Working in | Load |
| --- | --- |
| `apps/api` (Phase 2) | `references/api-standards.md` |
| `apps/indexer` (Phase 3) | `references/indexer-standards.md` |

Work that spans both (a schema change the indexer consumes, a read model the API serves) needs
both.

## Required reading before writing code

Do not skip this. Several rules below exist because the vendored source contradicts the design
docs, and the source wins every time.

- `CLAUDE.md` at the repo root, and the `CLAUDE.md` for the workspace being changed
- `contracts/NOTES.md` — the verified map of the vendored T-REX and ONCHAINID sources, with
  `file:line` citations against pinned submodule SHAs. Sections that matter most:
  - §3 `IToken` operation table · §3a which operations are pause-gated
  - §4 event tables with exact parameter lists and indexed flags · §4.4 `HolderCountChanged`
  - §5 claims and keys · §5a the management super-key · §5b **the pinned claim data payload**
  - §6 deployment wiring order · §7 **deviations from the docs**
- `docs/TASKS.md`, the "Phase 1 outcomes that constrain later phases" table — 16 numbered
  findings. Rules below cite them by number.

`NOTES.md` is authoritative over any summary, including `docs/TASKS.md` and this skill. If a
rule here disagrees with the vendored source, follow the source and report the discrepancy.

## Shared invariants

These hold in both workspaces.

1. **TypeScript strict.** No `any`, no `as` casts to silence the compiler, no `@ts-ignore`.
2. **Addresses come from the shared loaders** in `packages/shared` — the address book
   (`addresses.local.json` / `addresses.amoy.json`) and the seed manifest (`seed.local.json`).
   Never hardcode an address, a deploy block, or a private key. (Finding 15)
3. **`deployBlock` in the address book is the pre-deploy chain tip** — a deliberately
   conservative floor. Use it as written; do not optimise it forward. (Finding 12)
4. **Amounts are `bigint` in memory, `Decimal(78,0)` in the database, decimal strings in JSON.**
   Never a JS number, never a float. A `Number` cast silently loses precision above 2^53 and the
   corruption is not detectable downstream.
5. **Addresses are stored and compared lowercased**, everywhere, without exception.
6. **Zero-value transfers do not exist on this token.** `ModularCompliance` requires
   `_value > 0`, so a zero-value transfer reverts and no zero-value `Transfer` log is ever
   emitted. Reject `amount == 0` at the API boundary with its own reason; do not write
   defensive zero handling in the indexer. (Finding 8)
7. **Never parse on-chain revert strings.** Every gate failure produces the same generic
   `"Transfer not possible"`. Diagnose gates individually. (Finding 9)
8. **Single-writer rule for every table.** The API owns `claims`, `investors`, `offerings`,
   `admin_actions`, `kyc_sessions`, `aml_screenings`, `siwe_nonces`. The indexer owns
   `chain_events`, `transfers`, `holdings`, `holder_counts`, `token_state`,
   `claim_chain_state`, `indexed_blocks`, `indexer_checkpoint`, `watched_contracts`, `reorgs`.
   No table has two writers. `claims` and `claim_chain_state` are a deliberate split — see
   either reference file for why.
9. **Local Anvil is the default target.** `CHAIN_ENV` defaults to `local`; everything runs
   against `addresses.local.json` and `seed.local.json`. Amoy is a config switch, never a code
   path.
10. **Conventional commits. Do not commit** — leave changes staged and report.

## Definition of done

Run these and paste the real output. A summary of what you believe passed is not evidence.

```
pnpm --filter @tessera/<workspace> typecheck
pnpm --filter @tessera/<workspace> lint
pnpm --filter @tessera/<workspace> test
```

Plus the prompt's own acceptance gate.

Every prompt also requires:

- Unit tests for every service, guard, and handler added
- The documentation the prompt names, updated in the same pass — not deferred
- Structured logging, with no key material, seed, or signature in any log line

## Report format

Close every session with:

- **Files created and changed**, grouped by workspace
- **Acceptance gate output**, verbatim
- **Source contradictions** — anywhere the vendored source disagreed with `NOTES.md`, the
  prompt, or this skill, with the `file:line` citation
- **Undirected decisions** — anything decided that the prompt did not specify, and why
- **Blocked work** — anything deliberately left unimplemented, with the reason. A scaffolded
  `501` with a clear reason code is a valid outcome; a silently widened permission is not.

## Escalation

Stop and report rather than improvising when:

- An operation needs a signer the backend does not hold. Do not reuse the agent key, do not
  call `addKey` to widen a role, do not add an env var on your own initiative.
- A schema change would give a table a second writer.
- Making a test pass would require weakening an invariant above.

These are decisions for the planning session, not the coding session.