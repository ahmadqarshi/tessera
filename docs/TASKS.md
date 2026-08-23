# Tessera — build task list

Ordered by dependency. Each phase ends at a demoable state. **Ship Phase 1 publicly before
starting Phase 2** — it is the single strongest artifact and stands alone.

Legend: `[CORE]` required · `[STRETCH]` optional depth

---

## Phase 0 — Scaffold  (~1 day)

- [ ] Create repo, copy in `.claude/`, all `CLAUDE.md` files, and `design/` mockups
- [ ] Run the scaffold prompt (`docs/SCAFFOLD-PROMPT.md`)
- [ ] **Gate: `forge build` green with T-REX + ONCHAINID submodules resolved** ← the real hurdle
- [ ] `pnpm install && pnpm lint && pnpm typecheck && pnpm build` all green
- [ ] `docker compose up -d` → postgres + anvil healthy
- [ ] Tailwind preset carries the Tessera tokens; fonts load in both apps
- [ ] CI green on first push; repo public

---

## Phase 1 — On-chain  (~1 week) — *the standalone artifact*

Proves: ERC-3643, ONCHAINID, transfer restrictions, edge-case testing, verified contract.

**Deploy & wire**
- [ ] `script/Deploy.s.sol` — manual wiring, exact order from the `trex-contracts` skill
- [ ] Verify `bindIdentityRegistry` and `bindToken` are called (most common silent bug)
- [ ] Agent wallet granted agent role on **both** Token and IdentityRegistry
- [ ] ONCHAINID: Identity impl → ImplementationAuthority → IdFactory → ClaimIssuer
- [ ] Claim-issuer key registered as claim key (purpose 3)
- [ ] Trusted issuer added for topics `[1,2]`; topics `1` and `2` required

**Identity & claims**
- [ ] `script/Seed.s.sol` — deploy investor Identity, `registerIdentity`, sign claim
      (ERC-735 scheme 1, **not** EIP-712), `addClaim`
- [ ] **Milestone: verified investor receives tokens; unverified wallet transfer reverts** ←
      the green/red pair that proves the whole architecture
- [ ] Seed set: 2 verified investors, 1 unverified wallet, 2 property tokens, distributions

**Custom module**
- [ ] `MaxInvestorsModule` implementing `IModule`
- [ ] Bind to `ModularCompliance`; holder count correct across transfer/mint/burn/zeroing

**Tests** (`/audit-contracts`)
- [ ] Unit: unverified receiver · non-agent forcedTransfer · paused · exceeds `balance-frozen` ·
      forcedTransfer to unverified still reverts
- [ ] Fuzz: partial freeze bounds · holder cap under fuzzed sequences
- [ ] Invariant: `sum(balanceOf)==totalSupply` · holders ≤ cap · `frozen ≤ balance`
- [ ] Reentrancy test or documented finding that no hook makes external calls
- [ ] `solidity-auditor` clean of Critical/High

**Ship**
- [ ] Deploy to Polygon Amoy; `forge verify-contract` on PolygonScan
- [ ] Addresses → `packages/shared/addresses.amoy.json` + root README
- [ ] README: architecture, "what this demonstrates" map, licensing note on vendored modules
- [ ] **Push and share. This alone is portfolio-ready.**

`[STRETCH]` refactor deploy to `TREXFactory` + `TREXImplementationAuthority`

---

## Phase 2 — Backend core  (~3–4 days)

- [ ] Prisma schema + first migration (all tables from the spec, incl. `indexer_checkpoint`,
      `indexed_blocks`, unique `(tx_hash, log_index)` on transfers)
- [ ] `ChainModule` — viem public client + **two separate** wallet clients (Agent, ClaimIssuer)
- [ ] `AuthModule` — SIWE nonce/verify → JWT; single-use nonces, domain-bound
- [ ] Agent-role guard checks the **on-chain** role (allowlist fallback only when `CHAIN_ENV=local`)
- [ ] `IdentityModule` — deploy/register ONCHAINID, set country
- [ ] `ClaimIssuerModule` — build digest, sign, `addClaim`, revoke
- [ ] `AgentModule` — mint, distribute, pause/unpause, freeze address, partial freeze,
      forcedTransfer; **every call writes an `admin_actions` audit row**
- [ ] `KycModule` + `AmlModule` — adapter interfaces, Mock implementations (default)
- [ ] `TokenModule` (offerings metadata) + `ComplianceModule` (topics, issuers, module params)
- [ ] Transfer pre-check endpoint returning `{ allowed, reason }` with regulator-repeatable
      reason strings
- [ ] Tests: unit per service; e2e happy path and blocked path
- [ ] **Milestone: drive the entire Phase 1 flow over HTTP**

---

## Phase 3 — Indexer  (~3–4 days) — *the Q3 headline*

Build incrementally, testing each guarantee as you add it.

- [ ] Naive `getLogs` over bounded ranges → Postgres (events only)
- [ ] Persisted cursor (`indexer_checkpoint`); resume on restart
- [ ] Confirmations buffer (`safeHead = latest - CONFIRMATIONS`, config-driven)
- [ ] Idempotent upserts on `(tx_hash, log_index)`; **derived-state updates idempotent too**
- [ ] Block-hash tracking + reorg detection + rollback of events **and** derived rows
- [ ] Single DB transaction per batch (events + hashes + checkpoint together)
- [ ] Derived read models: `holdings`, holder counts, frozen amounts, `transfers`
- [ ] Backfill from `deploy_block`
- [ ] Tests: idempotent replay · reorg rollback · restart-without-gaps
- [ ] `/verify-indexer` → all four guarantees HOLD
- [ ] README soundbite documented

---

## Phase 4 — Investor portal  (~4–5 days)

`/implement-screen investor <name>` per screen, in order:

- [ ] Design system components from tokens (buttons incl. destructive, inputs, table, badges,
      modal, toast) + domain primitives (address chip 6/4, claim chips, pre-check panel)
- [ ] Providers shell: wagmi + RainbowKit + TanStack Query + SIWE session
- [ ] **Sign in** — idle · connecting · waiting for signature · rejected
- [ ] **Identity verification** — connected → submitting → in review → verified
- [ ] **Offerings** — grid, filters, empty state
- [ ] **Offering detail** — backing figure, compliance requirements, gated Invest CTA
- [ ] **Holdings** — balances with **frozen called out**, claim status
- [ ] **Transfer** — live pre-check; **both allowed and blocked variants**; submit disabled
      until `allowed: true`; reason rendered verbatim
- [ ] **Activity** — history, address chips, explorer links
- [ ] `design-fidelity-reviewer` clean

---

## Phase 5 — Agent console  (~5–6 days)

`/implement-screen admin <name>`. Remember: **no `useWriteContract` in this app.**

- [ ] **Operator sign in** — SIWE + on-chain role check
- [ ] **Agent role required** — denial state (wallet, roles found, tokens checked)
- [ ] **Dashboard** — supply, holders, frozen total, pause state, admin-action feed
- [ ] **Investors** — list + detail; issue/revoke claims, register identity, set country
- [ ] **Compliance rules** — topics, trusted issuers, module parameters
- [ ] **Token controls** — mint/distribute, pause/unpause, freeze address, partial freeze,
      forced transfer; typed-confirmation modal on each destructive action
- [ ] Global "token paused" banner; visible session expiry
- [ ] **Providers** — KYC/AML/identity selection; API keys write-only, masked on display
- [ ] **Audit log** — filterable; every mutation invalidates `['audit']`
- [ ] `design-fidelity-reviewer` clean

---

## Phase 6 — Polish & publish  (~2–3 days)

- [ ] One-command bootstrap verified on a **fresh clone with no accounts**
- [ ] README: architecture diagram, verified Amoy addresses, "what this demonstrates" map,
      quickstart, security notes, licensing
- [ ] Demo GIFs: compliant transfer · blocked transfer with reason · agent freeze · forced transfer
- [ ] Seed data polished (real-estate names, plausible tranche sizes)
- [ ] CI badges; `pnpm test` green end to end
- [ ] Security notes: key separation rationale, no PII on-chain, agent power is break-glass,
      trust model limits

---

## Stretch backlog

- [ ] Real Persona sandbox (hosted flow + verified webhooks)
- [ ] Real AML via self-hosted OpenSanctions/yente
- [ ] `TREXFactory` deployment path
- [ ] Additional modules: lock-ups, supply cap, transfer fees
- [ ] Wallet recovery flow demo
- [ ] The Graph subgraph as an alternative indexer + README comparison
- [ ] Gasless onboarding via meta-tx / EIP-2612 permit
- [ ] Playwright e2e + coverage badges

---

## Timeline

| Phase | Focused | Part-time |
| --- | --- | --- |
| 0–1 | ~1.5 weeks | ~3 weeks |
| 2–3 | ~1.5 weeks | ~3 weeks |
| 4–6 | ~2 weeks | ~4 weeks |

**Phase 1 is ~80% of the interview value for ~20% of the effort.** Ship it standalone, then
build the rest in the open on top of it.
