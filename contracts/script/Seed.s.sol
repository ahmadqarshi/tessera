// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IdentityRegistry } from "@erc-3643/contracts/registry/implementation/IdentityRegistry.sol";
import { Token } from "@erc-3643/contracts/token/Token.sol";

import { Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IdFactory } from "@onchain-id/solidity/contracts/factory/IdFactory.sol";
import { ClaimIssuer } from "@onchain-id/solidity/contracts/ClaimIssuer.sol";
import { IIdentity } from "@onchain-id/solidity/contracts/interface/IIdentity.sol";

import { TREXConstants } from "./TREXConstants.sol";

/**
 * @title Seed — demo investors, on-chain KYC/AML claims, and a primary distribution.
 *
 * @notice Consumes the suite deployed and wired by {Deploy} (read from the local address
 *         book) and brings the identity model to life: it onboards two verified institutional
 *         investors, leaves one deliberately unverified as a negative-path fixture, and
 *         distributes tokens to the two verified holders. Every claim is signed with the exact
 *         ERC-735 scheme-1 digest that {ClaimIssuer.isClaimValid} recovers, so a mistake in the
 *         signing recipe surfaces immediately — `Identity.addClaim` itself calls
 *         `isClaimValid` and reverts on a bad signature (Identity.sol:356).
 *
 *         The script asserts the identity gate at the end: A and B verify, C does not, and the
 *         distributed balances are exactly what we minted. A half-seeded run reverts here rather
 *         than reporting success.
 *
 * ── Key model (mirrors Deploy; least privilege) ────────────────────────────────────────────
 *   DEPLOYER_PRIVATE_KEY          Owner of the IdFactory — the only key that may
 *                                 `createIdentity`. Broadcasts identity creation.
 *   AGENT_PRIVATE_KEY             Agent on Token + IdentityRegistry. Broadcasts
 *                                 `registerIdentity` and `mint`.
 *   CLAIM_ISSUER_PRIVATE_KEY      The purpose-3 CLAIM signer registered on the ClaimIssuer by
 *                                 Deploy. Signs claims OFF-CHAIN (vm.sign) — never broadcasts.
 *   Investor A/B/C keys           Derived from ANVIL_MNEMONIC at indices 3/4/5 (distinct from
 *                                 deployer #0, signer #1, agent #2). Each investor broadcasts
 *                                 `addClaim` on its OWN identity: the wallet is its identity's
 *                                 purpose-1 MANAGEMENT key, which satisfies `onlyClaimKey`.
 *
 * ── Two traps, per contracts/NOTES.md §5/§5a ───────────────────────────────────────────────
 *   1. The signed digest hashes the INVESTOR'S IDENTITY address; the claimId (looked up by
 *      `isVerified`) hashes the ISSUER address. They are different addresses — do not conflate.
 *   2. `addClaim` is `onlyClaimKey` on the investor's OWN identity, so it must be broadcast by a
 *      purpose-3 claim key on that identity — the investor wallet itself, NOT the deployer or
 *      the issuer. We therefore switch the broadcast sender to the investor for that call.
 */
contract Seed is Script, TREXConstants {
    // Shared claim-topic + purpose + address-book constants are inherited from {TREXConstants}.
    // ERC-735 claim scheme: 1 = ECDSA over the `eth_sign` prefixed hash (NOT EIP-712).
    uint256 internal constant SCHEME_ECDSA = 1;

    // ISO 3166-1 numeric country codes. A = Germany (276), B = Luxembourg (442).
    uint16 internal constant COUNTRY_DE = 276;
    uint16 internal constant COUNTRY_LU = 442;

    // Anvil derivation indices. #0/#1/#2 are deployer/signer/agent (see .env.example); the
    // three investors take the next slots so no key wears two hats.
    uint32 internal constant IDX_INVESTOR_A = 3;
    uint32 internal constant IDX_INVESTOR_B = 4;
    uint32 internal constant IDX_INVESTOR_C = 5;

    // Primary distribution (18 decimals — the token's decimals, asserted below).
    uint256 internal constant AMOUNT_A = 250_000 * 1e18;
    uint256 internal constant AMOUNT_B = 100_000 * 1e18;

    // Claim payloads. NEVER PII (rule 2): only a topic label lives on-chain; the personal data
    // that backs it stays with the KYC/AML provider. The exact same bytes are signed AND stored,
    // because `isClaimValid` re-hashes the stored `data` to recover the signer.
    bytes internal constant KYC_DATA = bytes("KYC verified by Tessera claim issuer");
    bytes internal constant AML_DATA = bytes("AML/sanctions cleared by Tessera claim issuer");

    // Human labels for the seeded investors — the manifest's source of truth; the console log
    // mirrors them.
    string internal constant LABEL_A = "Halvorsen Capital AG";
    string internal constant LABEL_B = "Orbis Family Office";
    string internal constant LABEL_C = "Unverified negative fixture";

    // The address book (_addressBookPath(), inherited from {TREXConstants}) is the file Deploy
    // emits and Seed reads back; the seed manifest below is ours to write. fs_permissions in
    // foundry.toml grants read-write on the packages/shared directory that holds both. The
    // manifest name is chain-selected for the same reason as the address book — a seed on Amoy
    // must not clobber the local manifest.
    function _seedManifestPath() internal view returns (string memory) {
        if (block.chainid == CHAINID_LOCAL) return "../packages/shared/seed.local.json";
        if (block.chainid == CHAINID_AMOY) return "../packages/shared/seed.amoy.json";
        revert("seed manifest: unsupported chainid (expected 31337 local or 80002 amoy)");
    }

    /// @dev BIP-39 mnemonic the investor A/B/C wallets are derived from, chain-selected with the
    ///      same guard as {_addressBookPath}. Local Anvil must use the fixed test mnemonic — its
    ///      derived accounts are the ones Anvil pre-funds, so `seed:local` stays zero-config and
    ///      byte-identical (SEED_MNEMONIC is deliberately ignored there for reproducibility). On
    ///      Amoy the investor wallets must be distinct, fundable EOAs you control — never the
    ///      public Anvil keys — so we prefer SEED_MNEMONIC, falling back to ANVIL_MNEMONIC when it
    ///      is unset. Unknown chains revert rather than silently seeding the wrong keys.
    function _seedMnemonic() internal view returns (string memory) {
        if (block.chainid == CHAINID_LOCAL) return vm.envString("ANVIL_MNEMONIC");
        if (block.chainid == CHAINID_AMOY) {
            return vm.envOr("SEED_MNEMONIC", vm.envString("ANVIL_MNEMONIC"));
        }
        revert("seed mnemonic: unsupported chainid (expected 31337 local or 80002 amoy)");
    }

    /// @dev Live handles resolved from the address book, plus the signing keys, kept in one
    ///      struct so helpers stay under the stack-depth limit.
    struct Ctx {
        Token token;
        IdentityRegistry identityRegistry;
        IdFactory idFactory;
        ClaimIssuer claimIssuer;
        uint256 deployerPk;
        uint256 agentPk;
        uint256 signerPk;
    }

    function run() external virtual {
        Ctx memory c = _loadContext();

        // ── Onboard the two verified investors ─────────────────────────────────────────────
        // One mnemonic read (chain-selected: ANVIL_MNEMONIC locally, SEED_MNEMONIC on Amoy).
        string memory mnemonic = _seedMnemonic();
        uint256 pkA = vm.deriveKey(mnemonic, IDX_INVESTOR_A);
        uint256 pkB = vm.deriveKey(mnemonic, IDX_INVESTOR_B);
        address walletC = vm.addr(vm.deriveKey(mnemonic, IDX_INVESTOR_C));

        (address walletA, address identityA) =
            _onboardVerifiedInvestor(c, pkA, "halvorsen-capital-ag", COUNTRY_DE);
        (address walletB, address identityB) =
            _onboardVerifiedInvestor(c, pkB, "orbis-family-office", COUNTRY_LU);

        // Investor C: a wallet with NO identity and NO claims — the negative-path fixture.
        // We intentionally do nothing for it on-chain; `isVerified` must return false.

        // ── Primary distribution (agent-signed token op, rule 6/7) ─────────────────────────
        vm.startBroadcast(c.agentPk);
        c.token.mint(walletA, AMOUNT_A);
        c.token.mint(walletB, AMOUNT_B);
        vm.stopBroadcast();

        // ── The gate: this is the moment the identity model is actually working ────────────
        _assertSeed(c, walletA, walletB, walletC);

        // Manifest for Phase 2/3 e2e tests: seeded wallets, their ONCHAINIDs, and the exact
        // balances distributed — written alongside the address book so tests need not rediscover.
        _writeSeedManifest(c, walletA, identityA, walletB, identityB, walletC);
        _logSeed(walletA, identityA, walletB, identityB, walletC, c);
    }

    /// @dev Resolves live contract handles from the address book Deploy wrote, and reads the
    ///      three broadcasting keys from env. Fails loudly if the book is missing a contract.
    function _loadContext() internal view returns (Ctx memory c) {
        string memory json = vm.readFile(_addressBookPath());
        c.token = Token(vm.parseJsonAddress(json, ".contracts.Token"));
        c.identityRegistry =
            IdentityRegistry(vm.parseJsonAddress(json, ".contracts.IdentityRegistry"));
        c.idFactory = IdFactory(vm.parseJsonAddress(json, ".contracts.IdFactory"));
        c.claimIssuer = ClaimIssuer(vm.parseJsonAddress(json, ".contracts.ClaimIssuer"));

        c.deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        c.agentPk = vm.envUint("AGENT_PRIVATE_KEY");
        c.signerPk = vm.envUint("CLAIM_ISSUER_PRIVATE_KEY");

        // Fail early and loudly if the signing key is not the issuer's registered purpose-3
        // CLAIM key. Without this, an inconsistent env rotation surfaces only as an opaque
        // "invalid claim" revert inside addClaim (Identity.sol:356) — no hint at the cause.
        require(
            c.claimIssuer.keyHasPurpose(keccak256(abi.encode(vm.addr(c.signerPk))), PURPOSE_CLAIM),
            "seed: CLAIM_ISSUER_PRIVATE_KEY is not a purpose-3 claim key on the ClaimIssuer"
        );
    }

    /**
     * @dev Full onboarding for one verified investor:
     *      1. deployer  → IdFactory.createIdentity(wallet)         (onlyOwner)
     *      2. agent     → IdentityRegistry.registerIdentity(...)   (onlyAgent)
     *      3. off-chain → sign KYC + AML claims with the claim-signer key
     *      4. investor  → addClaim(...) x2 on its OWN identity      (onlyClaimKey)
     */
    function _onboardVerifiedInvestor(
        Ctx memory c,
        uint256 investorPk,
        string memory salt,
        uint16 country
    ) internal returns (address wallet, address identity) {
        (wallet, identity) = _registerInvestor(c, investorPk, salt, country);
        _addKycAmlClaims(c, investorPk, identity);
    }

    /**
     * @dev Steps 1–2 of onboarding: create the investor's ONCHAINID and register the
     *      wallet → (identity, country) mapping. Stops SHORT of adding claims, so the wallet is
     *      "registered but unverified" until {_addKycAmlClaims} runs. Split out from
     *      {_onboardVerifiedInvestor} so callers can compose an investor with an identity but
     *      *no* claims — the distinct negative-path fixture that a claim-less holder represents
     *      (a different verification failure than a wallet with no identity at all).
     */
    function _registerInvestor(
        Ctx memory c,
        uint256 investorPk,
        string memory salt,
        uint16 country
    ) internal returns (address wallet, address identity) {
        wallet = vm.addr(investorPk);

        // 1. Create the investor's ONCHAINID via the factory (deployer owns the factory).
        vm.startBroadcast(c.deployerPk);
        identity = c.idFactory.createIdentity(wallet, salt);
        vm.stopBroadcast();

        // 2. Register the wallet → (identity, country) mapping (agent role on the IR).
        vm.startBroadcast(c.agentPk);
        c.identityRegistry.registerIdentity(wallet, IIdentity(identity), country);
        vm.stopBroadcast();
    }

    /**
     * @dev Steps 3–4 of onboarding: sign the KYC + AML claims off-chain with the claim-signer
     *      key and have the investor add them to its OWN identity.
     */
    function _addKycAmlClaims(Ctx memory c, uint256 investorPk, address identity) internal {
        // 3. Sign both claims off-chain. Trap #1: the digest binds the INVESTOR'S IDENTITY
        //    address, not the issuer's.
        bytes memory kycSig = _signClaim(c.signerPk, identity, TOPIC_KYC, KYC_DATA);
        bytes memory amlSig = _signClaim(c.signerPk, identity, TOPIC_AML, AML_DATA);

        // 4. The investor adds the claims to its own identity. Trap #2: `addClaim` is
        //    `onlyClaimKey` on THIS identity, so the sender must be the investor wallet (its
        //    purpose-1 management key satisfies the check) — not the deployer or the issuer.
        vm.startBroadcast(investorPk);
        Identity(identity).addClaim(
            TOPIC_KYC, SCHEME_ECDSA, address(c.claimIssuer), kycSig, KYC_DATA, ""
        );
        Identity(identity).addClaim(
            TOPIC_AML, SCHEME_ECDSA, address(c.claimIssuer), amlSig, AML_DATA, ""
        );
        vm.stopBroadcast();
    }

    /**
     * @dev Produces a 65-byte ERC-735 scheme-1 signature over the exact digest
     *      `ClaimIssuer.isClaimValid` recovers (contracts/NOTES.md §5):
     *          digest       = keccak256(abi.encode(identity, topic, data))
     *          prefixedHash = keccak256("\x19Ethereum Signed Message:\n32" ++ digest)
     *          signature    = r ++ s ++ v          (packed, 65 bytes)
     *      `identity` is the INVESTOR'S identity address (the claim holder), not the issuer.
     */
    function _signClaim(uint256 signerKey, address identity, uint256 topic, bytes memory data)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 digest = keccak256(abi.encode(identity, topic, data));
        bytes32 prefixedHash =
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, prefixedHash);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @dev The gate. A and B must verify, C must not, balances must equal the distribution,
     *      and the token must be live. Any failure reverts the whole seed.
     */
    function _assertSeed(Ctx memory c, address walletA, address walletB, address walletC)
        internal
        view
    {
        require(c.identityRegistry.isVerified(walletA), "seed: investor A is not verified");
        require(c.identityRegistry.isVerified(walletB), "seed: investor B is not verified");
        require(
            !c.identityRegistry.isVerified(walletC),
            "seed: investor C unexpectedly verified (negative fixture broken)"
        );

        require(c.token.balanceOf(walletA) == AMOUNT_A, "seed: investor A balance mismatch");
        require(c.token.balanceOf(walletB) == AMOUNT_B, "seed: investor B balance mismatch");

        require(c.token.decimals() == 18, "seed: token decimals != 18 (distribution scaled wrong)");
        require(!c.token.paused(), "seed: token is paused");
    }

    /**
     * @dev Emits packages/shared/seed.local.json: the seeded wallets, their ONCHAINID contracts,
     *      country, verification status, and the exact distributed balances (base-unit decimal
     *      strings, per the shared amount convention). Phase 2/3 e2e tests consume this so they
     *      never re-derive seed state. C's identity is address(0) — it has none, by design.
     */
    function _writeSeedManifest(
        Ctx memory c,
        address walletA,
        address identityA,
        address walletB,
        address identityB,
        address walletC
    ) internal {
        string memory investors = "seedInvestors";
        vm.serializeString(
            investors, "A", _investorJson("invA", LABEL_A, walletA, identityA, COUNTRY_DE, true, AMOUNT_A)
        );
        vm.serializeString(
            investors, "B", _investorJson("invB", LABEL_B, walletB, identityB, COUNTRY_LU, true, AMOUNT_B)
        );
        string memory investorsJson = vm.serializeString(
            investors, "C", _investorJson("invC", LABEL_C, walletC, address(0), 0, false, 0)
        );

        string memory root = "seedManifest";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "token", address(c.token));
        string memory json = vm.serializeString(root, "investors", investorsJson);

        string memory path = _seedManifestPath();
        vm.writeJson(json, path);
        console2.log("Seed manifest written to", path);
    }

    /// @dev Serializes one investor object; `objId` must be unique across the manifest so
    ///      Foundry's JSON registry keeps the three objects distinct.
    function _investorJson(
        string memory objId,
        string memory label,
        address wallet,
        address identity,
        uint16 country,
        bool verified,
        uint256 balance
    ) internal returns (string memory) {
        vm.serializeString(objId, "label", label);
        vm.serializeAddress(objId, "wallet", wallet);
        vm.serializeAddress(objId, "identity", identity);
        vm.serializeUint(objId, "country", country);
        vm.serializeBool(objId, "verified", verified);
        return vm.serializeString(objId, "balance", vm.toString(balance));
    }

    function _logSeed(
        address walletA,
        address identityA,
        address walletB,
        address identityB,
        address walletC,
        Ctx memory c
    ) internal view {
        console2.log("=== Tessera seed ===");
        console2.log("chainId        ", block.chainid);
        console2.log("-- Investor A: Halvorsen Capital AG (DE / 276) --");
        console2.log("  wallet        ", walletA);
        console2.log("  identity      ", identityA);
        console2.log("  verified      ", c.identityRegistry.isVerified(walletA));
        console2.log("  balance (BER-A)", c.token.balanceOf(walletA));
        console2.log("-- Investor B: Orbis Family Office (LU / 442) --");
        console2.log("  wallet        ", walletB);
        console2.log("  identity      ", identityB);
        console2.log("  verified      ", c.identityRegistry.isVerified(walletB));
        console2.log("  balance (BER-A)", c.token.balanceOf(walletB));
        console2.log("-- Investor C: unverified negative fixture --");
        console2.log("  wallet        ", walletC);
        console2.log("  verified      ", c.identityRegistry.isVerified(walletC));
        console2.log("total supply   ", c.token.totalSupply());
        console2.log("token paused   ", c.token.paused());
    }
}
