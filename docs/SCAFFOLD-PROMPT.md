# Scaffold prompt

Run this as the **first** Claude Code prompt in an empty directory, *after* copying in the
`.claude/` folder, the `CLAUDE.md` files, and the `design/` mockups.

---

```
Scaffold a pnpm + Turborepo monorepo for "Tessera" — an ERC-3643 RWA tokenization and
compliance platform. Read the root CLAUDE.md first; it defines the golden rules, the chain of
record, and the layout. Do not write feature code in this pass — scaffolding only, and it must
end in a green build.

Create this structure:

  contracts/                Foundry project
  apps/api/                 NestJS REST API
  apps/indexer/             NestJS worker
  apps/web-investor/        Next.js (App Router)
  apps/web-admin/           Next.js (App Router)
  packages/shared/          TS types, ABIs, address book, Zod schemas
  packages/config/          shared eslint / tsconfig / prettier / tailwind preset
  infra/docker-compose.yml  postgres + anvil
  docs/

Root setup
- pnpm-workspace.yaml covering apps/*, packages/*
- turbo.json with dev, build, lint, typecheck, test pipelines (correct dependsOn)
- TypeScript strict everywhere, no `any`; shared tsconfig base in packages/config
- ESLint + Prettier from packages/config, wired into every workspace
- .gitignore: node_modules, .env, out/, cache/, broadcast/, .next/, dist/, addresses.local.json
- .env.example with exactly the variables listed in the root CLAUDE.md and the spec —
  placeholders only, mock providers as defaults, never a real key
- Root package.json scripts: dev, build, lint, typecheck, test, db:migrate, seed,
  contracts:deploy:local, contracts:deploy:amoy, contracts:verify:amoy
- GitHub Actions CI: install, lint, typecheck, forge test, workspace tests

contracts/
- forge init, foundry.toml, remappings.txt
- Add as git submodules under lib/: forge-std, OpenZeppelin/openzeppelin-contracts,
  TokenySolutions/T-REX, onchain-id/solidity
- Align the solc pragma with what T-REX pins; set it in foundry.toml
- Create empty dirs: src/modules, src/mocks, script, test/unit, test/fuzz, test/invariant
- GOAL FOR THIS PASS: `forge build` compiles cleanly with the submodules resolved. Fix
  remappings and solc version until it is green. Do not write contracts yet.

apps/api and apps/indexer
- NestJS scaffolds, TypeScript strict
- api: config module reading .env, health endpoint, Prisma set up against DATABASE_URL
- indexer: standalone Nest application (worker, no HTTP server), viem installed
- Both depend on packages/shared

apps/web-investor and apps/web-admin
- Next.js App Router + TypeScript + Tailwind
- Install wagmi v2, viem, @rainbow-me/rainbowkit, @tanstack/react-query, react-hook-form, zod
- Tailwind config extends the shared preset in packages/config
- Wire fonts: Space Grotesk (UI) and Roboto Mono (on-chain values) via next/font
- Providers wrapper (wagmi + RainbowKit + TanStack Query) in the app shell
- A placeholder home route per app that renders and passes build

packages/shared
- Exports: viem-typed Address helpers, shared Zod schemas, an address-book loader that reads
  addresses.{local,amoy}.json, and a place for generated ABIs

packages/config
- eslint preset, tsconfig base, prettier config, and a Tailwind preset whose theme.extend
  contains the Tessera tokens from .claude/skills/design-tokens/SKILL.md — primary pine-teal
  scale, cool-gray neutrals, the four semantic compliance palettes (verified/pending/blocked/
  paused with fg/bg/bd), the type scale, 4px spacing scale, and tight radii (2/4/6/pill).
  Components must reference tokens only; no raw hex anywhere else.

infra/docker-compose.yml
- postgres 16 (db rwa, user rwa, healthcheck) and foundry anvil on 8545 with a deterministic
  mnemonic and --block-time 2

Finish by running: pnpm install, pnpm lint, pnpm typecheck, pnpm build, and forge build.
Report the status of each and fix anything that fails. Then print a short summary of the tree.
```

---

## After the scaffold

1. Copy the design mockups into place:
   - `Investor_Portal_dc.html` → `apps/web-investor/design/`
   - `Admin_Console_dc.html` → `apps/web-admin/design/`
   - `RWA_Tokenization_Design_System_dc.html` → both `design/` folders (or
     `packages/config/design/` and reference it)
2. `git init`, commit the scaffold, push as a public repo early — a repo that visibly grows is
   itself a signal.
3. Run `/deploy-local` once contracts exist.
