// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { StdInvariant } from "forge-std/StdInvariant.sol";

import { TREXFixture } from "../helpers/TREXFixture.sol";
import { TokenHandler } from "./handlers/TokenHandler.sol";

/**
 * @title TokenInvariants — the properties that must hold no matter how the token is driven.
 *
 * @notice This is the centrepiece of the contract suite. Where the unit and fuzz tests pin
 *         individual behaviours, these invariants assert the token's deep structural truths survive
 *         ARBITRARY interleavings of every agent and holder action. The fuzzer calls {TokenHandler}
 *         ~256×64 times per run in a random order and re-checks every `invariant_*` below after each
 *         call; a single reachable counterexample fails the run and prints the calldata that got
 *         there.
 *
 * ── Why the cap is shrunk to 3 ────────────────────────────────────────────────────────────────
 *   The fixture's production cap is 199 — unreachable by a handful of actors, so invariants 2 and 4
 *   would pass VACUOUSLY, never once exercising the enforcement path. We override {_maxInvestors} to
 *   3 and stand up a verified actor set (A, B, E, F) that is strictly LARGER than the cap. Seeded
 *   holders A and B start the count at 2; E and F give the fuzzer two more verified wallets to
 *   create, so a compliant holder-creation can actually collide with the cap and be rejected by
 *   `moduleCheck` — the exact path invariant 2 guards. C and D (unverified) round out the set as the
 *   eligibility negatives that keep invariant 5 honest.
 *
 * ── The subtlety in invariant 2 (do NOT "simplify" it to an unconditional cap) ────────────────
 *   `forcedTransfer` deliberately skips `moduleCheck` while still running `moduleTransferAction`
 *   (NOTES.md §7.1), so an agent force-transfer CAN create a holder past the cap — the count is
 *   allowed to exceed `maxInvestors` on that path, by design. An unconditional "holders ≤ cap"
 *   invariant is therefore FALSE and the fuzzer would rightly find a legitimate counterexample. The
 *   real property is conditional: the cap holds on every holder-initiated + mint path, i.e. whenever
 *   no forced transfer has yet run. We encode exactly that using the handler's {ghostForcedTransfers}
 *   counter — full strength, not weakened. `forcedTransfer` stays in the handler because invariants
 *   1, 3, 4, 4b and 6 must all keep holding across it.
 */
contract TokenInvariants is TREXFixture {
    /// @dev A reachable cap (see contract doc). Overrides the fixture's default of 199.
    uint256 internal constant CAP = 3;

    TokenHandler internal handler;

    /// @dev The full actor universe, mirrored from the handler so the invariants compute ground
    ///      truth over exactly the addresses that can ever hold the token.
    address[] internal actors;

    function _maxInvestors() internal view override returns (uint256) {
        return CAP;
    }

    function setUp() public override {
        super.setUp();

        // Two verified, zero-balance investors so the verified set {A, B, E, F} EXCEEDS the cap (3)
        // — the precondition for a compliant holder-creation to actually be rejected by moduleCheck.
        // Reuses the seed's onboarding recipe (identity → registerIdentity → signed KYC/AML claims).
        Ctx memory c = Ctx({
            token: token,
            identityRegistry: identityRegistry,
            idFactory: idFactory,
            claimIssuer: claimIssuer,
            deployerPk: vm.deriveKey(MNEMONIC, 0),
            agentPk: vm.deriveKey(MNEMONIC, 2),
            signerPk: vm.deriveKey(MNEMONIC, 1)
        });
        (address investorE,) =
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 7), "token-invariant-e", COUNTRY_DE);
        (address investorF,) =
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 8), "token-invariant-f", COUNTRY_LU);

        // A, B verified holders · E, F verified empty · C, D unverified (no identity / no claims).
        actors.push(investorA);
        actors.push(investorB);
        actors.push(investorE);
        actors.push(investorF);
        actors.push(investorC);
        actors.push(investorD);

        handler = new TokenHandler(token, agent, actors);

        // Fuzz ONLY the handler, and only its bounded action selectors — never the raw suite. This
        // keeps every fuzzer call inside the handler's guarded surface (correct signer, bounded
        // amount, actors from the fixed set), which is what makes the runs explore real state.
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.forcedTransfer.selector;
        selectors[2] = handler.mint.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.freezePartialTokens.selector;
        selectors[5] = handler.unfreezePartialTokens.selector;
        selectors[6] = handler.setAddressFrozen.selector;
        selectors[7] = handler.pause.selector;
        selectors[8] = handler.unpause.selector;
        targetSelector(StdInvariant.FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    // ── 1. Solvency ──────────────────────────────────────────────────────────────────────────
    //
    // The books always balance, checked two independent ways: the sum of every actor's balance
    // equals `totalSupply` (only actors ever hold, so nothing is unaccounted for), AND `totalSupply`
    // equals the mint/burn ghost. Two derivations of the same number — a bug in the token's supply
    // accounting fails the first, a bug in a lifecycle hook's bookkeeping tends to fail the second.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_solvency() public {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "sum of all actor balances == totalSupply");
        assertEq(
            token.totalSupply(),
            handler.ghostNetSupply(),
            "totalSupply == seeded supply + mints - burns"
        );
    }

    // ── 2. Holder cap (conditional — the real property, NOTES.md §7.1) ─────────────────────────
    //
    // While no forced transfer has run, the distinct-holder count never exceeds the cap: every
    // holder-creating path left (transfer, mint) passes through `moduleCheck`, which refuses the
    // (cap+1)-th holder. Once a forced transfer executes, the cap may be legitimately breached
    // (moduleCheck is skipped), so we stop asserting the bound — but NOT the invariant: the count
    // still has to be ACCURATE, which invariant 4 continues to enforce on that path.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_holderCapUnlessForcedTransfer() public {
        if (handler.ghostForcedTransfers() == 0) {
            assertLe(
                _distinctHolders(),
                CAP,
                "distinct holders <= maxInvestors on every non-forced path"
            );
        }
    }

    // ── 3. Frozen consistency ──────────────────────────────────────────────────────────────────
    //
    // No wallet's frozen lien ever exceeds its balance — so `balance - frozen` (the spendable
    // amount the transfer gate computes) can never underflow. Because this is re-checked after every
    // handler action, it also establishes task invariant 6: it holds specifically across the
    // `forcedTransfer` and `burn` auto-unfreeze paths (whose exact shortfall arithmetic is asserted
    // inline in the handler the moment those moves succeed).
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_frozenNeverExceedsBalance() public {
        for (uint256 i = 0; i < actors.length; i++) {
            assertLe(
                token.getFrozenTokens(actors[i]),
                token.balanceOf(actors[i]),
                "frozen[addr] <= balanceOf(addr) for every actor, on every path"
            );
        }
    }

    // ── 4. Module count accuracy ─────────────────────────────────────────────────────────────
    //
    // The MaxInvestorsModule's O(1) holder counter equals the true number of non-zero-balance
    // holders, always — including after a forced-transfer breach, where the count legitimately
    // exceeds the cap but must still be RIGHT. This is the property the cap decisions depend on.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_moduleCountAccuracy() public {
        assertEq(
            maxInvestorsModule.investorCount(address(compliance)),
            _distinctHolders(),
            "module investorCount == true count of non-zero-balance holders"
        );
    }

    // ── 4b. Mirror accuracy (per-address — the compensating-error trap) ────────────────────────
    //
    // Stronger than the aggregate count: the module's internal balance mirror equals
    // `token.balanceOf` for EVERY actor. The mirror is the second source of truth every crossing
    // decision reads, and a correct total can hide two per-address errors that cancel. The action
    // hooks debit with saturating math, which would silently swallow an underflow — a mirror that
    // drifts below the real balance. This per-address equality is what would catch that.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_mirrorAccuracy() public {
        for (uint256 i = 0; i < actors.length; i++) {
            assertEq(
                maxInvestorsModule.mirroredBalance(address(compliance), actors[i]),
                token.balanceOf(actors[i]),
                "module mirror == token balance for every actor"
            );
        }
    }

    // ── 5. No unverified holder ────────────────────────────────────────────────────────────────
    //
    // Every actor holding a non-zero balance is currently verified. This holds because all three
    // token-crediting paths — `mint`, `transfer`, `forcedTransfer` — gate on `isVerified(_to)`, so
    // an unverified wallet (C, D) can never be credited in the first place.
    //
    // The precise general property in ERC-3643 is a DISJUNCTION: a holder is verified OR it was
    // verified when credited and later had its claim revoked. ERC-3643 has no clawback on
    // revocation, so a revoked wallet keeps its tokens — the count/mirror would still track it, but
    // `isVerified` would now be false. We can assert the stronger conjunct (`holder ⇒ verified`)
    // rather than the disjunction ONLY because this handler exposes no claim-revocation action, so
    // verification status is fixed for the whole run and the revoked branch is unreachable by
    // construction. Were a `revokeClaim` action ever added to the handler, this must relax to the
    // disjunction above — NOT be deleted — because the revoked-holder-retains-tokens path is real.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_noUnverifiedHolder() public {
        for (uint256 i = 0; i < actors.length; i++) {
            if (token.balanceOf(actors[i]) > 0) {
                assertTrue(
                    identityRegistry.isVerified(actors[i]),
                    "any wallet with a non-zero balance is verified (no revocation path in this handler)"
                );
            }
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────────────────

    /// @dev Ground-truth distinct-holder count: actors with a non-zero balance. Exhaustive because
    ///      only actors can ever hold the token (every crediting path targets one of them).
    function _distinctHolders() internal view returns (uint256 count) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (token.balanceOf(actors[i]) > 0) {
                count++;
            }
        }
    }
}
