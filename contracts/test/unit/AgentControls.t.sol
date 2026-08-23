// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { TREXFixture } from "../helpers/TREXFixture.sol";

import { MaxInvestorsModule } from "../../src/modules/MaxInvestorsModule.sol";

/**
 * @title AgentControls — the agent break-glass surface of an ERC-3643 token.
 *
 * @notice Where {TransferGate} proves the holder-initiated eligibility gate, this suite proves the
 *         AGENT powers layered on top of it: `transferFrom`, `pause`/`unpause`, whole-wallet and
 *         partial freezes, and `forcedTransfer`. Each test states the security property it pins,
 *         not just the mechanics — because these are the levers a compliance operator actually
 *         pulls, and their edges are counter-intuitive (verified against contracts/NOTES.md §3a
 *         and §4). Every revert string below is the vendored Token's own, re-checked at source.
 *
 *         The fixture deploys with the production holder cap ({TREXFixture._maxInvestors} == 199),
 *         which no test here reaches — so the {MaxInvestorsModule} is present and counting but
 *         never gates these flows. The one test that MUST reach the cap (forced transfer breaching
 *         it) lives in its own contract at the bottom, which overrides the cap down to a reachable
 *         value. Keeping the two apart means the ordinary agent tests read against a realistic
 *         deployment while the cap test still has something to hit.
 */
contract AgentControlsTest is TREXFixture {
    uint256 internal constant XFER = 10_000e18;

    // Local mirrors of Token/IToken events so vm.expectEmit can match them: Solidity 0.8.17 cannot
    // reference another contract's event in an `emit`. Signatures copied verbatim from IToken.sol.
    event AddressFrozen(
        address indexed _userAddress, bool indexed _isFrozen, address indexed _owner
    );
    event TokensFrozen(address indexed _userAddress, uint256 _amount);
    event TokensUnfrozen(address indexed _userAddress, uint256 _amount);

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // transferFrom — the SAME gate as transfer, on a distinct function body.
    //
    // Token.transfer and Token.transferFrom are separate implementations (Token.sol:417 vs :220).
    // If transferFrom skipped the eligibility checks, an investor could `approve` a contract and
    // let it move tokens to anyone — routing around KYC/AML entirely. These tests prove the full
    // gate (frozen · balance-minus-frozen · isVerified · canTransfer · pause) applies identically
    // when a third-party spender pulls tokens, not just when the holder pushes them.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function _approveSpender(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        token.approve(spender, amount);
    }

    // Happy path: a spender pulls tokens to a VERIFIED receiver, within the free balance. Proves
    // the allowance mechanism works end to end AND that a compliant transferFrom is permitted —
    // the baseline the negative cases below deviate from one property at a time.
    function test_transferFrom_toVerified_succeeds() public {
        address spender = makeAddr("spender");
        _approveSpender(investorA, spender, XFER);
        uint256 fromBefore = token.balanceOf(investorA);
        uint256 toBefore = token.balanceOf(investorB);

        vm.prank(spender);
        token.transferFrom(investorA, investorB, XFER);

        assertEq(token.balanceOf(investorA), fromBefore - XFER, "owner debited");
        assertEq(token.balanceOf(investorB), toBefore + XFER, "verified receiver credited");
        assertEq(token.allowance(investorA, spender), 0, "allowance consumed by the pull");
    }

    // Receiver has NO identity (C): the receiver-eligibility leg (gate 2) fails exactly as it does
    // for `transfer`. The approval does not buy the spender a way around verification.
    function test_transferFrom_toUnregisteredReceiver_reverts() public {
        address spender = makeAddr("spender");
        _approveSpender(investorA, spender, XFER);

        vm.prank(spender);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transferFrom(investorA, investorC, XFER);
    }

    // Receiver is REGISTERED but unclaimed (D): a distinct failure cause (missing claims, not
    // missing identity) that still stops transferFrom at gate 2 — same as it stops `transfer`.
    function test_transferFrom_toRegisteredButUnclaimedReceiver_reverts() public {
        assertTrue(identityRegistry.contains(investorD), "D registered");
        assertFalse(identityRegistry.isVerified(investorD), "D unverified (no claims)");
        address spender = makeAddr("spender");
        _approveSpender(investorA, spender, XFER);

        vm.prank(spender);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transferFrom(investorA, investorD, XFER);
    }

    // Paused market: transferFrom carries `whenNotPaused` (Token.sol:223) just like transfer. A
    // live allowance does not let a spender move tokens during a halt.
    function test_transferFrom_whilePaused_reverts() public {
        address spender = makeAddr("spender");
        _approveSpender(investorA, spender, XFER);
        vm.prank(agent);
        token.pause();

        vm.prank(spender);
        vm.expectRevert(bytes("Pausable: paused"));
        token.transferFrom(investorA, investorB, XFER);
    }

    // Either party address-frozen blocks the pull: transferFrom requires
    // `!_frozen[to] && !_frozen[from]` (Token.sol:225). Freezing the OWNER stops the spender from
    // moving that owner's tokens; freezing the RECEIVER stops tokens landing on a frozen wallet.
    function test_transferFrom_whenFromFrozen_reverts() public {
        address spender = makeAddr("spender");
        _approveSpender(investorA, spender, XFER);
        vm.prank(agent);
        token.setAddressFrozen(investorA, true);

        vm.prank(spender);
        vm.expectRevert(bytes("wallet is frozen"));
        token.transferFrom(investorA, investorB, XFER);
    }

    function test_transferFrom_whenToFrozen_reverts() public {
        address spender = makeAddr("spender");
        _approveSpender(investorA, spender, XFER);
        vm.prank(agent);
        token.setAddressFrozen(investorB, true);

        vm.prank(spender);
        vm.expectRevert(bytes("wallet is frozen"));
        token.transferFrom(investorA, investorB, XFER);
    }

    // Partial freeze binds transferFrom too: the pull may not exceed `balance - frozenTokens[from]`
    // (Token.sol:226). Frozen tokens are unspendable regardless of who initiates the move.
    function test_transferFrom_exceedingFreeBalance_reverts() public {
        address spender = makeAddr("spender");
        uint256 balance = token.balanceOf(investorA);
        uint256 freeze = balance - XFER; // leaves exactly XFER spendable
        vm.prank(agent);
        token.freezePartialTokens(investorA, freeze);
        _approveSpender(investorA, spender, type(uint256).max);

        // One wei over the free balance is refused, even with an unlimited allowance.
        vm.prank(spender);
        vm.expectRevert(bytes("Insufficient Balance"));
        token.transferFrom(investorA, investorB, XFER + 1);

        // Exactly the free balance goes through — proving the bound is `balance - frozen`, not `balance`.
        vm.prank(spender);
        token.transferFrom(investorA, investorB, XFER);
        assertEq(
            token.getFrozenTokens(investorA), freeze, "frozen amount untouched by the transfer"
        );
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // Pause — a market halt on HOLDER movement, not a freeze on agent break-glass powers (§3a).
    // ══════════════════════════════════════════════════════════════════════════════════════════

    function test_agentCanPauseAndUnpause() public {
        vm.startPrank(agent);
        token.pause();
        assertTrue(token.paused(), "agent paused the token");
        token.unpause();
        assertFalse(token.paused(), "agent unpaused the token");
        vm.stopPrank();
    }

    // pause is onlyAgent (the modifier runs before whenNotPaused), so a holder cannot halt the market.
    function test_nonAgentCannotPause_reverts() public {
        vm.prank(investorA);
        vm.expectRevert(bytes("AgentRole: caller does not have the Agent role"));
        token.pause();
    }

    // Ordinary holder moves are frozen during a halt.
    function test_transferRevertsWhilePaused() public {
        vm.prank(agent);
        token.pause();
        vm.prank(investorA);
        vm.expectRevert(bytes("Pausable: paused"));
        token.transfer(investorB, XFER);
    }

    // The crux of §3a: mint, burn and forcedTransfer carry NO pause modifier. Pause is a halt on
    // holder-initiated trading, not a freeze on the agent's supply-control and break-glass powers —
    // an operator must still be able to mint a redemption, burn a clawback, or force a court-ordered
    // transfer while the market is halted. Assert all three succeed on a PAUSED token.
    function test_agentBreakGlassOpsSucceedWhilePaused() public {
        vm.startPrank(agent);
        token.pause();
        assertTrue(token.paused(), "token is halted");

        // mint to an existing verified holder — supply control is unaffected by the halt.
        uint256 aBefore = token.balanceOf(investorA);
        token.mint(investorA, XFER);
        assertEq(token.balanceOf(investorA), aBefore + XFER, "mint works while paused");

        // burn a holder's tokens — clawback is unaffected by the halt.
        token.burn(investorA, XFER);
        assertEq(token.balanceOf(investorA), aBefore, "burn works while paused");

        // forcedTransfer between verified holders — break-glass is unaffected by the halt.
        uint256 bBefore = token.balanceOf(investorB);
        token.forcedTransfer(investorA, investorB, XFER);
        assertEq(token.balanceOf(investorB), bBefore + XFER, "forcedTransfer works while paused");
        assertTrue(token.paused(), "token remained paused throughout");
        vm.stopPrank();
    }

    // After unpause, holder transfers resume — the halt is fully reversible.
    function test_transfersResumeAfterUnpause() public {
        vm.startPrank(agent);
        token.pause();
        token.unpause();
        vm.stopPrank();

        uint256 toBefore = token.balanceOf(investorB);
        vm.prank(investorA);
        token.transfer(investorB, XFER);
        assertEq(token.balanceOf(investorB), toBefore + XFER, "transfer works again after unpause");
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // Address freeze — a whole-wallet block on BOTH sending and receiving.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    // A frozen holder cannot SEND. The freeze flag on msg.sender fails the first gate check.
    function test_frozenHolderCannotSend() public {
        vm.prank(agent);
        vm.expectEmit(true, true, true, false, address(token));
        emit AddressFrozen(investorA, true, agent);
        token.setAddressFrozen(investorA, true);
        assertTrue(token.isFrozen(investorA), "A is address-frozen");

        vm.prank(investorA);
        vm.expectRevert(bytes("wallet is frozen"));
        token.transfer(investorB, XFER);
    }

    // A frozen address also cannot RECEIVE — _transfer requires `!_frozen[to] && !_frozen[from]`
    // (NOTES.md:331 / Token.sol:418), so the freeze is bidirectional. Freezing a wallet quarantines
    // it completely: value can neither leave nor arrive. This is the leg an operator relies on to
    // truly ring-fence a sanctioned address, not merely stop it spending.
    function test_frozenHolderCannotReceive() public {
        vm.prank(agent);
        token.setAddressFrozen(investorB, true);
        assertTrue(token.isFrozen(investorB), "B is address-frozen");

        vm.prank(investorA);
        vm.expectRevert(bytes("wallet is frozen"));
        token.transfer(investorB, XFER);
    }

    // setAddressFrozen is onlyAgent — a holder cannot freeze anyone (including themselves).
    function test_nonAgentCannotSetAddressFrozen_reverts() public {
        vm.prank(investorA);
        vm.expectRevert(bytes("AgentRole: caller does not have the Agent role"));
        token.setAddressFrozen(investorB, true);
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // Partial freeze — a per-wallet lien: exactly `balance - frozen` stays spendable.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    // freezePartialTokens(holder, x) leaves exactly balance - x spendable: not one wei more.
    function test_partialFreeze_leavesExactlyFreeBalanceSpendable() public {
        uint256 balance = token.balanceOf(investorA);
        uint256 freeze = balance - XFER; // spendable == XFER after freezing

        vm.prank(agent);
        vm.expectEmit(true, false, false, true, address(token));
        emit TokensFrozen(investorA, freeze);
        token.freezePartialTokens(investorA, freeze);
        assertEq(token.getFrozenTokens(investorA), freeze, "frozen amount recorded");

        // One wei above the free balance reverts on the balance-minus-frozen check.
        vm.prank(investorA);
        vm.expectRevert(bytes("Insufficient Balance"));
        token.transfer(investorB, XFER + 1);

        // Exactly the free balance succeeds — the bound is `balance - frozen`.
        vm.prank(investorA);
        token.transfer(investorB, XFER);
        assertEq(token.balanceOf(investorA), freeze, "only the frozen tranche remains");
    }

    // unfreezePartialTokens restores spendability; it requires frozen >= amount (cannot unfreeze
    // more than is frozen), guarding against underflowing the lien.
    function test_partialUnfreeze_restoresSpendableAndBoundsAmount() public {
        uint256 balance = token.balanceOf(investorA);
        vm.startPrank(agent);
        token.freezePartialTokens(investorA, balance); // freeze everything

        // Cannot unfreeze more than is frozen.
        vm.expectRevert(bytes("Amount should be less than or equal to frozen tokens"));
        token.unfreezePartialTokens(investorA, balance + 1);

        // Unfreeze it all and confirm the wallet is fully spendable again.
        vm.expectEmit(true, false, false, true, address(token));
        emit TokensUnfrozen(investorA, balance);
        token.unfreezePartialTokens(investorA, balance);
        assertEq(token.getFrozenTokens(investorA), 0, "lien fully released");
        vm.stopPrank();

        vm.prank(investorA);
        token.transfer(investorB, balance); // whole balance now moves
        assertEq(token.balanceOf(investorA), 0, "entire balance spendable after unfreeze");
    }

    // freezePartialTokens requires balance >= frozen + amount: you cannot freeze more than the
    // holder owns (would create a lien larger than the balance backing it).
    function test_partialFreeze_exceedingBalance_reverts() public {
        uint256 balance = token.balanceOf(investorA);
        vm.prank(agent);
        vm.expectRevert(bytes("Amount exceeds available balance"));
        token.freezePartialTokens(investorA, balance + 1);
    }

    // Both partial-freeze operations are onlyAgent — a holder cannot lien or release their own tokens.
    function test_nonAgentCannotFreezeOrUnfreezePartial_reverts() public {
        vm.startPrank(investorA);
        vm.expectRevert(bytes("AgentRole: caller does not have the Agent role"));
        token.freezePartialTokens(investorA, XFER);
        vm.expectRevert(bytes("AgentRole: caller does not have the Agent role"));
        token.unfreezePartialTokens(investorA, XFER);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════════════════════
    // forcedTransfer — the agent's break-glass move. Bypasses holder consent AND gate 3, but NOT
    // receiver eligibility (gate 2). See §7.1 and the dedicated cap-breach contract below.
    // ══════════════════════════════════════════════════════════════════════════════════════════

    // The agent can move a holder's tokens WITHOUT that holder's signature or approval — the
    // property that lets an operator execute a court order, correct an error, or reassign on death.
    function test_forcedTransfer_agentMovesWithoutHolderConsent() public {
        uint256 fromBefore = token.balanceOf(investorA);
        uint256 toBefore = token.balanceOf(investorB);

        // No prank as A, no approval from A — the agent acts alone.
        vm.prank(agent);
        token.forcedTransfer(investorA, investorB, XFER);

        assertEq(token.balanceOf(investorA), fromBefore - XFER, "holder debited without consenting");
        assertEq(token.balanceOf(investorB), toBefore + XFER, "receiver credited");
    }

    // forcedTransfer STILL runs gate 2: it cannot deposit onto an unverified receiver
    // (Token.sol:449 falls through to the same "Transfer not possible" revert). Break-glass does
    // not mean "send anywhere" — the receiver must still be a verified holder.
    function test_forcedTransfer_toUnverifiedReceiver_reverts() public {
        vm.prank(agent);
        vm.expectRevert(bytes("Transfer not possible"));
        token.forcedTransfer(investorA, investorC, XFER);
    }

    // forcedTransfer AUTO-UNFREEZES: forcing more than the holder's free balance reduces
    // frozenTokens by the shortfall and emits TokensUnfrozen for exactly that shortfall
    // (Token.sol:438-440), so a lien can never block a court-ordered seizure. Assert the emitted
    // amount is the shortfall, and that the lien is reduced by precisely that much.
    function test_forcedTransfer_autoUnfreezesTheShortfall() public {
        uint256 balance = token.balanceOf(investorA); // AMOUNT_A
        uint256 freeze = 200_000e18; // free balance becomes balance - 200k
        uint256 free = balance - freeze;
        uint256 forced = free + 50_000e18; // 50k over the free balance
        uint256 shortfall = forced - free; // == 50k, the amount that must be unfrozen

        vm.startPrank(agent);
        token.freezePartialTokens(investorA, freeze);

        vm.expectEmit(true, false, false, true, address(token));
        emit TokensUnfrozen(investorA, shortfall);
        token.forcedTransfer(investorA, investorB, forced);
        vm.stopPrank();

        assertEq(
            token.getFrozenTokens(investorA),
            freeze - shortfall,
            "lien reduced by exactly the shortfall"
        );
        assertEq(
            token.balanceOf(investorA), balance - forced, "holder debited the full forced amount"
        );
    }

    // forcedTransfer is onlyAgent — a holder cannot force-move anyone's tokens, not even their own.
    function test_nonAgentCannotForcedTransfer_reverts() public {
        vm.prank(investorB);
        vm.expectRevert(bytes("AgentRole: caller does not have the Agent role"));
        token.forcedTransfer(investorA, investorB, XFER);
    }

    // Note: "forcedTransfer succeeds while paused" is asserted in
    // {test_agentBreakGlassOpsSucceedWhilePaused} above, alongside mint and burn (§3a).
}

/**
 * @title ForcedTransferCapBreachTest — forcedTransfer can drive holder count PAST the module cap.
 *
 * @notice The single most counter-intuitive agent behaviour (contracts/NOTES.md §7.1), isolated in
 *         its own contract because it is the one agent test that must REACH the {MaxInvestorsModule}
 *         cap — so it overrides the fixture's cap down to a value a test can hit.
 *
 *         The asymmetry being proven:
 *           • forcedTransfer does NOT call `compliance.canTransfer`, so `moduleCheck` — where the
 *             cap is enforced — never runs. An agent can therefore create a holder beyond the cap.
 *           • but `compliance.transferred` STILL fires, so `moduleTransferAction` still runs and the
 *             module's distinct-holder count keeps tracking reality: it climbs to 4 against a cap of
 *             3, rather than clamping. The count must reflect what happened, not what was allowed.
 *           • `mint`, by contrast, DOES enforce the cap (it calls canTransfer → moduleCheck), proven
 *             in {MaxInvestorsModuleTest.test_mintCreatingHolderAtCap_reverts}.
 */
contract ForcedTransferCapBreachTest is TREXFixture {
    uint256 internal constant CAP = 3;
    uint256 internal constant XFER = 10_000e18;

    address internal investorE; // becomes the 3rd holder, taking the count to the cap
    address internal investorF; // the brand-new receiver a forced transfer creates past the cap

    function _maxInvestors() internal view override returns (uint256) {
        return CAP;
    }

    function setUp() public override {
        super.setUp();
        Ctx memory c = Ctx({
            token: token,
            identityRegistry: identityRegistry,
            idFactory: idFactory,
            claimIssuer: claimIssuer,
            deployerPk: vm.deriveKey(MNEMONIC, 0),
            agentPk: vm.deriveKey(MNEMONIC, 2),
            signerPk: vm.deriveKey(MNEMONIC, 1)
        });
        (investorE,) =
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 7), "forced-cap-e", COUNTRY_DE);
        (investorF,) =
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 8), "forced-cap-f", COUNTRY_LU);
    }

    function test_forcedTransfer_breachesCap_butActionHookStillTracks() public {
        // Drive the holder count to the cap: A and B are seeded holders (2); minting to E makes 3.
        vm.prank(agent);
        token.mint(investorE, XFER);
        assertEq(maxInvestorsModule.investorCount(address(compliance)), CAP, "count is at the cap");

        // Prove the cap WOULD block a holder-initiated move to a new wallet: moduleCheck says no.
        assertFalse(
            maxInvestorsModule.moduleCheck(investorA, investorF, XFER, address(compliance)),
            "moduleCheck rejects creating a new holder at the cap"
        );
        // And confirm that rejection is real: a normal transfer to F reverts.
        vm.prank(investorA);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transfer(investorF, XFER);

        // Now the break-glass path. forcedTransfer skips moduleCheck entirely, so the SAME move the
        // gate just refused goes through — creating F as a 4th holder past the cap of 3. (A keeps a
        // balance, so it stays a holder; the net effect is +1.)
        vm.prank(agent);
        token.forcedTransfer(investorA, investorF, XFER);

        assertEq(token.balanceOf(investorF), XFER, "forced transfer created the new holder");

        // The action hook still fired: the module's count climbed to 4, exceeding the cap of 3,
        // rather than clamping. moduleCheck was skipped; moduleTransferAction was NOT — so the
        // tracked count stays accurate to reality even though the rule was breached.
        assertEq(
            maxInvestorsModule.investorCount(address(compliance)),
            CAP + 1,
            "count tracks past the cap"
        );
        assertGt(
            maxInvestorsModule.investorCount(address(compliance)),
            maxInvestorsModule.maxInvestors(address(compliance)),
            "holder count now exceeds the configured cap - the documented agent-path breach"
        );
        assertEq(
            maxInvestorsModule.mirroredBalance(address(compliance), investorF),
            XFER,
            "the module's mirror recorded the new holder's balance"
        );
    }
}
