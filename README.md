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

## Testnet deployment (Polygon Amoy · 80002)

The local Anvil flow above needs no accounts. Deploying the same suite to the public
**Polygon Amoy** showcase additionally requires three real inputs in `.env` (all gitignored):

| Env var | Purpose |
| --- | --- |
| `RPC_URL_AMOY` | An Amoy JSON-RPC endpoint (the public `https://rpc-amoy.polygon.technology` works). |
| `DEPLOYER_PRIVATE_KEY` | A **funded** Amoy deployer EOA. Fund it from a POL faucet first. Replace the public Anvil key — never broadcast with a well-known key. |
| `POLYGONSCAN_API_KEY` | A PolygonScan API key, used by `forge verify-contract` (Etherscan-v2 compatible). |

```bash
pnpm contracts:deploy:amoy    # deploy + wire + in-script assertions, then --verify each contract
pnpm contracts:seed:amoy      # onboard demo investors A/B (+ unverified C), sign claims, distribute
pnpm contracts:verify:amoy:all             # re-verify ALL 11 contracts from addresses.amoy.json
pnpm contracts:verify:amoy -- <address> <path:Name> [--constructor-args <abi-encoded>]  # re-verify one
```

`contracts:verify:amoy:all` (→ `contracts/script/verify-amoy.sh`) is the idempotent re-run of
verification: it reads `addresses.amoy.json`, reconstructs the constructor args for the four
contracts that take them (Identity, ImplementationAuthority, IdFactory, ClaimIssuer) from the
same book + env the deploy used, and loops `forge verify-contract` over every contract,
reporting a pass/fail tally. Prefix with `DRY_RUN=1` to print the commands without running them.

`foundry.toml` carries the `amoy` RPC alias and `[etherscan]` verifier config; both read from
env so no endpoint or key is committed. `Deploy.s.sol` selects
`packages/shared/addresses.amoy.json` automatically from `block.chainid` (80002), and its
in-script wiring assertions must pass on Amoy exactly as they do locally.

> **Demo constraint — issuer management key.** On Amoy, as locally,
> `CLAIM_ISSUER_MANAGEMENT_ADDRESS` **must equal the deployer**: the manual single-broadcast
> script registers the claim-signer key via `ClaimIssuer.addKey()`, which is `onlyManager`, so
> the broadcasting deployer has to hold the management purpose. A production deployment would
> **separate issuer management from the deployer** (management key in a multisig/HSM, distinct
> from the ops key that deploys). We make this coupling explicit here as a documented demo
> simplification, not an oversight — the claim *signer* is already a distinct least-privilege
> purpose-3 key regardless (see `contracts/NOTES.md` §5a and `Deploy.s.sol` step 7).

### Deployed addresses (Amoy · 80002)

Populated from `packages/shared/addresses.amoy.json` after a successful broadcast; each links to
`https://amoy.polygonscan.com/address/<addr>`. _Pending a funded deployment — the table is filled
in once `contracts:deploy:amoy` has broadcast and verified._

| Contract | Address |
| --- | --- |
| ClaimTopicsRegistry | _pending_ |
| TrustedIssuersRegistry | _pending_ |
| IdentityRegistryStorage | _pending_ |
| IdentityRegistry | _pending_ |
| ModularCompliance | _pending_ |
| MaxInvestorsModule | _pending_ |
| Token (BER-A) | _pending_ |
| IdentityLibrary | _pending_ |
| ImplementationAuthority | _pending_ |
| IdFactory | _pending_ |
| ClaimIssuer | _pending_ |

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
- **`MaxInvestorsModule` bind-safety, and its one residual** — the holder-cap module keeps an
  incremental balance mirror that must start empty, so it refuses to bind to a compliance whose
  token already has holders (`canComplianceBind` requires a bound token with `totalSupply() == 0`;
  it is not plug-and-play, so `addModule` runs the gate). This closes the accidental
  `addModule`-then-`bindToken(tokenWithHolders)` ordering. One path the module cannot self-defend
  remains: an owner who calls `unbindToken` and then `bindToken` a *different* token that already
  has holders — `bindToken` never re-consults modules — silently starts the mirror below reality.
  That is an **owner operational responsibility**, documented with the exact sequence and mitigation
  in [`contracts/NOTES.md` §9](contracts/NOTES.md).

## What this repo demonstrates

| Signal | Location |
| --- | --- |
| ERC-3643 / ONCHAINID / transfer restrictions | `contracts/` |
| Fuzz + invariant testing, forced-transfer & pause edge cases | `contracts/test/` |
| Reorg-safe, exactly-once-effective event indexing | `apps/indexer/` |
| Full-stack Web3 architecture | monorepo as a whole |

## License

MIT for first-party code. Vendored submodules retain their upstream licenses.
