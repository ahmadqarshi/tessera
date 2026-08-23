---
name: trex-contracts
description: Use when writing, deploying, or testing ERC-3643 / T-REX contracts, ONCHAINID identities, claim issuance and verification, compliance modules, or agent operations like forcedTransfer, freezePartialTokens, and pause. Covers the deployment wiring order, the exact claim signing scheme, the transfer gate, and required test coverage.
---

# T-REX / ERC-3643 implementation

Tokeny's **T-REX** and **ONCHAINID** are consumed as audited submodules under `contracts/lib/`.
**Never edit them.** Extend only via `IModule`.

## The mental model

`transfer` is a **question, not a command**. It asks three things before moving anything:
is the token operational, is the receiver eligible, does this transfer obey the rules. A
non-compliant transfer does not get flagged — it **reverts**.

## Contract topology

| Contract | Answers |
| --- | --- |
| `Token` | ERC-20 + compliance gating; holds agent roles |
| `IdentityRegistry` | `isVerified(address)` — may this wallet hold this token? |
| `IdentityRegistryStorage` | `address → (ONCHAINID, country)`; shareable across tokens |
| `TrustedIssuersRegistry` | which claim issuers are trusted, per topic |
| `ClaimTopicsRegistry` | which claim topics are required |
| `ModularCompliance` | composes pluggable rule modules |
| `Identity` (ONCHAINID) | per-investor contract holding ERC-735 claims |
| `ClaimIssuer` | validates claim signatures; holds claim keys |

## Deployment wiring order

1. `ClaimTopicsRegistry`, `TrustedIssuersRegistry`, `IdentityRegistryStorage`
2. `IdentityRegistry` initialized against those three
3. **`storage.bindIdentityRegistry(identityRegistry)`** ← omitting this silently breaks
   verification; it is the most common deployment bug
4. `ModularCompliance` → `Token` (pointing at registry + compliance) → `compliance.bindToken(token)`
5. Add the agent wallet as agent on **both** `Token` and `IdentityRegistry`
6. ONCHAINID: `Identity` impl → `ImplementationAuthority` → `IdFactory` → `ClaimIssuer`
7. Register the claim-issuer signing key as a **claim key (purpose 3)**
8. `addTrustedIssuer(claimIssuer, [1, 2])`; `addClaimTopic(1)`, `addClaimTopic(2)`
9. Per investor: deploy `Identity` → `registerIdentity(wallet, onchainid, country)` → sign
   claim off-chain → `addClaim` on their Identity

Write the manual script first. Refactor to `TREXFactory` only after it is green end to end.

## Claim signing — exact scheme

ONCHAINID uses **ERC-735 scheme 1 (`eth_sign` prefixed hash)**, *not* EIP-712 typed data.

```
digest        = keccak256(abi.encode(identityAddress, topic, data))
signedMessage = keccak256("\x19Ethereum Signed Message:\n32", digest)
signature     = sign(signedMessage, claimIssuerKey)
claimId       = keccak256(abi.encode(issuerAddress, topic))
```

`isVerified` loops the required topics, fetches each claim by `claimId`, and calls
`IClaimIssuer.isClaimValid`, which `ecrecover`s the signer and confirms it is a valid claim key
— **and** that the issuer is trusted for that topic. Both conditions must hold.

Topics: `1` KYC · `2` AML/sanctions · `3` Accredited (stretch) · `10` Jurisdiction (stretch).

## The transfer gate

1. **Operational** — not paused; `amount <= balance - frozenTokens[from]`
2. **Eligibility** — `identityRegistry.isVerified(to)`
3. **Rules** — `compliance.canTransfer(from, to, amount)` (view pre-flight)
4. **Move + record** — balance move, then `compliance.transferred(...)` (mutating; updates
   module counters such as holder count)

`canTransfer` and `transferred` are deliberately split: check first, record last. Stateful
rules like holder caps need the post-move hook to keep count.

## Agent operations — features, not vulnerabilities

These are regulator-mandated and **agent-gated**:

- `forcedTransfer(from, to, amount)` — bypasses **sender consent only**. Gates 2 and 3 still
  run: you cannot force a transfer to an ineligible receiver.
- `freezePartialTokens(addr, amount)` / `unfreeze` — locks part of a balance in place.
- `setAddressFrozen(addr, bool)` — freezes a whole wallet.
- `pause()` / `unpause()` — global emergency stop.
- Recovery — move holdings to a new wallet for the same identity.

The security question is never "how do I prevent forced transfers" — it is "how do I guarantee
only an authorized agent can call them, and that eligibility still holds."

## Custom module — `MaxInvestorsModule`

Implements `IModule` against `ModularCompliance`: caps distinct holders per token (e.g. 199).
`moduleCheck` rejects transfers that would create a holder beyond the cap;
`moduleTransferAction` / `moduleMintAction` / `moduleBurnAction` maintain the count.

Prefer custom modules over license-encumbered vendor modules where practical — some T-REX
compliance modules carry Tokeny's commercial license. Document licensing in the README.

## Required tests

**Unit (`vm.expectRevert`)** — transfer to unverified receiver · non-agent `forcedTransfer` ·
transfer while paused · transfer exceeding `balance - frozen` · `forcedTransfer` to an
unverified receiver still reverts.

**Fuzz** — bounded `freezePartialTokens`: spendable never negative, always `balance - frozen` ·
`MaxInvestorsModule` under fuzzed sequences: holder count never exceeds cap.

**Invariant (handler pattern; actors = agent + investors)** —
`sum(balanceOf) == totalSupply` across mint/burn/transfer/forcedTransfer/freeze ·
distinct holders `<= maxInvestors` · `frozen[addr] <= balanceOf(addr)`.

**Reentrancy** — if any module hook makes an external call, prove CEI ordering with a malicious
token. If no hooks make external calls, document that finding explicitly.
