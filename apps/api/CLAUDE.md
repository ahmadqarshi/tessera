# apps/api — NestJS REST API

Serves both portals. Holds the two backend signing keys, brokers KYC/AML providers, issues
on-chain claims, and executes privileged agent operations.

## Module map

`ChainModule` viem public client + Agent and ClaimIssuer wallet clients, address book ·
`AuthModule` SIWE nonce/verify → JWT, `@Roles()` guard · `KycModule` adapter + Persona/Mock ·
`AmlModule` adapter + yente/Mock · `ClaimIssuerModule` digest, sign, `addClaim` ·
`AgentModule` mint, distribute, pause, freeze, partial-freeze, forcedTransfer, recovery ·
`IdentityModule` deploy/register ONCHAINID · `TokenModule` offerings metadata ·
`ComplianceModule` topics, issuers, module params · `ReadModule` indexer-backed read models

## Hard rules

- **Private keys never leave this process.** No key, seed, or signature material in any API
  response. Frontends never receive a key.
- **Two wallets, strictly separated.** `ClaimIssuerService` may only sign claims.
  `AgentService` may only call token/registry operations. No shared signer abstraction that
  could blur them.
- **Every privileged action writes an `admin_actions` audit row** in the same transaction
  boundary as the dispatch, before returning. No silent agent operations.
- Admin routes are guarded by the **on-chain agent role** (`isAgent(wallet)`), not merely a
  JWT claim. Local dev may fall back to an allowlist, gated on `CHAIN_ENV=local`.
- **Reads serve indexer-populated tables.** Do not hit the chain to answer list/balance
  queries. Live-only values (e.g. current pause state at confirm time) may use viem.
- Provider selection via `PROVIDER_KYC` / `PROVIDER_AML` env at boot. **Mock is the default**
  and must always work offline.
- Verify Persona webhook signatures before acting on any payload. Reject unsigned webhooks.
- SIWE nonces are single-use, domain-bound, short TTL.

## Adapter contract

New providers implement the interface and register in the module — no call sites change.

```ts
interface KycAdapter {
  start(input: { investorAddress: Address; email?: string }): Promise<{ sessionRef: string; redirectUrl?: string }>;
  getStatus(sessionRef: string): Promise<'pending' | 'approved' | 'declined'>;
  verifyWebhook(headers: Record<string, string>, rawBody: Buffer): boolean;
}
interface AmlAdapter {
  screen(input: { fullName: string; country?: string; dob?: string }):
    Promise<{ clear: boolean; matches: Array<{ list: string; score: number }> }>;
}
```

## Conventions

- Zod (or class-validator) DTOs on every endpoint; validate addresses with `isAddress`.
- Amounts are `bigint` internally; serialize as decimal **strings** in JSON. Never a JS number.
- Errors: typed exception filters. Chain reverts are decoded into human-readable reasons and
  returned as structured `{ allowed: false, reason }` — the transfer pre-check UI renders
  `reason` verbatim, so write it in language an operator could repeat to a regulator.
- Tests: unit per service (mock adapters), e2e for the happy path (register → claims →
  distribute → compliant transfer) and the blocked path (transfer to unverified → correct reason).
