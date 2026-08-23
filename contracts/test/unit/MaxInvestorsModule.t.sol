// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { TREXFixture } from "../helpers/TREXFixture.sol";

import { ModularCompliance } from "@erc-3643/contracts/compliance/modular/ModularCompliance.sol";
import { Token } from "@erc-3643/contracts/token/Token.sol";

import { MaxInvestorsModule } from "../../src/modules/MaxInvestorsModule.sol";

/**
 * @title MaxInvestorsModule — distinct-holder cap, proven through the real token path.
 *
 * @notice Every assertion drives the module the way production does: through agent `mint`/`burn`
 *         and holder `transfer`, which route into `compliance.created`/`destroyed`/`transferred`
 *         and fan out to the module's hooks. The module's action hooks are `onlyComplianceCall`,
 *         so there is no way — and no reason — to poke them directly; exercising the token proves
 *         the count stays correct under the ONLY calls that can ever reach it.
 *
 *         The suite runs with a cap of {_maxInvestors} == 3 (overridden below): the production
 *         default of 199 is unreachable in a unit test, so a small cap is the only way to actually
 *         drive a holder-creating path into the limit rather than passing vacuously.
 *
 *         Seeded starting state (from {TREXFixture.setUp}): A and B are verified holders, so the
 *         module's count begins at 2 with room for exactly one more holder before the cap bites.
 *         The fixture's extra verified-but-empty investors E/F/G give us fresh wallets to create,
 *         zero out, and re-create without tripping the receiver-eligibility gate (gate 2), which
 *         would otherwise mask the cap behaviour we are testing.
 */
contract MaxInvestorsModuleTest is TREXFixture {
    uint256 internal constant CAP = 3;
    uint256 internal constant XFER = 1_000e18;

    // Mirror of {MaxInvestorsModule.MaxInvestorsSet} so vm.expectEmit can match it. Solidity
    // 0.8.17 cannot reference another contract's event in an `emit`, so we redeclare the exact
    // signature here; a drift from the module's declaration would break the expectation.
    event MaxInvestorsSet(address indexed _compliance, uint256 _maxInvestors);

    // Mirror of {MaxInvestorsModule.HolderCountChanged} — same rationale as above (0.8.17 cannot
    // reference another contract's event in an `emit`).
    event HolderCountChanged(address indexed _compliance, uint256 _newCount);

    // Fresh verified investors (identity + KYC/AML) that start with a zero balance. Distinct
    // Anvil indices (7/8) and salts from the fixture's own cast (0-6) so no key or salt collides.
    address internal investorE;
    address internal investorF;

    /// @dev Shrink the deployed cap to a value a unit test can reach. The base fixture reads this
    ///      hook when it calls {Deploy._deployAndWire}, so the whole suite deploys with cap == 3.
    function _maxInvestors() internal view override returns (uint256) {
        return CAP;
    }

    function setUp() public override {
        super.setUp();

        // Onboard two fully-verified, zero-balance investors by REUSING the seed's onboarding
        // helper (identity -> registerIdentity -> signed KYC/AML claims). No tokens are minted to
        // them here, so the holder count is still 2 (A, B) until a test creates them.
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
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 7), "cap-fixture-e", COUNTRY_DE);
        (investorF,) =
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 8), "cap-fixture-f", COUNTRY_LU);
    }

    // Convenience: the module's live count / mirror for THIS deployment's compliance.
    function _count() internal view returns (uint256) {
        return maxInvestorsModule.investorCount(address(compliance));
    }

    function _mirror(address holder) internal view returns (uint256) {
        return maxInvestorsModule.mirroredBalance(address(compliance), holder);
    }

    // ── Sanity: the deployed cap and the seeded count are what every test below assumes ───────
    function test_setUp_capAndCountAsExpected() public {
        assertEq(maxInvestorsModule.maxInvestors(address(compliance)), CAP, "cap deployed as 3");
        assertEq(_count(), 2, "A and B are the only holders after seeding");
        assertEq(_mirror(investorA), AMOUNT_A, "mirror tracks A's seeded balance");
        assertEq(_mirror(investorB), AMOUNT_B, "mirror tracks B's seeded balance");
        assertEq(_mirror(investorE), 0, "E onboarded but holds nothing");
    }

    // ── Count-transition edge cases (each is a distinct crossing rule) ────────────────────────

    // Transfer to an EXISTING holder, sender keeps a balance: no zero-crossing on either side, so
    // the distinct-holder count must not move — the property that stops routine trading from
    // inflating the count.
    function test_transferToExistingHolder_countUnchanged() public {
        assertEq(_count(), 2, "precondition");
        vm.prank(investorA);
        token.transfer(investorB, XFER);
        assertEq(_count(), 2, "moving tokens between two existing holders changes no count");
        assertEq(_mirror(investorA), AMOUNT_A - XFER, "sender mirror debited");
        assertEq(_mirror(investorB), AMOUNT_B + XFER, "receiver mirror credited");
    }

    // Transfer of the sender's ENTIRE balance to an existing holder: the sender crosses to zero
    // and stops being a holder, so the count must decrement by exactly one.
    function test_transferZeroesSender_countDecrements() public {
        vm.prank(investorA);
        token.transfer(investorB, AMOUNT_A); // A sends everything to B
        assertEq(_count(), 1, "sender leaving drops the holder count");
        assertEq(_mirror(investorA), 0, "A no longer holds");
        assertEq(_mirror(investorB), AMOUNT_B + AMOUNT_A, "B absorbed A's balance");
    }

    // Transfer of the sender's entire balance to a BRAND-NEW holder: one down-crossing (sender)
    // and one up-crossing (receiver) net to zero. Proves the count tracks the set of holders, not
    // the number of transfers — a swap of identities leaves the cap headroom unchanged.
    function test_transferZeroesSenderAndCreatesReceiver_netUnchanged() public {
        assertEq(_count(), 2, "precondition");
        vm.prank(investorA);
        token.transfer(investorE, AMOUNT_A); // A (existing) → E (new), full balance
        assertEq(_count(), 2, "one holder replaced by another: net zero");
        assertEq(_mirror(investorA), 0, "A exited");
        assertEq(_mirror(investorE), AMOUNT_A, "E entered with A's balance");
    }

    // Self-transfer of the FULL balance: the debit momentarily zeroes the wallet (−1) and the
    // credit restores it (+1). The net must be zero — a wallet sending to itself is still one
    // holder. This is the case a naive "did the receiver just go non-zero?" check gets wrong.
    function test_selfTransferFullBalance_countUnchanged() public {
        assertEq(_count(), 2, "precondition");
        vm.prank(investorA);
        token.transfer(investorA, AMOUNT_A);
        assertEq(_count(), 2, "self-transfer is a no-op for the holder set");
        assertEq(_mirror(investorA), AMOUNT_A, "A's mirror is unchanged after the round trip");
    }

    // Mint to an EXISTING holder tops up a balance without adding a wallet: count unchanged.
    function test_mintToExistingHolder_countUnchanged() public {
        assertEq(_count(), 2, "precondition");
        vm.prank(agent);
        token.mint(investorA, XFER);
        assertEq(_count(), 2, "minting more to a current holder adds no holder");
        assertEq(_mirror(investorA), AMOUNT_A + XFER, "A's mirror grew by the mint");
    }

    // Mint to a NEW verified wallet creates a holder: count increments (and mint, unlike forced
    // transfer, is subject to the cap — verified separately below).
    function test_mintToNewHolder_countIncrements() public {
        assertEq(_count(), 2, "precondition");
        vm.prank(agent);
        token.mint(investorE, XFER);
        assertEq(_count(), 3, "a new holder was created by mint");
        assertEq(_mirror(investorE), XFER, "E's mirror seeded by the mint");
    }

    // Burn that leaves a remainder: the holder stays above zero, so the count must not move.
    function test_burnDoesNotReachZero_countUnchanged() public {
        assertEq(_count(), 2, "precondition");
        vm.prank(agent);
        token.burn(investorA, XFER); // A still holds AMOUNT_A - XFER
        assertEq(_count(), 2, "a partial burn removes no holder");
        assertEq(_mirror(investorA), AMOUNT_A - XFER, "A's mirror debited by the burn");
    }

    // Burn of the entire balance: the holder crosses to zero and leaves the set → count decrements.
    function test_burnToZero_countDecrements() public {
        vm.prank(agent);
        token.burn(investorB, AMOUNT_B); // B's full balance
        assertEq(_count(), 1, "burning a holder to zero drops the count");
        assertEq(_mirror(investorB), 0, "B no longer holds");
    }

    // ── Cap enforcement on holder-initiated paths ─────────────────────────────────────────────

    // A transfer that would create the (cap+1)-th holder is rejected. With the count driven to the
    // cap (A, B, E), A's attempt to seed a brand-new wallet F must revert — the module's
    // moduleCheck returns false and the Token surfaces the standard eligibility revert. The count
    // must be untouched by the failed attempt.
    function test_transferCreatingHolderAtCap_reverts() public {
        vm.prank(agent);
        token.mint(investorE, XFER); // count → 3 == CAP
        assertEq(_count(), CAP, "count is at the cap");

        vm.prank(investorA);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transfer(investorF, XFER); // F would be the 4th holder

        assertEq(_count(), CAP, "rejected transfer left the count unchanged");
        assertEq(_mirror(investorF), 0, "F never became a holder");
    }

    // Mint enforces the SAME cap: minting a fresh holder at the cap reverts. This is the mint-side
    // proof that gate 3 (compliance.canTransfer) runs on mint — contrast forcedTransfer, which
    // skips it (see AgentControls). The revert string is the Token's, raised when canTransfer fails.
    function test_mintCreatingHolderAtCap_reverts() public {
        vm.prank(agent);
        token.mint(investorE, XFER); // count → 3 == CAP
        assertEq(_count(), CAP, "count is at the cap");

        vm.prank(agent);
        vm.expectRevert(bytes("Compliance not followed"));
        token.mint(investorF, XFER);

        assertEq(_count(), CAP, "rejected mint left the count unchanged");
    }

    // A transfer to an EXISTING holder is allowed even at the cap — it creates no new holder, so
    // the cap never applies. Guards against an over-eager check that blocks all transfers once full.
    function test_transferToExistingHolderAtCap_succeeds() public {
        vm.prank(agent);
        token.mint(investorE, XFER); // count → 3 == CAP
        assertEq(_count(), CAP, "at the cap");

        vm.prank(investorA);
        token.transfer(investorB, XFER); // both already holders
        assertEq(_count(), CAP, "count unchanged; transfer between existing holders allowed at cap");
    }

    // After a holder exits and the count falls below the cap, a new holder can enter again — the
    // cap is a live gate on the current set, not a monotonic high-water mark.
    function test_afterHolderExits_newHolderCanEnter() public {
        vm.prank(agent);
        token.mint(investorE, XFER); // count → 3 == CAP (A, B, E)
        assertEq(_count(), CAP, "at the cap");

        // A exits by sending its whole balance to B (an existing holder): count → 2.
        vm.prank(investorA);
        token.transfer(investorB, AMOUNT_A);
        assertEq(_count(), 2, "a seat opened up");

        // Now F can be created — the transfer that failed at the cap now succeeds.
        vm.prank(agent);
        token.mint(investorF, XFER);
        assertEq(_count(), CAP, "the freed seat was taken by a new holder");
        assertEq(_mirror(investorF), XFER, "F is now a holder");
    }

    // ── Configuration: cap of zero means "unlimited" ─────────────────────────────────────────

    // Setting the cap to 0 disables it: holder creation past the former cap then succeeds. Proves
    // the documented "0 = unlimited" convention rather than "0 = freeze everything".
    function test_capOfZero_disablesTheLimit() public {
        _setCapAsOwner(0);
        assertEq(maxInvestorsModule.maxInvestors(address(compliance)), 0, "cap cleared");

        // Create two new holders (E, F) — well past the old cap of 3 — without a revert.
        vm.startPrank(agent);
        token.mint(investorE, XFER);
        token.mint(investorF, XFER);
        vm.stopPrank();
        assertEq(_count(), 4, "unlimited cap admits holders past the former limit");
    }

    // ── Configuration access control: only the compliance owner may change the cap ────────────

    // The owner path: compliance.callModuleFunction (onlyOwner) reaches setMaxInvestors with
    // msg.sender == compliance, so the module accepts it and emits MaxInvestorsSet keyed to the
    // compliance. This is the sanctioned config route (NOTES §1.5).
    function test_ownerCanSetCap_andEmits() public {
        vm.expectEmit(true, false, false, true, address(maxInvestorsModule));
        emit MaxInvestorsSet(address(compliance), 7);
        _setCapAsOwner(7);
        assertEq(maxInvestorsModule.maxInvestors(address(compliance)), 7, "owner updated the cap");
    }

    // A non-owner cannot reach the setter through the compliance: callModuleFunction is onlyOwner,
    // so a stranger's attempt reverts at the compliance before it ever reaches the module.
    function test_nonOwnerCannotSetCapViaCompliance_reverts() public {
        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        compliance.callModuleFunction(
            abi.encodeWithSelector(MaxInvestorsModule.setMaxInvestors.selector, uint256(1)),
            address(maxInvestorsModule)
        );
        assertEq(maxInvestorsModule.maxInvestors(address(compliance)), CAP, "cap unchanged");
    }

    // A stranger cannot call the module's setter directly either: setMaxInvestors is
    // onlyComplianceCall, so anything but a bound compliance is rejected. This is the module-side
    // half of the access story — the setter is unreachable except through a bound compliance.
    function test_directSetCapFromStranger_reverts() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("only bound compliance can call"));
        maxInvestorsModule.setMaxInvestors(1);
        assertEq(maxInvestorsModule.maxInvestors(address(compliance)), CAP, "cap unchanged");
    }

    // ── Bind-safety: the module may only bind to a compliance whose token has no holders (M-1) ──
    //
    // The mirror initializes empty, so binding to a token that already has holders would start the
    // count below reality and make the cap silently under-enforce. The module opts OUT of
    // plug-and-play (isPlugAndPlay() == false) so ModularCompliance.addModule consults
    // canComplianceBind, which rejects a non-empty token in O(1) via totalSupply() == 0.

    // Reject path, driven through the REAL add path: the fixture's compliance already has holders
    // A and B (minted in setUp), so adding a fresh module instance to it must revert at the
    // canComplianceBind gate. addModule is onlyOwner, so we send it as the compliance owner
    // (deployer) — proving the rejection is the gate's, not an access-control accident.
    function test_bindToComplianceWithHolders_reverts() public {
        assertGt(token.totalSupply(), 0, "precondition: fixture token already has holders");

        MaxInvestorsModule fresh = new MaxInvestorsModule();
        assertFalse(
            fresh.canComplianceBind(address(compliance)),
            "a compliance whose token has holders is not bindable"
        );

        vm.prank(deployer);
        vm.expectRevert(bytes("compliance is not suitable for binding to the module"));
        compliance.addModule(address(fresh));

        assertFalse(
            compliance.isModuleBound(address(fresh)), "the rejected module was never bound"
        );
    }

    // Happy path: a fresh compliance + token with zero supply — the exact deploy-time state the
    // module is written for — binds successfully through the same addModule gate. This is what
    // {Deploy} relies on (addModule precedes the first mint).
    function test_bindPreMintToEmptyToken_succeeds() public {
        ModularCompliance emptyCompliance = new ModularCompliance();
        emptyCompliance.init();

        Token emptyToken = new Token();
        emptyToken.init(
            address(identityRegistry),
            address(emptyCompliance),
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS,
            address(0)
        );
        assertEq(emptyToken.totalSupply(), 0, "a freshly initialized token has no holders");

        MaxInvestorsModule fresh = new MaxInvestorsModule();
        assertTrue(
            fresh.canComplianceBind(address(emptyCompliance)), "an empty token is bindable"
        );

        emptyCompliance.addModule(address(fresh)); // owner == this test; must not revert
        assertTrue(emptyCompliance.isModuleBound(address(fresh)), "module bound to compliance");
        assertTrue(fresh.isComplianceBound(address(emptyCompliance)), "compliance bound on module");
    }

    // A compliance with NO token bound is rejected: binding is only allowed once a token is bound,
    // forcing addModule to run after bindToken. Permitting a token-less bind would leave open
    // addModule -> bindToken(tokenWithHolders), which never re-runs this gate and reaches the same
    // under-counted mirror M-1 prevents (see canComplianceBind NatSpec / NOTES §9).
    function test_canComplianceBind_falseWhenNoTokenBound() public {
        ModularCompliance tokenlessCompliance = new ModularCompliance();
        tokenlessCompliance.init();
        assertFalse(
            maxInvestorsModule.canComplianceBind(address(tokenlessCompliance)),
            "no token bound -> reject; addModule must run after bindToken"
        );
    }

    // Same rejection driven through the REAL add path: addModule against a token-less compliance
    // must revert at the canComplianceBind gate, so an operator cannot add-then-bind-later.
    function test_addModuleToTokenlessCompliance_reverts() public {
        ModularCompliance tokenlessCompliance = new ModularCompliance();
        tokenlessCompliance.init();

        MaxInvestorsModule fresh = new MaxInvestorsModule();
        vm.expectRevert(bytes("compliance is not suitable for binding to the module"));
        tokenlessCompliance.addModule(address(fresh)); // owner == this test

        assertFalse(
            tokenlessCompliance.isModuleBound(address(fresh)), "the rejected module was never bound"
        );
    }

    // The stable module identifier used by tooling and the address book.
    function test_name_isStable() public {
        assertEq(maxInvestorsModule.name(), "MaxInvestorsModule", "module name is stable");
    }

    // The module deliberately opts OUT of plug-and-play so addModule runs the canComplianceBind
    // gate (M-1). Asserting it directly documents the choice and pins the behaviour.
    function test_isPlugAndPlay_isFalse() public {
        assertFalse(
            maxInvestorsModule.isPlugAndPlay(),
            "module opts out of plug-and-play so the bind gate runs"
        );
    }

    // ── Indexer signal: HolderCountChanged fires on (and only on) a real crossing (L-2) ─────────

    // A mint that creates a new holder emits HolderCountChanged with the post-crossing count, so the
    // indexer can track holder counts directly instead of re-deriving them from Transfer logs.
    function test_mintNewHolder_emitsHolderCountChanged() public {
        assertEq(_count(), 2, "precondition");
        vm.expectEmit(true, false, false, true, address(maxInvestorsModule));
        emit HolderCountChanged(address(compliance), 3);
        vm.prank(agent);
        token.mint(investorE, XFER);
    }

    // A burn that zeroes a holder emits the decremented count on the down-crossing.
    function test_burnToZero_emitsHolderCountChanged() public {
        vm.expectEmit(true, false, false, true, address(maxInvestorsModule));
        emit HolderCountChanged(address(compliance), 1);
        vm.prank(agent);
        token.burn(investorB, AMOUNT_B);
    }

    // A top-up mint to an EXISTING holder creates no crossing, so it must emit no
    // HolderCountChanged. We assert the count is unchanged across the call (a spurious emit would
    // signal a crossing that did not happen).
    function test_mintToExistingHolder_noCrossingNoCountChange() public {
        assertEq(_count(), 2, "precondition");
        vm.prank(agent);
        token.mint(investorA, XFER); // A already holds
        assertEq(_count(), 2, "a top-up creates no crossing, so the count is unchanged");
    }

    /// @dev Set the cap through the sanctioned owner path (the deployer owns the compliance in the
    ///      fixture). Mirrors exactly how {Deploy} configures the module.
    function _setCapAsOwner(uint256 newCap) internal {
        vm.prank(deployer);
        compliance.callModuleFunction(
            abi.encodeWithSelector(MaxInvestorsModule.setMaxInvestors.selector, newCap),
            address(maxInvestorsModule)
        );
    }
}
