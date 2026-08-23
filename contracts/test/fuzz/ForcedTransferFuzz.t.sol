// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { TREXFixture } from "../helpers/TREXFixture.sol";

/**
 * @title ForcedTransferFuzz — the agent break-glass predicate, proven across the input space.
 *
 * @notice {AgentControls} pins forcedTransfer at chosen points; this suite proves its governing
 *         predicate holds for ANY caller, actor pair, and amount, and that two conservation laws
 *         never break.
 *
 * ── The exact success predicate (see the deviation note below) ────────────────────────────────
 *   `forcedTransfer(from, to, amount)` succeeds **iff**:
 *     • the caller holds the agent role, AND
 *     • `amount <= balanceOf(from)`, AND
 *     • `isVerified(to)`.
 *   It does NOT depend on the compliance module check (NOTES.md §7.1 / §7 item 1 — forcedTransfer
 *   skips `canTransfer`, so the {MaxInvestorsModule} cap never gates it) NOR on pause state
 *   (NOTES.md §3a — mint/burn/forcedTransfer carry no `whenNotPaused`).
 *
 * ── ⚠️ Deliberate deviation from the task spec: address-freeze does NOT gate forcedTransfer ────
 *   The task asked us to assert forcedTransfer succeeds "iff ... neither party is address-frozen."
 *   That is FALSE for this codebase, and asserting it would be a bug in the test. `Token.forcedTransfer`
 *   (Token.sol:431-449) checks only `balanceOf(_from) >= _amount`, auto-unfreezes any partial-freeze
 *   shortfall, and then requires `isVerified(_to)` — it never consults the whole-wallet `_frozen`
 *   flag. The internal `_transfer` / `_beforeTokenTransfer` it calls are freeze-agnostic too; the
 *   `"wallet is frozen"` guard lives only in the holder-facing `transfer`/`transferFrom` bodies
 *   (Token.sol:418, :225). NOTES.md §7.1 confirms forcedTransfer "checks **only** `isVerified(_to)`."
 *   This is itself a meaningful break-glass property — an agent must be able to seize from, or
 *   reassign onto, a quarantined wallet (e.g. recovery is built on forcedTransfer) — so rather than
 *   drop the clause we fuzz the freeze flags of BOTH parties and prove the outcome is INDEPENDENT of
 *   them: the predicate above decides success whether or not either wallet is address-frozen.
 *
 *   Runs against the default fixture (cap 199, unreachable — underscoring that the cap is irrelevant
 *   to forcedTransfer). Cast: A, B verified holders; C no identity; D registered but unclaimed. C
 *   and D are the two distinct unverified receivers the predicate must reject.
 */
contract ForcedTransferFuzzTest is TREXFixture {
    // ── Predicate + freeze-independence: succeeds iff agent ∧ amount≤balance ∧ isVerified(to) ──
    //
    // Fuzz the caller (agent or not), the sender (A/B, both funded), the receiver (A/B/C/D, mixed
    // verification), the amount (spanning below and above the balance), and BOTH address-freeze
    // flags. Assert the exact outcome the predicate dictates — and, by driving the freeze flags
    // through every combination while the predicate ignores them, prove address-freeze does not
    // gate the agent's forced transfer.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_forcedTransfer_predicate(
        uint256 fromSel,
        uint256 toSel,
        uint256 rawAmount,
        bool callerIsAgent,
        bool freezeFrom,
        bool freezeTo
    ) public {
        address[2] memory froms = [investorA, investorB];
        address[4] memory tos = [investorA, investorB, investorC, investorD];
        address from = froms[bound(fromSel, 0, 1)];
        address to = tos[bound(toSel, 0, 3)];

        uint256 fromBalance = token.balanceOf(from);
        // Span both sides of the balance boundary so the "sender balance too low" branch is hit.
        // Bounded to [1, …]: a zero-value move is rejected by the compliance layer
        // (ModularCompliance.transferred requires `_value > 0`) independently of the agent predicate,
        // so the predicate below is stated — and probed — over strictly non-zero amounts.
        uint256 amount = bound(rawAmount, 1, fromBalance * 2);

        // Apply the fuzzed whole-wallet freezes as the agent. Per the predicate these must NOT
        // change the outcome — that is exactly what this test proves.
        if (freezeFrom) {
            vm.prank(agent);
            token.setAddressFrozen(from, true);
        }
        if (freezeTo) {
            vm.prank(agent);
            token.setAddressFrozen(to, true);
        }

        address caller = callerIsAgent ? agent : investorA; // investorA never holds the agent role
        uint256 totalBefore = token.totalSupply();

        if (!callerIsAgent) {
            vm.prank(caller);
            vm.expectRevert(bytes("AgentRole: caller does not have the Agent role"));
            token.forcedTransfer(from, to, amount);
        } else if (amount > fromBalance) {
            vm.prank(caller);
            vm.expectRevert(bytes("sender balance too low"));
            token.forcedTransfer(from, to, amount);
        } else if (!identityRegistry.isVerified(to)) {
            vm.prank(caller);
            vm.expectRevert(bytes("Transfer not possible"));
            token.forcedTransfer(from, to, amount);
        } else {
            uint256 toBefore = token.balanceOf(to);
            vm.prank(caller);
            assertTrue(
                token.forcedTransfer(from, to, amount),
                "agent + sufficient balance + verified receiver => success, regardless of freeze"
            );
            if (from != to) {
                assertEq(token.balanceOf(from), fromBalance - amount, "sender debited exactly");
                assertEq(token.balanceOf(to), toBefore + amount, "receiver credited exactly");
            } else {
                assertEq(token.balanceOf(from), fromBalance, "self forced-transfer leaves balance unchanged");
            }
        }

        assertEq(token.totalSupply(), totalBefore, "forcedTransfer never changes total supply");
    }

    // ── Conservation: total supply is invariant across any successful forced transfer ─────────
    //
    // A focused restatement of the supply law over guaranteed-successful moves: agent caller, both
    // parties verified (A/B), amount within balance. forcedTransfer relocates tokens, never mints
    // or burns, so `totalSupply` is unchanged for every input.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_forcedTransfer_totalSupplyInvariant(
        uint256 fromSel,
        uint256 toSel,
        uint256 rawAmount
    ) public {
        address[2] memory who = [investorA, investorB];
        address from = who[bound(fromSel, 0, 1)];
        address to = who[bound(toSel, 0, 1)];
        // [1, balance]: non-zero (compliance rejects zero moves) and within balance, so every
        // input is a guaranteed-successful forced transfer whose supply effect we can assert.
        uint256 amount = bound(rawAmount, 1, token.balanceOf(from));

        uint256 totalBefore = token.totalSupply();
        vm.prank(agent);
        token.forcedTransfer(from, to, amount);
        assertEq(token.totalSupply(), totalBefore, "supply constant across a forced transfer");
    }

    // ── Auto-unfreeze: forcing past the free balance reduces frozen by exactly the shortfall ──
    //
    // Freeze an arbitrary tranche of A, then force an arbitrary amount (within A's balance) to B.
    // When the amount exceeds the free balance, `frozenTokens` must drop by precisely the shortfall
    // (amount − free) and never underflow; when it stays within free, the lien is untouched. This
    // is the mechanism that guarantees a lien can never block a court-ordered seizure.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_forcedTransfer_autoUnfreezesShortfall(
        uint256 rawFreeze,
        uint256 rawForced
    ) public {
        uint256 balance = token.balanceOf(investorA);
        uint256 freezeAmount = bound(rawFreeze, 0, balance);
        // [1, balance]: non-zero (compliance rejects zero moves) and within balance, so the move
        // always succeeds (A frozen or not; B is verified) and we observe the unfreeze arithmetic.
        uint256 forcedAmount = bound(rawForced, 1, balance);

        vm.prank(agent);
        token.freezePartialTokens(investorA, freezeAmount);

        uint256 free = balance - freezeAmount;
        uint256 toBefore = token.balanceOf(investorB);

        vm.prank(agent);
        token.forcedTransfer(investorA, investorB, forcedAmount);

        uint256 frozenAfter = token.getFrozenTokens(investorA);
        if (forcedAmount > free) {
            uint256 shortfall = forcedAmount - free;
            assertLe(shortfall, freezeAmount, "shortfall can never exceed the lien (no underflow)");
            assertEq(frozenAfter, freezeAmount - shortfall, "lien reduced by exactly the shortfall");
        } else {
            assertEq(frozenAfter, freezeAmount, "lien untouched when the move fits in the free balance");
        }
        assertLe(frozenAfter, freezeAmount, "lien never grows and never underflows");
        assertEq(token.balanceOf(investorA), balance - forcedAmount, "sender debited the forced amount");
        assertEq(token.balanceOf(investorB), toBefore + forcedAmount, "receiver credited the forced amount");
    }
}
