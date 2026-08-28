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

## Non-negotiable invariants

Detail and rationale live in the `tessera-backend-standards` skill. These are restated here
because they must be in context for every session, and because a silent violation of any of
them is expensive to find later.

- **Three signing roles, structurally separated.** `CLAIM_ISSUER_*` signs claims and never
  broadcasts — it is a viem `LocalAccount`, not a `WalletClient`. `AGENT_*` performs token and
  registry operations and never signs a claim. Owner-level operations (`revokeClaim`,
  `callModuleFunction`, registry configuration) need a third key. If it is not configured,
  return `501 OWNER_SIGNER_NOT_CONFIGURED` — never reuse the agent key, never call `addKey` to
  widen a role, never add an env var unprompted.
- **The claim `data` payload is pinned.** Raw UTF-8 bytes of the fixed per-topic label from
  `Seed.s.sol`, character for character. No ABI wrapping, no length prefix, no NUL, no
  per-investor variation. One changed character silently fails `isClaimValid` and presents as a
  signing bug.
- **`addClaim` is investor-submitted.** The backend signs; the investor's wallet sends. There is
  no backend submission path and adding one is not permitted.
- **`forcedTransfer` skips `canTransfer`** and ignores freeze and pause. Its pre-check must not
  call `canTransfer`. `mint`, `burn`, and `forcedTransfer` all work while paused.
- **Reject `amount == 0`** with its own reason. `ModularCompliance` requires `_value > 0`.
- **Never parse revert strings.** Diagnose each gate independently.
- **Amounts:** `bigint` in memory, `Decimal(78,0)` in the database, decimal strings in JSON.
- **Reads serve indexer tables.** Exceptions: live `paused()` / `totalSupply()` on offering
  detail, and pre-checks.
- **The API writes `claims`; the indexer writes `claim_chain_state`.** Never both. Nothing
  writes `REVOKED` to `claims.status` — revocation is observed, not asserted.
- **Every privileged action writes an `admin_actions` row before dispatch**, including failures.
- **Break-glass acknowledgement sentences are imported from `packages/shared`**, never inlined.

Stop and report rather than improvising when an operation needs a signer we do not hold, when a
change would give a table a second writer, or when passing a test would require weakening any
rule above.