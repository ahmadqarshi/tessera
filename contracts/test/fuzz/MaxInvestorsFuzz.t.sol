// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { TREXFixture } from "../helpers/TREXFixture.sol";

/**
 * @title MaxInvestorsFuzz — the distinct-holder cap and its balance mirror, under fuzzed sequences.
 *
 * @notice {MaxInvestorsModuleTest} walks each count-transition rule at hand-picked points. This
 *         suite proves the two module invariants survive ARBITRARY sequences of operations over a
 *         bounded actor set:
 *
 *           • **Count truth** — `investorCount` always equals the true number of addresses holding a
 *             non-zero balance, and on holder-initiated paths (`transfer`) it never exceeds the cap.
 *           • **Mirror truth** — the module's internal `_balances` mirror equals `token.balanceOf`
 *             for EVERY actor after every op, across the full op set (transfer, mint, burn,
 *             forcedTransfer). A correct aggregate count with a wrong mirror is achievable through
 *             compensating per-address errors, so we assert PER-ADDRESS equality, not just the sum.
 *
 *         The fixture's production cap (199) is unreachable with a small actor set — every run would
 *         pass vacuously, never touching the enforcement path. So {_maxInvestors} is overridden down
 *         to {CAP} == 3: seeded holders A and B start the count at 2, leaving exactly one free seat,
 *         so holder-creating moves routinely collide with the cap and exercise the rejection path.
 *
 *         Actor set: the two seeded holders A, B plus three fully-verified, zero-balance investors
 *         E, F, G (fresh Anvil indices 7–9, salts disjoint from the fixture's cast). All five are
 *         verified, so a move never fails receiver-eligibility (gate 2) — isolating the cap and the
 *         mirror as the only things a run can break. Because only these five ever receive tokens,
 *         the set of possible holders is exactly `actors`, so we can compute the true holder count
 *         by iterating it.
 */
contract MaxInvestorsFuzzTest is TREXFixture {
    uint256 internal constant CAP = 3;

    // The complete universe of holders: seeded A, B + zero-balance verified E, F, G.
    address[5] internal actors;

    /// @dev Shrink the deployed cap so a bounded actor set can actually reach it (see contract doc).
    function _maxInvestors() internal view override returns (uint256) {
        return CAP;
    }

    function setUp() public override {
        super.setUp();

        // Onboard three fully-verified, zero-balance investors by reusing the seed's onboarding
        // recipe (identity -> registerIdentity -> signed KYC/AML claims). No mint, so the count
        // stays at 2 (A, B) until a fuzzed op creates them.
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
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 7), "maxinv-fuzz-e", COUNTRY_DE);
        (address investorF,) =
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 8), "maxinv-fuzz-f", COUNTRY_LU);
        (address investorG,) =
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 9), "maxinv-fuzz-g", COUNTRY_DE);

        actors = [investorA, investorB, investorE, investorF, investorG];
    }

    // ── Count truth + cap enforcement on holder-initiated transfers ───────────────────────────
    //
    // Replay a fuzzed sequence of holder-to-holder transfers among the actor set. Each transfer is
    // attempted at its natural outcome — it may revert (a move that would create the (cap+1)-th
    // holder is refused by moduleCheck with "Transfer not possible"); we swallow that with
    // try/catch, since the point is the state AFTER whatever happened. After every step:
    //   • investorCount equals the true number of non-zero holders (iterated over `actors`), and
    //   • investorCount never exceeds the cap — because transfer is a holder-initiated path, the
    //     only path the cap actually gates.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transfers_countTracksHoldersAndRespectsCap(
        uint256[] calldata fromIdx,
        uint256[] calldata toIdx,
        uint256[] calldata rawAmounts
    ) public {
        uint256 steps = _minLen3(fromIdx.length, toIdx.length, rawAmounts.length);

        for (uint256 i = 0; i < steps; i++) {
            address from = actors[bound(fromIdx[i], 0, actors.length - 1)];
            address to = actors[bound(toIdx[i], 0, actors.length - 1)];
            uint256 amount = bound(rawAmounts[i], 0, token.balanceOf(from));

            vm.prank(from);
            // May revert on a cap-blocked holder creation; that is a valid outcome we don't force.
            try token.transfer(to, amount) { } catch { }

            assertEq(
                maxInvestorsModule.investorCount(address(compliance)),
                _trueHolderCount(),
                "count equals the number of addresses with a non-zero balance"
            );
            assertLe(
                maxInvestorsModule.investorCount(address(compliance)),
                CAP,
                "holder-initiated transfers never push the count past the cap"
            );
        }
    }

    // ── Mirror truth across the full op set (the compensating-error trap) ─────────────────────
    //
    // Replay a fuzzed sequence mixing all four lifecycle paths — transfer, mint, burn,
    // forcedTransfer — over the actor set, then assert the module's mirror equals the token balance
    // for EVERY actor after every op. forcedTransfer is included deliberately: it bypasses
    // moduleCheck and can drive the count PAST the cap (NOTES §7.1), so the mirror must keep
    // tracking reality even when the cap is breached. Per-address equality is the assertion that
    // matters: an aggregate count can be right while two mirrors are wrong by offsetting amounts.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_mixedOps_mirrorEqualsBalancePerAddress(
        uint256[] calldata opSeed,
        uint256[] calldata idxA,
        uint256[] calldata idxB,
        uint256[] calldata rawAmounts
    ) public {
        uint256 steps = _minLen4(opSeed.length, idxA.length, idxB.length, rawAmounts.length);

        for (uint256 i = 0; i < steps; i++) {
            uint256 op = bound(opSeed[i], 0, 3);
            address a = actors[bound(idxA[i], 0, actors.length - 1)];
            address b = actors[bound(idxB[i], 0, actors.length - 1)];

            if (op == 0) {
                // Holder transfer a -> b, bounded to a's balance. May revert at the cap.
                uint256 amount = bound(rawAmounts[i], 0, token.balanceOf(a));
                vm.prank(a);
                try token.transfer(b, amount) { } catch { }
            } else if (op == 1) {
                // Agent mint to b. May revert when it would create a holder at the cap.
                uint256 amount = bound(rawAmounts[i], 0, 1_000_000e18);
                vm.prank(agent);
                try token.mint(b, amount) { } catch { }
            } else if (op == 2) {
                // Agent burn from a, bounded to a's balance (auto-unfreeze covers any lien).
                uint256 amount = bound(rawAmounts[i], 0, token.balanceOf(a));
                vm.prank(agent);
                try token.burn(a, amount) { } catch { }
            } else {
                // Agent forcedTransfer a -> b. All actors are verified and amount <= balance, so it
                // succeeds — and may push the count past the cap, which the mirror must still track.
                uint256 amount = bound(rawAmounts[i], 0, token.balanceOf(a));
                vm.prank(agent);
                try token.forcedTransfer(a, b, amount) { } catch { }
            }

            // The invariant: the module's mirror matches the token, address by address.
            for (uint256 j = 0; j < actors.length; j++) {
                assertEq(
                    maxInvestorsModule.mirroredBalance(address(compliance), actors[j]),
                    token.balanceOf(actors[j]),
                    "module mirror equals token balance for every actor"
                );
            }
            // And the count still equals the true holder set (it may legitimately exceed the cap
            // here, since forcedTransfer is in the mix — so we assert truth, not the cap bound).
            assertEq(
                maxInvestorsModule.investorCount(address(compliance)),
                _trueHolderCount(),
                "count equals the number of non-zero holders even after a forced-transfer breach"
            );
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────────────────────

    /// @dev The true distinct-holder count: actors with a non-zero token balance. Correct because
    ///      only actors ever receive tokens, so no holder can exist outside this set.
    function _trueHolderCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (token.balanceOf(actors[i]) > 0) {
                count++;
            }
        }
    }

    /// @dev Smallest of three lengths, capped at 24 so each fuzz run stays cheap.
    function _minLen3(uint256 x, uint256 y, uint256 z) internal pure returns (uint256 m) {
        m = x < y ? x : y;
        m = m < z ? m : z;
        if (m > 24) {
            m = 24;
        }
    }

    /// @dev Smallest of four lengths, capped at 24 so each fuzz run stays cheap.
    function _minLen4(uint256 w, uint256 x, uint256 y, uint256 z)
        internal
        pure
        returns (uint256 m)
    {
        m = w < x ? w : x;
        m = m < y ? m : y;
        m = m < z ? m : z;
        if (m > 24) {
            m = 24;
        }
    }
}
