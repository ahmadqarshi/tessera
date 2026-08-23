# Tessera — RWA Tokenization & Compliance Platform

Institutional real-world-asset (RWA) tokenization platform. Real estate is tokenized as
**ERC-3643 (T-REX)** permissioned security tokens on **Polygon**, with on-chain KYC/AML
compliance, a reorg-safe chain indexer, and two portals (investor + agent console).

> **Status: scaffold.** This pass establishes the monorepo, toolchain, and a green build.
> Feature work is tracked in [`docs/TASKS.md`](docs/TASKS.md).

This is a **public portfolio repository** — code quality, documentation, and test rigor are
part of the deliverable.

## Architecture

```
contracts/          Foundry — ERC-3643/T-REX + ONCHAINID (submodules) + custom compliance module
apps/api/           NestJS REST API (auth, claims, agent ops, providers, indexer-backed reads)
apps/indexer/       NestJS worker — chain → Postgres (reorg-safe, exactly-once effective)
apps/web-investor/  Next.js investor portal (App Router)
apps/web-admin/     Next.js agent console (App Router)
packages/shared/    TS types, viem Address helpers, Zod schemas, ABIs, address-book loader
packages/config/    Shared ESLint / Prettier / tsconfig / Tailwind preset (design tokens)
infra/              docker-compose: Postgres 16 + Anvil
```

Built with **pnpm workspaces + Turborepo**. TypeScript is `strict` everywhere with no `any`;
token amounts are `bigint` end to end.

## Chain of record

**Polygon** — local **Anvil (31337)** by default, **Polygon Amoy (80002)** for the public
showcase. Chain config comes from environment variables plus
`packages/shared/addresses.{local,amoy}.json`.

## Quickstart

Clone-and-run with **zero paid accounts** — mock KYC/AML adapters are the default.

```bash
git clone --recurse-submodules <repo-url>
cd tessera
cp .env.example .env
pnpm install
docker compose -f infra/docker-compose.yml up -d   # Postgres + Anvil

pnpm build          # turbo: shared → apps
pnpm lint           # ESLint across every workspace
pnpm typecheck      # tsc --noEmit across every workspace
pnpm test           # vitest across workspaces

# Contracts
cd contracts && forge build && forge test
```

If you already cloned without submodules: `git submodule update --init --recursive`.

## Vendored contracts & licensing

The audited ERC-3643 suite and ONCHAINID are consumed as **git submodules** under
`contracts/lib/` and are never edited — compliance is extended via the `IModule` interface.

| Submodule | Source | Pin |
| --- | --- | --- |
| ERC-3643 / T-REX | [`ERC-3643/ERC-3643`](https://github.com/ERC-3643/ERC-3643) | `4.1.3` |
| ONCHAINID | [`onchain-id/solidity`](https://github.com/onchain-id/solidity) | `2.1.0` |
| OpenZeppelin Contracts | [`OpenZeppelin/openzeppelin-contracts`](https://github.com/OpenZeppelin/openzeppelin-contracts) | `v4.9.3` |
| OpenZeppelin Upgradeable | [`OpenZeppelin/openzeppelin-contracts-upgradeable`](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable) | `v4.9.3` |
| forge-std | [`foundry-rs/forge-std`](https://github.com/foundry-rs/forge-std) | `v1.9.7` |

> **Note on T-REX:** the original `TokenySolutions/T-REX` repository is deprecated and now
> redirects to the community-maintained `ERC-3643/ERC-3643`. We track the maintained fork; its
> `4.1.3` tag is byte-identical in the core contracts to Tokeny's `4.1.6`. Both pin solc
> `0.8.17`, which `contracts/foundry.toml` matches exactly.

## Security notes

- **No PII on-chain** — only claim signatures + minimal metadata; personal data stays with the
  KYC provider (or Postgres in mock mode, labeled demo-only).
- **Two backend keys, never merged** — `CLAIM_ISSUER_PRIVATE_KEY` only signs claims;
  `AGENT_PRIVATE_KEY` only performs token operations. Separate blast radius.
- **No secrets committed** — keys live in `.env` (gitignored); `.env.example` carries public
  Anvil dev keys and mock-provider defaults only.

## What this repo demonstrates

| Signal | Location |
| --- | --- |
| ERC-3643 / ONCHAINID / transfer restrictions | `contracts/` |
| Fuzz + invariant testing, forced-transfer & pause edge cases | `contracts/test/` |
| Reorg-safe, exactly-once-effective event indexing | `apps/indexer/` |
| Full-stack Web3 architecture | monorepo as a whole |

## License

MIT for first-party code. Vendored submodules retain their upstream licenses.
