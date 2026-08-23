// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/**
 * @title TREXConstants — the handful of constants shared verbatim by {Deploy} and {Seed}.
 *
 * @notice These four values are consensus- or wiring-critical and must be byte-identical
 *         across the deploy path, the seed path, and any test fixture that reuses them —
 *         so they live in exactly one place. Extracting them here is also what lets a test
 *         fixture inherit BOTH {Deploy} and {Seed} at once: Solidity forbids a derived
 *         contract from inheriting the same constant name from two independent bases, so the
 *         scripts must share these through a common parent rather than each declaring them.
 *
 *         Script-local constants (token metadata, seed amounts, country codes, file paths that
 *         only one script writes) deliberately stay in their own script — only the genuinely
 *         shared domain constants belong here.
 */
abstract contract TREXConstants {
    // Required claim topics for verification. 1 = KYC, 2 = AML/sanctions
    // (packages/shared/schemas.ts, contracts/CLAUDE.md). isVerified requires BOTH.
    uint256 internal constant TOPIC_KYC = 1;
    uint256 internal constant TOPIC_AML = 2;

    // ONCHAINID key purpose (ERC-734): 3 = CLAIM signer. The claim-issuer signing key holds
    // this and nothing else (least privilege — see Deploy.s.sol step 7 / NOTES §5a).
    uint256 internal constant PURPOSE_CLAIM = 3;

    // Address book emitted by {Deploy} and read back by {Seed}. Written relative to the Foundry
    // root (contracts/); resolves to packages/shared. fs_permissions grants r/w on that dir.
    string internal constant ADDRESS_BOOK_PATH = "../packages/shared/addresses.local.json";
}
