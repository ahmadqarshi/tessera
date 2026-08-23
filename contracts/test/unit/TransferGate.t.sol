// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Identity } from "@onchain-id/solidity/contracts/Identity.sol";

import { TREXFixture } from "../helpers/TREXFixture.sol";

/**
 * @title TransferGate — the ERC-3643 eligibility gate, proven end to end.
 *
 * @notice The Phase 1 milestone: a compliant transfer succeeds, and every non-compliant one is
 *         rejected ON-CHAIN by a revert — not flagged, not logged. These tests exercise the
 *         receiver-eligibility leg of {Token.transfer}: `isVerified(_to)` must hold, and it holds
 *         only when the receiver has an identity in the registry carrying valid claims for every
 *         required topic (KYC + AML).
 *
 *         Note the gate checks the RECEIVER, not the sender — so the revocation tests below revoke
 *         the receiver's (B's) claim, which is what actually blocks a transfer into B.
 *
 *         The revert string is `"Transfer not possible"` for every eligibility failure:
 *         {Token.transfer} evaluates `isVerified(_to) && canTransfer(...)` and falls through to a
 *         single `revert("Transfer not possible")` (Token.sol:425) when either is false. Distinct
 *         *causes* therefore surface as the *same* string — the tests document which cause each
 *         one hits.
 */
contract TransferGateTest is TREXFixture {
    uint256 internal constant XFER = 10_000e18;

    // ── 1. Happy path: verified → verified moves balances ───────────────────────────────────
    function test_VerifiedToVerified_transferSucceeds() public {
        uint256 fromBefore = token.balanceOf(investorA);
        uint256 toBefore = token.balanceOf(investorB);

        vm.prank(investorA);
        token.transfer(investorB, XFER);

        assertEq(token.balanceOf(investorA), fromBefore - XFER, "sender debited");
        assertEq(token.balanceOf(investorB), toBefore + XFER, "receiver credited");
    }

    // ── 2. Receiver has NO identity at all (C) → revert ─────────────────────────────────────
    // Cause: `isVerified(C)` is false because C was never registered — the registry has no
    // ONCHAINID for the wallet, so verification stops before any claim is even considered.
    function test_TransferToUnregisteredWallet_reverts() public {
        assertFalse(identityRegistry.contains(investorC), "C must have no identity registered");

        vm.prank(investorA);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transfer(investorC, XFER);
    }

    // ── 3. Receiver is REGISTERED but has NO claims (D) → revert ─────────────────────────────
    // Reaches the SAME `"Transfer not possible"` revert as test 2, but by a DISTINCT path: D
    // *is* in the registry (contains == true), so verification proceeds — and then `isVerified`
    // fails while looping the required topics, finding no valid KYC/AML claim on D's identity.
    // Test 2 fails on a missing identity; this fails on missing claims for an existing identity.
    function test_TransferToRegisteredButUnclaimed_reverts() public {
        assertTrue(identityRegistry.contains(investorD), "D must be registered (unlike C)");
        assertFalse(identityRegistry.isVerified(investorD), "D must be unverified (no claims)");

        vm.prank(investorA);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transfer(investorD, XFER);
    }

    // ── 4a. Claim revocation, ISSUER side ───────────────────────────────────────────────────
    // `claimIssuer.revokeClaim` flips the claim to invalid via the `!isClaimRevoked(signature)`
    // leg of `isClaimValid`, WITHOUT touching the investor's Identity: the claim is still stored
    // on-chain, just no longer valid. This is the mechanism a compliance operator actually uses,
    // because it needs no cooperation from the investor (contrast 4b, which is onlyClaimKey).
    function test_IssuerSideRevocation_blocksTransfer() public {
        assertTrue(identityRegistry.isVerified(investorB), "B verified before revocation");
        bytes32 kycClaimId = keccak256(abi.encode(address(claimIssuer), TOPIC_KYC));

        // onlyManager → the ClaimIssuer's management key, which is the deployer.
        vm.prank(deployer);
        claimIssuer.revokeClaim(kycClaimId, identityB);

        // Verification now fails — but the claim record itself is UNTOUCHED on the identity.
        assertFalse(identityRegistry.isVerified(investorB), "B unverified after issuer revocation");
        assertEq(
            Identity(identityB).getClaimIdsByTopic(TOPIC_KYC).length,
            1,
            "issuer-side revoke leaves the claim stored (only marks it revoked)"
        );

        vm.prank(investorA);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transfer(investorB, XFER);
    }

    // ── 4b. Claim revocation, IDENTITY side ─────────────────────────────────────────────────
    // `identity.removeClaim` DELETES the claim entirely from the investor's Identity. It is
    // `onlyClaimKey`, so it must be sent by the investor (its wallet is the identity's purpose-1
    // management key, which satisfies the check). A different mechanism from 4a — do not conflate:
    // 4a leaves the claim stored-but-invalid; 4b removes it outright.
    function test_IdentitySideRemoval_blocksTransfer() public {
        assertTrue(identityRegistry.isVerified(investorB), "B verified before removal");
        bytes32 kycClaimId = keccak256(abi.encode(address(claimIssuer), TOPIC_KYC));

        vm.prank(investorB);
        Identity(identityB).removeClaim(kycClaimId);

        // Verification fails AND the claim is gone entirely (contrast the issuer-side path above).
        assertFalse(identityRegistry.isVerified(investorB), "B unverified after claim removal");
        assertEq(
            Identity(identityB).getClaimIdsByTopic(TOPIC_KYC).length,
            0,
            "identity-side removal deletes the claim outright"
        );

        vm.prank(investorA);
        vm.expectRevert(bytes("Transfer not possible"));
        token.transfer(investorB, XFER);
    }
}
