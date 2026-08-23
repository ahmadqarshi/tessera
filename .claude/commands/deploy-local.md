---
description: Deploy the T-REX suite to local Anvil and seed demo data
---

Bring up a fully working local environment.

1. `docker compose -f infra/docker-compose.yml up -d` (postgres + anvil); wait for health.
2. `pnpm contracts:deploy:local` — verify the wiring order from the `trex-contracts` skill,
   especially `bindIdentityRegistry` and `bindToken`, and agent roles on both Token and
   IdentityRegistry.
3. Write addresses to `packages/shared/addresses.local.json`.
4. `pnpm db:migrate && pnpm seed` — two verified investors with on-chain KYC+AML claims, one
   unverified wallet, two property tokens, primary distribution to each verified investor.
5. Sanity-check both paths: a compliant transfer succeeds; a transfer to the unverified wallet
   reverts with the expected reason.
6. Report the deployed addresses and the seeded accounts.
