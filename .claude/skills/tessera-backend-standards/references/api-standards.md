# API standards (`apps/api`, Phase 2)

Load alongside the shared invariants in `SKILL.md`. Findings 1–9, 13, 15, 16 land here.

## Key separation — the rule the whole design rests on

Three signing roles, and they must remain structurally incapable of doing each other's jobs.

| Role | Env | May do | Must never do |
| --- | --- | --- | --- |
| Claim issuer | `CLAIM_ISSUER_PRIVATE_KEY` | Sign claim digests off-chain | Broadcast any transaction |
| Agent | `AGENT_PRIVATE_KEY` | Token and registry operations | Sign a claim |
| Owner | `OWNER_PRIVATE_KEY` (pending) | Issuer-side revocation, module and registry configuration | Anything agent-level |

The claim issuer is a viem **`LocalAccount`, not a `WalletClient`** — do not construct a
transport for it. The separation is enforced by the type, not by discipline. A structural test
asserts nothing exported from `chain/` exposes a wallet client built from the claim issuer key.
(Finding 16)

At boot, assert the derived address of `CLAIM_ISSUER_PRIVATE_KEY` equals
`CLAIM_ISSUER_SIGNER_ADDRESS` and fail fatally on a mismatch. This is the single most likely
misconfiguration in Phase 2 and it otherwise presents as an unexplainable signing bug.

Private keys never leave the process. No key, seed, mnemonic, or raw signing material in any
log line, error message, or HTTP response.

## Claim signing — consensus-critical, do not improvise

- The payload is **ERC-735 scheme 1**, not EIP-712:
  `dataHash = keccak256(abi.encode(identityAddress, topic, data))`, then the
  `"\x19Ethereum Signed Message:\n32"` prefix, then sign. (Finding 2)
- The signed digest binds the **investor identity address**. The
  `claimId = keccak256(abi.encode(issuer, topic))` binds the **issuer**. Do not conflate them.
- `data` is the **raw UTF-8 bytes of a fixed per-topic label**. No ABI wrapping, no length
  prefix, no trailing NUL, no per-investor variation. The label strings in
  `contracts/script/Seed.s.sol` (`KYC_DATA`, `AML_DATA`) are the source of truth and are
  reproduced character for character. One changed character silently fails `isClaimValid` and
  looks like a signing bug rather than the encoding mismatch it is. (Finding 1, `NOTES.md` §5b)
- `addClaim` is `onlyClaimKey` on the investor's **own** identity. The backend signs; the
  investor's wallet submits. There is no backend submission path, and adding one as a
  convenience is not permitted. (Finding 3)
- Claims have **no on-chain expiry**. ERC-735 has no expiry field. Expiry is off-chain
  (`claims.expires_at`) and enforced by issuer-side `revokeClaim`. (Finding 4)
- Two revocation mechanisms: **issuer-side `revokeClaim`** (claim stays stored, `isClaimValid`
  returns false, no investor cooperation needed) and identity-side `removeClaim` (deleted,
  requires the investor). Only the issuer-side path is exposed. (Finding 5)

## Agent operations — encode the real behaviour

From `NOTES.md` §3, §3a, §7. These are verified against the vendored source; do not "correct"
them to match intuition.

- `mint`, `burn`, `forcedTransfer`, `freezePartialTokens`, `unfreezePartialTokens`,
  `setAddressFrozen`, `recoveryAddress` **all work while the token is paused**. Only
  `transfer` and `transferFrom` are pause-gated. (Finding 7)
- `forcedTransfer` **skips `compliance.canTransfer` entirely** and ignores address freeze and
  pause. Its real predicate is: caller is agent, `amount <= balanceOf(from)`, and
  `isVerified(to)`. It **can** breach the `MaxInvestorsModule` holder cap, because `moduleCheck`
  is skipped while `moduleTransferAction` still runs. (Finding 6, `NOTES.md` §7.1)
- `forcedTransfer` and `burn` **auto-unfreeze** when the amount exceeds the free balance.
- A freshly initialised token **starts paused**. (Finding 13)
- `recoveryAddress` requires the new wallet to be a **purpose-1 MANAGEMENT** key on the
  investor's ONCHAINID, not purpose 3. (`NOTES.md` §7.3)

Every privileged action writes an `admin_actions` row with status `PENDING` **before**
broadcasting, updated to `CONFIRMED` or `FAILED` after. The row exists even if the process dies
mid-flight — that is the point of writing it first. Failures are audited too, with the reason.

## Break-glass acknowledgements

Operations that bypass compliance or can un-verify holders require an exact acknowledgement
sentence, imported from `packages/shared`:

- `FORCED_TRANSFER_ACKNOWLEDGEMENT`
- `REMOVE_CLAIM_TOPIC_ACKNOWLEDGEMENT`
- `REMOVE_TRUSTED_ISSUER_ACKNOWLEDGEMENT`

Never inline the literal string. The admin portal imports the same symbols for its
confirmation modals, and a duplicated sentence drifts the moment someone rewords the copy —
producing a 400 that neither side can explain. A sentence rather than a boolean is deliberate:
`acknowledged: true` is what a script sends by accident and what a human never reads.

## Pre-checks

Two distinct endpoints, and the difference between them is load-bearing.

**Ordinary transfer pre-check** evaluates every gate independently and does not short-circuit:
`ZERO_AMOUNT`, `SENDER_FROZEN`, `RECIPIENT_FROZEN`, `INSUFFICIENT_BALANCE`, `TOKEN_PAUSED`,
`RECIPIENT_NOT_VERIFIED`, `COMPLIANCE_BLOCKED`. `reason` is the highest-priority failure;
`checks` carries them all.

**Forced-transfer pre-check must never call `canTransfer`.** Include a code comment saying so
and citing Finding 6, because the omission looks like a bug to a future reader. It reports
bypassed gates in `bypassed` and a holder-cap breach as a `warning`, never a block — the chain
permits it, and blocking would misrepresent on-chain reality.

Reason strings are rendered verbatim in the investor portal and quoted in the audit log. Write
them in complete English an operator could repeat to a regulator. `"canTransfer returned false"`
is not acceptable. Export them as a const map from `packages/shared`.

## Reads

Reads serve **indexer-populated tables**. Do not hit the chain for list, balance, or history
queries. Two documented exceptions: live `paused()` and `totalSupply()` on offering detail, and
the pre-checks, which are point-in-time consensus statements and cache nothing.

Every read response carries `asOfBlock` and `stale`. When the indexer has not run, return an
empty result with `asOfBlock: null` and `stale: true`. Do not 404 and do not fall back to the
chain — that shortcut becomes permanent.

## Claim table ownership

`claims` is API-owned: the off-chain lifecycle (`PENDING_SUBMISSION`, `SUBMITTED`, `EXPIRED`)
plus `revocationRequestedAt` and `revocationTxHash`. `claim_chain_state` is indexer-owned:
`present`, `revoked`, and provenance. They join on `(claimId, identityAddress)` with no foreign
key.

Nothing writes `REVOKED` to `claims.status`. Revocation is **observed**, not asserted — the API
records that it asked, the indexer records that it happened, and the two disagreeing is a
displayable state rather than a corruption.

Resolve the pair through the shared `effectiveClaimStatus` function. Never reimplement its
precedence: no chain row → `PENDING_SUBMISSION`; revoked → `REVOKED`; not present → `REMOVED`;
`expiresAt` passed → `EXPIRED`; otherwise `ACTIVE`.

## Endpoint documentation

Every endpoint, without exception:

- `@ApiOperation`, `@ApiResponse` for success **and every error code**, `@ApiBearerAuth` where
  auth is required
- `@ApiProperty` on every DTO property with description, example, and format
- An entry in `docs/api/API.md`: method, path, auth, purpose, request schema, a curl command, a
  200 response, and every error response
- Samples use real addresses from `seed.local.json` and plausible amounts — not `0x0000…`, not
  `"foo"`
- One error envelope: `{ statusCode, code, reason, details? }`, with every `code` value listed
  in `docs/api/ERRORS.md`

## Testing

- Unit tests mock the chain and the database.
- Integration tests are tagged `@chain` and run against live Anvil after `deploy:local` and
  `seed:local`, consuming the shared loaders.
- The keystone integration test: a backend-produced signature passes `ClaimIssuer.isClaimValid`
  on chain, with negative controls for wrong identity, wrong topic, mutated data, and a
  non-purpose-3 signer.
- A drift guard: a test reads `Seed.s.sol`, extracts the label literals, and compares them to
  the TypeScript constants.