// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { TREXFixture } from "../helpers/TREXFixture.sol";

/**
 * @title FreezeFuzz — the partial-freeze lien, proven for every input rather than a few points.
 *
 * @notice {AgentControls} pins the freeze mechanics at hand-picked boundaries (exactly the free
 *         balance, one wei over, unfreeze-more-than-frozen). This suite proves the SAME properties
 *         hold across the whole input space: for any freeze amount, any freeze/unfreeze sequence,
 *         and any transfer against a frozen balance, the two invariants that make a lien sound must
 *         never break —
 *
 *           • **spendable == balance − frozen**, always, and it never underflows
 *             (`frozen <= balance` is preserved by every legal freeze op), and
 *           • a `transfer` succeeds **iff** it stays within that spendable amount.
 *
 *         Everything runs against the default fixture: cap 199 (unreachable, so the
 *         {MaxInvestorsModule} never interferes), A and B are verified holders, so the only gate a
 *         holder-to-holder move can fail is the balance-minus-frozen check we are probing.
 *
 *         Every fuzzed input is shaped with `bound()` (never `vm.assume`) so no run is discarded —
 *         each of the 512+ runs exercises a real, in-range scenario.
 */
contract FreezeFuzzTest is TREXFixture {
    // Agent freezes and transfers between two SEEDED, verified holders. A holds AMOUNT_A, B holds
    // AMOUNT_B (see {TREXFixture.setUp}); using the pre-seeded pair keeps every leg but the frozen
    // check trivially green, so a failure can only be the property under test.

    // ── freezePartialTokens over the full range: spendable is always balance − frozen ─────────
    //
    // For any freeze amount within the balance, the recorded lien equals the request, the remaining
    // spendable is exactly balance − frozen, and `frozen <= balance` (so `balance - frozen` cannot
    // underflow). Bounding to [0, balance] mirrors the Token's own `balance >= frozen + amount`
    // guard — we probe the legal domain, not the revert (that boundary is covered in AgentControls).
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_freezePartial_spendableIsBalanceMinusFrozen(uint256 freezeAmount) public {
        uint256 balance = token.balanceOf(investorA);
        freezeAmount = bound(freezeAmount, 0, balance);

        vm.prank(agent);
        token.freezePartialTokens(investorA, freezeAmount);

        uint256 frozen = token.getFrozenTokens(investorA);
        assertEq(frozen, freezeAmount, "recorded lien equals the requested freeze");
        assertLe(frozen, balance, "frozen never exceeds balance (balance - frozen cannot underflow)");
        assertEq(balance - frozen, balance - freezeAmount, "spendable is exactly balance - frozen");
    }

    // ── Arbitrary freeze/unfreeze sequences keep the lien consistent and non-negative ─────────
    //
    // Replays a fuzzed sequence of legal freeze / unfreeze operations against a private model of
    // the expected frozen amount. Each op is bounded to its legal range at the moment it runs
    // (freeze up to the current spendable, unfreeze up to the current lien), so none revert; after
    // every step the on-chain `getFrozenTokens` must equal the model and stay within [0, balance].
    // This catches drift that a single freeze/unfreeze pair would miss.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_freezeUnfreezeSequence_staysConsistent(
        uint256[] calldata amounts,
        bool[] calldata isFreeze
    ) public {
        uint256 balance = token.balanceOf(investorA);
        uint256 steps = amounts.length < isFreeze.length ? amounts.length : isFreeze.length;
        if (steps > 16) {
            steps = 16; // cap iterations so each of the 512 runs stays cheap
        }

        uint256 expectedFrozen = 0;
        for (uint256 i = 0; i < steps; i++) {
            if (isFreeze[i]) {
                // Freeze at most what is still spendable, so `balance >= frozen + amount` holds.
                uint256 amount = bound(amounts[i], 0, balance - expectedFrozen);
                vm.prank(agent);
                token.freezePartialTokens(investorA, amount);
                expectedFrozen += amount;
            } else {
                // Unfreeze at most what is currently frozen, so `frozen >= amount` holds.
                uint256 amount = bound(amounts[i], 0, expectedFrozen);
                vm.prank(agent);
                token.unfreezePartialTokens(investorA, amount);
                expectedFrozen -= amount;
            }

            uint256 frozen = token.getFrozenTokens(investorA);
            assertEq(frozen, expectedFrozen, "on-chain lien tracks the model exactly");
            assertLe(frozen, balance, "lien never exceeds balance (stays non-negative spendable)");
        }
    }

    // ── A transfer against a frozen balance succeeds iff amount <= balance − frozen ────────────
    //
    // The core lien property, as a biconditional. Freeze an arbitrary tranche of A's balance, then
    // attempt an arbitrary transfer A → B (B verified, not paused, cap unreachable — so the frozen
    // check is the ONLY gate that can bite). The move must go through exactly when it stays within
    // the free balance, and revert with "Insufficient Balance" the instant it does not — proving
    // the bound is `balance - frozen`, never `balance`.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_transferAgainstFrozen_succeedsIffWithinFree(
        uint256 freezeAmount,
        uint256 transferAmount
    ) public {
        uint256 balance = token.balanceOf(investorA);
        freezeAmount = bound(freezeAmount, 0, balance);
        transferAmount = bound(transferAmount, 0, balance);

        vm.prank(agent);
        token.freezePartialTokens(investorA, freezeAmount);

        uint256 free = balance - freezeAmount;
        uint256 toBefore = token.balanceOf(investorB);

        if (transferAmount == 0) {
            // A zero-value move is rejected upstream of the frozen check, at the compliance layer
            // (ModularCompliance.transferred requires `_value > 0`). Not a lien property, but we
            // pin the exact outcome so the biconditional below reads over strictly non-zero amounts.
            vm.prank(investorA);
            vm.expectRevert(bytes("invalid argument - no value transfer"));
            token.transfer(investorB, 0);
            assertEq(token.balanceOf(investorA), balance, "zero transfer moved nothing");
        } else if (transferAmount <= free) {
            vm.prank(investorA);
            token.transfer(investorB, transferAmount);
            assertEq(token.balanceOf(investorA), balance - transferAmount, "sender debited exactly");
            assertEq(token.balanceOf(investorB), toBefore + transferAmount, "receiver credited exactly");
            assertEq(token.getFrozenTokens(investorA), freezeAmount, "lien untouched by a spendable move");
        } else {
            vm.prank(investorA);
            vm.expectRevert(bytes("Insufficient Balance"));
            token.transfer(investorB, transferAmount);
            assertEq(token.balanceOf(investorA), balance, "rejected transfer moved nothing");
        }
    }
}
