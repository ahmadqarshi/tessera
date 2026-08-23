# Tessera — RWA Tokenization & Compliance Platform

Institutional real-world-asset (RWA) tokenization platform. Real estate tokenized as
**ERC-3643 (T-REX)** permissioned security tokens on **Polygon**, with on-chain KYC/AML
compliance, a custom chain indexer, and two portals (investor + agent console).

This is a **public portfolio repository**. Code quality, documentation, and test rigor are
part of the deliverable — treat every file as if a hiring engineer will read it.

---

## Golden rules

1. **Never reimplement audited infrastructure.** T-REX and ONCHAINID are consumed as git
   submodules under `contracts/lib/`. Extend via the `IModule` interface; do not fork or
   edit vendored contracts.
2. **Never put PII on-chain.** Only claim signatures + minimal metadata. Personal data
   stays with the KYC provider (or Postgres in mock mode, labeled demo-only).
3. **Never commit secrets.** Private keys and API keys live in `.env` (gitignored).
   `.env.example` carries placeholder values only.
4. **The repo must clone-and-run with zero paid accounts.** Mock KYC/AML adapters are the
   default. Any change that breaks `pnpm dev` on a fresh clone is a bug.
5. **Reads come from the indexer-backed API, not direct chain calls** — unless the value is
   inherently live/unindexed.
6. **Writes split by portal.** Investor actions are client-signed (wagmi). Agent/admin
   privileged actions are API mutations signed server-side by the agent wallet. Never
   client-sign a privileged action.
7. **Two backend keys, never merged.** `CLAIM_ISSUER_PRIVATE_KEY` only signs claims;
   `AGENT_PRIVATE_KEY` only performs token operations. Separate blast radius.

## Chain of record

**Polygon** — local Anvil (`31337`) by default, **Polygon Amoy (`80002`)** for the public
showcase. ⚠️ The design mockups in `design/` display `Base · 8453` as placeholder copy.
**Ignore that.** Never copy chain IDs, addresses, or block numbers out of the design HTML —
they are visual filler. Chain config comes from env + `packages/shared/addresses.*.json`.

## Monorepo layout

```
contracts/          Foundry — T-REX + ONCHAINID + custom compliance module
apps/api/           NestJS REST API (auth, claims, agent ops, providers)
apps/indexer/       NestJS worker — chain → Postgres
apps/web-investor/  Next.js investor portal
apps/web-admin/     Next.js agent console
packages/shared/    TS types, ABIs, address book, Zod schemas
```

Each workspace has its own `CLAUDE.md` with local rules. Read it before working in that
workspace.

## Commands

```bash
pnpm install
docker compose -f infra/docker-compose.yml up -d   # postgres + anvil
pnpm contracts:deploy:local
pnpm db:migrate && pnpm seed
pnpm dev                    # turbo: api + indexer + both portals
pnpm test                   # forge test + vitest across workspaces
pnpm lint && pnpm typecheck
```

## Conventions

- TypeScript **strict**, no `any`. No `as` casts to silence the compiler — fix the type.
- Token amounts are **`bigint`** end to end. Never `number`. Use viem `parseUnits` /
  `formatUnits` at the boundaries only.
- Addresses typed as viem `Address`, validated with `isAddress` at every entry point.
- Conventional Commits. Small, focused commits.
- Every new module ships with tests. Contracts additionally require fuzz + invariant coverage.

## Design source of truth

Static Claude Design mockups live in each frontend's `design/` folder. They are the visual
contract: **match them exactly**. Do not redesign, do not "improve" spacing or color.
See `.claude/skills/design-tokens/SKILL.md` for the token mapping.

## What this repo demonstrates (keep true)

| Signal | Location |
| --- | --- |
| ERC-3643 / ONCHAINID / transfer restrictions | `contracts/` |
| Fuzz + invariant testing, forced-transfer & pause edge cases | `contracts/test/` |
| Reorg-safe event indexing to Postgres | `apps/indexer/` |
| Full-stack Web3 architecture | monorepo as a whole |
