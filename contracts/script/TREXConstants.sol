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
    //
    // Chain-selected, NOT a single constant: the file name must match the chain we are actually
    // deploying to, or an Amoy run would silently overwrite the local book (and Seed on Amoy
    // would read local addresses). We derive it from block.chainid so the same script serves both
    // networks with no flag. Only the two chains this repo targets are recognised — any other id
    // reverts loudly rather than writing a mislabeled book. The design mockups' "Base · 8453" is
    // visual filler and is deliberately NOT a branch here (root CLAUDE.md).
    uint256 internal constant CHAINID_LOCAL = 31337;
    uint256 internal constant CHAINID_AMOY = 80002;

    /// @dev packages/shared/addresses.<network>.json for the current chain. Both `access` grants
    ///      in foundry.toml scope to the packages/shared directory, so either file is writable.
    function _addressBookPath() internal view returns (string memory) {
        if (block.chainid == CHAINID_LOCAL) return "../packages/shared/addresses.local.json";
        if (block.chainid == CHAINID_AMOY) return "../packages/shared/addresses.amoy.json";
        revert("address book: unsupported chainid (expected 31337 local or 80002 amoy)");
    }
}
