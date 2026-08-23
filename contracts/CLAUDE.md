# contracts/ — Foundry, T-REX, ONCHAINID

Solidity workspace. Consumes Tokeny's audited **T-REX** suite and **ONCHAINID** as git
submodules; adds one custom compliance module and the deploy/seed scripts.

## Hard rules

- **Do not edit anything under `lib/`.** Vendored, audited, upstream-tracked.
- Extend compliance via the `IModule` interface only. Custom modules live in `src/modules/`.
- Mocks for testing live in `src/mocks/` and are never deployed to a public network.
- Match the pragma T-REX pins. If solc versions conflict, fix `foundry.toml` and
  `remappings.txt` — never patch the submodule.
- Every state-changing function: explicit access control + event emission.
- CEI ordering everywhere. If a module hook makes an external call, it needs a reentrancy test.

## Layout

```
src/modules/MaxInvestorsModule.sol   custom: distinct-holder cap
src/mocks/                           test doubles only
script/Deploy.s.sol                  deploy + wire full suite
script/Seed.s.sol                    demo investors, claims, distribution
test/unit/  test/fuzz/  test/invariant/
lib/                                 T-REX, ONCHAINID, forge-std, OZ (submodules)
```

## Deployment wiring order (get this exactly right)

1. `ClaimTopicsRegistry`, `TrustedIssuersRegistry`, `IdentityRegistryStorage`
2. `IdentityRegistry` initialized against those three
3. **`storage.bindIdentityRegistry(identityRegistry)`** ← silently breaks verification if missed
4. `ModularCompliance`, then `Token`, then `compliance.bindToken(token)`
5. Add agent wallet as agent on **both** `Token` and `IdentityRegistry`
6. ONCHAINID: `Identity` impl → `ImplementationAuthority` → `IdFactory` → `ClaimIssuer`
7. Register claim-issuer signing key as a **claim key (purpose 3)** on the ClaimIssuer
8. `TrustedIssuersRegistry.addTrustedIssuer(claimIssuer, [1, 2])`
9. `ClaimTopicsRegistry.addClaimTopic(1)` and `(2)`
10. Per investor: deploy `Identity` → `registerIdentity(wallet, onchainid, country)` →
    sign claim off-chain → `addClaim` on their Identity

Build the manual script **first**; refactor to `TREXFactory` only once it is green.

## Claim signing (exact scheme — do not substitute EIP-712)

```
digest        = keccak256(abi.encode(identityAddress, topic, data))
signedMessage = keccak256("\x19Ethereum Signed Message:\n32", digest)
signature     = sign(signedMessage, claimIssuerKey)      // ERC-735 scheme 1
claimId       = keccak256(abi.encode(issuerAddress, topic))
```

`IdentityRegistry.isVerified` loops required topics, fetches the claim by `claimId`, and
calls `IClaimIssuer.isClaimValid`, which `ecrecover`s the signer and checks it is a valid
claim key on a trusted issuer.

## Claim topics

`1` = KYC · `2` = AML/sanctions · `3` = Accredited (stretch) · `10` = Jurisdiction (stretch)

## The transfer gate (must hold in all tests)

1. not paused; `amount <= balance - frozenTokens[from]`
2. `identityRegistry.isVerified(to)`
3. `compliance.canTransfer(from, to, amount)` — view pre-flight
4. balance move, then `compliance.transferred(...)` — state-mutating counters

`forcedTransfer` bypasses **sender consent only**. Gates 2 and 3 still run. Any test
asserting otherwise is wrong.

## Testing requirements

Unit (`vm.expectRevert`): transfer to unverified receiver · non-agent `forcedTransfer` ·
transfer while paused · transfer exceeding `balance - frozen` · `forcedTransfer` to an
unverified receiver still reverts.

Fuzz: `freezePartialTokens` bounded → spendable never negative, always `balance - frozen` ·
`MaxInvestorsModule` under fuzzed sequences → holder count never exceeds cap.

Invariant (handler pattern, actors = agent + investors): `sum(balanceOf) == totalSupply`
across mint/burn/transfer/forcedTransfer/freeze · distinct holders `<= maxInvestors` ·
`frozen[addr] <= balanceOf(addr)`.

Run: `forge test -vvv` · `forge test --match-path test/invariant -vvv` · `forge coverage`

## Verification

`forge verify-contract` against PolygonScan (Amoy). Write resulting addresses to
`packages/shared/addresses.amoy.json` and surface them in the root README.
