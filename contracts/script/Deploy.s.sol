// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

// --- T-REX (ERC-3643) core, deployed directly (no proxy) per contracts/NOTES.md §1.0 ---
import {
    ClaimTopicsRegistry
} from "@erc-3643/contracts/registry/implementation/ClaimTopicsRegistry.sol";
import {
    TrustedIssuersRegistry
} from "@erc-3643/contracts/registry/implementation/TrustedIssuersRegistry.sol";
import {
    IdentityRegistryStorage
} from "@erc-3643/contracts/registry/implementation/IdentityRegistryStorage.sol";
import { IdentityRegistry } from "@erc-3643/contracts/registry/implementation/IdentityRegistry.sol";
import { ModularCompliance } from "@erc-3643/contracts/compliance/modular/ModularCompliance.sol";
import { Token } from "@erc-3643/contracts/token/Token.sol";

// --- ONCHAINID: identity library + implementation authority + factory + claim issuer ---
import { Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import {
    ImplementationAuthority
} from "@onchain-id/solidity/contracts/proxy/ImplementationAuthority.sol";
import { IdFactory } from "@onchain-id/solidity/contracts/factory/IdFactory.sol";
import { ClaimIssuer } from "@onchain-id/solidity/contracts/ClaimIssuer.sol";
import { IClaimIssuer } from "@onchain-id/solidity/contracts/interface/IClaimIssuer.sol";

// --- Our one custom compliance module (extends IModule; the audited core is never forked) ---
import { MaxInvestorsModule } from "../src/modules/MaxInvestorsModule.sol";

import { TREXConstants } from "./TREXConstants.sol";

/**
 * @title Deploy — manual ERC-3643 (T-REX) + ONCHAINID suite deployment.
 *
 * @notice Deploys and wires a complete permissioned-security-token stack to a local chain,
 *         then asserts, in-script, that every wire took effect. A half-wired deployment
 *         reverts here rather than reporting success.
 *
 *         This is the *manual* path required by contracts/CLAUDE.md: each contract is
 *         deployed and initialized explicitly (no TREXFactory) so the wiring order and
 *         access-control assumptions are reviewable line by line. The ordering follows
 *         contracts/NOTES.md §6 (reconciled with the vendored source, which supersedes the
 *         skill docs where they differ).
 *
 * ── Key model (deliberate least privilege) ────────────────────────────────────────────────
 *   DEPLOYER_PRIVATE_KEY         Deploys everything and owns every registry/token/compliance.
 *                                Also the ClaimIssuer's MANAGEMENT key, so it — and only it —
 *                                can add/remove keys on the issuer.
 *   AGENT_ADDRESS                Holds the agent role on Token + IdentityRegistry (registers
 *                                investors, mints, freezes, pauses). AGENT_PRIVATE_KEY signs
 *                                the unpause below — an agent (token) operation per rule 7.
 *   CLAIM_ISSUER_MANAGEMENT_ADDRESS  Management key of the ClaimIssuer. Must equal the deployer
 *                                for this single-broadcast manual script (see the require below):
 *                                registering the signer key calls addKey(), which is onlyManager.
 *   CLAIM_ISSUER_SIGNER_ADDRESS  A DISTINCT signing EOA registered as a purpose-3 CLAIM key on
 *                                the ClaimIssuer (see the rationale block at the addKey call).
 */
contract Deploy is Script, TREXConstants {
    // Shared claim-topic + purpose + address-book constants are inherited from {TREXConstants}.
    // ONCHAINID keyType 1 = ECDSA (the type of the purpose-3 claim signer key).
    uint256 internal constant KEYTYPE_ECDSA = 1;

    // Token metadata for the showcase asset.
    string internal constant TOKEN_NAME = "Vestry Row Fund I";
    string internal constant TOKEN_SYMBOL = "BER-A";
    uint8 internal constant TOKEN_DECIMALS = 18;

    // Default distinct-holder cap for the showcase offering (e.g. a sub-200-investor private
    // placement). Passed to {_deployAndWire} so the value lives in exactly one place; the test
    // fixture calls the same helper with a smaller cap it can actually reach (see TREXFixture).
    uint256 internal constant DEFAULT_MAX_INVESTORS = 199;

    /// @dev Every deployed contract, passed by memory pointer to keep the stack shallow.
    struct Deployed {
        ClaimTopicsRegistry claimTopicsRegistry;
        TrustedIssuersRegistry trustedIssuersRegistry;
        IdentityRegistryStorage identityRegistryStorage;
        IdentityRegistry identityRegistry;
        ModularCompliance compliance;
        MaxInvestorsModule maxInvestorsModule;
        Token token;
        Identity identityLibrary;
        ImplementationAuthority implementationAuthority;
        IdFactory idFactory;
        ClaimIssuer claimIssuer;
        uint256 deployBlock;
    }

    function run() external virtual {
        // ── Inputs (no hardcoded keys; all from env) ──────────────────────────────────────
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address agent = vm.envAddress("AGENT_ADDRESS");
        address claimIssuerManagement = vm.envAddress("CLAIM_ISSUER_MANAGEMENT_ADDRESS");
        address claimIssuerSigner = vm.envAddress("CLAIM_ISSUER_SIGNER_ADDRESS");

        // The unpause is a token (agent) operation, so it is signed by the agent wallet
        // (rule 6/7). We read the agent key only to broadcast that one call and assert it
        // matches the AGENT_ADDRESS we grant the role to.
        uint256 agentPk = vm.envUint("AGENT_PRIVATE_KEY");
        require(vm.addr(agentPk) == agent, "AGENT_PRIVATE_KEY does not match AGENT_ADDRESS");

        // This manual script broadcasts as a single key (the deployer). Registering the
        // claim-signer key calls ClaimIssuer.addKey(), which is `onlyManager`. So the issuer's
        // management key must be the deployer here — otherwise addKey would revert with an
        // opaque permissions error. Fail early and loudly instead.
        require(
            claimIssuerManagement == deployer,
            "CLAIM_ISSUER_MANAGEMENT_ADDRESS must equal the deployer for the manual deploy"
        );
        require(
            claimIssuerSigner != claimIssuerManagement, "signer must differ from management key"
        );

        // Indexer backfill floor: the chain height the deployment starts from. `forge script`
        // simulates against the fork tip, so `block.number` here is the height *before* our
        // txs land (0 on a fresh Anvil, the live tip on Amoy). Starting the backfill at this
        // floor is the safe direction — the indexer is idempotent and reorg-safe, so scanning
        // a few blocks early never misses a deploy event, whereas starting late would.
        uint256 deployBlock = block.number;

        Deployed memory d = _deployAndWire(
            deployerPk,
            deployer,
            agent,
            claimIssuerManagement,
            claimIssuerSigner,
            DEFAULT_MAX_INVESTORS
        );
        d.deployBlock = deployBlock;

        // ── Unpause as the agent ──────────────────────────────────────────────────────────
        // A freshly initialized Token starts PAUSED (_tokenPaused = true, Token.sol:128).
        // unpause() is onlyAgent, so it is signed by the agent wallet (a token operation).
        vm.startBroadcast(agentPk);
        d.token.unpause();
        vm.stopBroadcast();

        _assertWiring(d, agent, claimIssuerSigner, DEFAULT_MAX_INVESTORS);
        _writeAddressBook(d);
        _logAddresses(d);
    }

    /**
     * @dev Deploys every contract and performs all deployer-owned wiring in one broadcast.
     *      Follows NOTES §6 step order exactly.
     */
    function _deployAndWire(
        uint256 deployerPk,
        address deployer,
        address agent,
        address claimIssuerManagement,
        address claimIssuerSigner,
        uint256 maxInvestors
    ) internal returns (Deployed memory d) {
        vm.startBroadcast(deployerPk);

        // 1. Leaf registries — each is OZ-upgradeable, made usable by a single init().
        d.claimTopicsRegistry = new ClaimTopicsRegistry();
        d.claimTopicsRegistry.init();

        d.trustedIssuersRegistry = new TrustedIssuersRegistry();
        d.trustedIssuersRegistry.init();

        d.identityRegistryStorage = new IdentityRegistryStorage();
        d.identityRegistryStorage.init();

        // 2. IdentityRegistry over the three registries.
        //    ⚠️ arg order is (trustedIssuers, claimTopics, storage) — trusted issuers FIRST
        //    (IdentityRegistry.sol:87 / NOTES §7). Transposing it fails silently later.
        d.identityRegistry = new IdentityRegistry();
        d.identityRegistry
            .init(
                address(d.trustedIssuersRegistry),
                address(d.claimTopicsRegistry),
                address(d.identityRegistryStorage)
            );

        // 3. Bind the IR into the storage. This adds the IR as an agent of the storage so it
        //    may write identities; without it, registerIdentity reverts "caller does not have
        //    the Agent role". Sent by the IRS owner (the deployer) — required (NOTES §1.3).
        d.identityRegistryStorage.bindIdentityRegistry(address(d.identityRegistry));

        // 4. Compliance, then Token. Token.init auto-calls compliance.bindToken(token) via
        //    setCompliance (Token.sol:520) — do NOT bindToken separately. Token onchainID is
        //    left zero: the ONCHAINID infra is deployed after the token in this ordering, and
        //    the token identity is optional and owner-settable later (Token.sol:106 comment).
        d.compliance = new ModularCompliance();
        d.compliance.init();

        d.token = new Token();
        d.token
            .init(
                address(d.identityRegistry),
                address(d.compliance),
                TOKEN_NAME,
                TOKEN_SYMBOL,
                TOKEN_DECIMALS,
                address(0)
            );

        // 4b. Deploy and bind our custom holder-cap module, then configure its cap.
        //     addModule is onlyOwner (deployer) and calls module.bindCompliance(compliance).
        //     The module is NOT plug-and-play (isPlugAndPlay() == false), so addModule DOES run
        //     the canComplianceBind gate; it passes here only because the token is already bound
        //     (Token.init -> setCompliance -> bindToken) and its totalSupply() == 0 (no mint yet).
        //     We bind it HERE — before any mint — because the module mirrors holder balances from
        //     an empty state, so it must see the token's entire holder history. Flipping the module
        //     to plug-and-play, or reordering addModule before the token/compliance bind, would let
        //     it attach to a token that already has holders and silently under-count (NOTES §9.1).
        //
        //     The cap is set through compliance.callModuleFunction (onlyOwner): that low-level
        //     call reaches the module with msg.sender == compliance, satisfying the module's
        //     onlyComplianceCall guard on setMaxInvestors. This is the canonical T-REX module-
        //     config path (NOTES §1.5) and keeps "only the compliance owner may set the cap" true.
        d.maxInvestorsModule = new MaxInvestorsModule();
        d.compliance.addModule(address(d.maxInvestorsModule));
        d.compliance
            .callModuleFunction(
                abi.encodeWithSelector(MaxInvestorsModule.setMaxInvestors.selector, maxInvestors),
                address(d.maxInvestorsModule)
            );

        // 5. Grant the agent role on BOTH the Token and the IdentityRegistry (both onlyOwner).
        d.token.addAgent(agent);
        d.identityRegistry.addAgent(agent);

        // 6. ONCHAINID: deploy the Identity logic as a shared library (_isLibrary = true),
        //    wrap it in an ImplementationAuthority, then an IdFactory that mints investor
        //    identity proxies against that authority. Deploy the ClaimIssuer with the
        //    management key as its initial (purpose-1) key.
        d.identityLibrary = new Identity(deployer, true);
        d.implementationAuthority = new ImplementationAuthority(address(d.identityLibrary));
        d.idFactory = new IdFactory(address(d.implementationAuthority));
        d.claimIssuer = new ClaimIssuer(claimIssuerManagement);

        // 7. Register the DISTINCT signing EOA as a purpose-3 CLAIM key on the ClaimIssuer.
        //
        //    Least-privilege rationale (deliberate — do NOT skip as "optional"):
        //    NOTES §5a documents that a purpose-1 MANAGEMENT key satisfies keyHasPurpose(_, 3)
        //    implicitly, so if we signed claims with the management key we would not need to
        //    register anything here. We are choosing NOT to rely on that. The signing key must
        //    be able to sign claims and nothing else: a leaked signer can then neither re-key
        //    nor administer the issuer contract, because it holds no management purpose.
        //    addKey is onlyManager, hence the "management == deployer" requirement in run().
        d.claimIssuer.addKey(keccak256(abi.encode(claimIssuerSigner)), PURPOSE_CLAIM, KEYTYPE_ECDSA);

        // 8. Trust this issuer for both required topics.
        uint256[] memory topics = new uint256[](2);
        topics[0] = TOPIC_KYC;
        topics[1] = TOPIC_AML;
        d.trustedIssuersRegistry.addTrustedIssuer(IClaimIssuer(address(d.claimIssuer)), topics);

        // 9. Require KYC and AML for verification.
        d.claimTopicsRegistry.addClaimTopic(TOPIC_KYC);
        d.claimTopicsRegistry.addClaimTopic(TOPIC_AML);

        vm.stopBroadcast();
    }

    /**
     * @dev Asserts the full wiring. Any failure reverts the whole run — a partially wired
     *      deployment must never be reported as success. Grouped by concern for readability.
     */
    function _assertWiring(
        Deployed memory d,
        address agent,
        address claimIssuerSigner,
        uint256 expectedMaxInvestors
    ) internal view {
        // IdentityRegistry points at the three registries — and in the RIGHT slots.
        require(
            address(d.identityRegistry.issuersRegistry()) == address(d.trustedIssuersRegistry),
            "wire: IR.issuersRegistry mismatch (arg order?)"
        );
        require(
            address(d.identityRegistry.topicsRegistry()) == address(d.claimTopicsRegistry),
            "wire: IR.topicsRegistry mismatch (arg order?)"
        );
        require(
            address(d.identityRegistry.identityStorage()) == address(d.identityRegistryStorage),
            "wire: IR.identityStorage mismatch (arg order?)"
        );

        // Storage <-> IdentityRegistry bind: the IR must be a linked registry (and an agent)
        // of the storage, else registerIdentity reverts.
        address[] memory linked = d.identityRegistryStorage.linkedIdentityRegistries();
        require(
            linked.length == 1 && linked[0] == address(d.identityRegistry), "wire: IRS bind missing"
        );
        require(
            d.identityRegistryStorage.isAgent(address(d.identityRegistry)),
            "wire: IR not an agent of IRS"
        );

        // Token <-> Compliance two-way binding (set up by Token.init -> setCompliance).
        require(
            address(d.token.compliance()) == address(d.compliance),
            "wire: token.compliance mismatch"
        );
        require(
            d.compliance.getTokenBound() == address(d.token), "wire: compliance not bound to token"
        );

        // MaxInvestorsModule is bound to the compliance and its cap reads back as configured.
        require(
            d.compliance.isModuleBound(address(d.maxInvestorsModule)),
            "wire: MaxInvestorsModule not bound to compliance"
        );
        require(
            d.maxInvestorsModule.isComplianceBound(address(d.compliance)),
            "wire: compliance not bound on MaxInvestorsModule"
        );
        require(
            d.maxInvestorsModule.maxInvestors(address(d.compliance)) == expectedMaxInvestors,
            "wire: MaxInvestorsModule cap mismatch"
        );
        require(
            address(d.token.identityRegistry()) == address(d.identityRegistry),
            "wire: token.identityRegistry mismatch"
        );

        // Agent roles on BOTH Token and IdentityRegistry.
        require(d.token.isAgent(agent), "wire: agent missing on Token");
        require(d.identityRegistry.isAgent(agent), "wire: agent missing on IdentityRegistry");

        // Claim topics present (KYC + AML).
        uint256[] memory storedTopics = d.claimTopicsRegistry.getClaimTopics();
        require(storedTopics.length == 2, "wire: expected exactly 2 claim topics");
        require(
            _hasTopic(storedTopics, TOPIC_KYC) && _hasTopic(storedTopics, TOPIC_AML),
            "wire: KYC/AML topic missing"
        );

        // Trusted issuer registered for BOTH topics.
        require(
            d.trustedIssuersRegistry.isTrustedIssuer(address(d.claimIssuer)),
            "wire: claim issuer not trusted"
        );
        require(
            d.trustedIssuersRegistry.hasClaimTopic(address(d.claimIssuer), TOPIC_KYC),
            "wire: claim issuer not trusted for KYC"
        );
        require(
            d.trustedIssuersRegistry.hasClaimTopic(address(d.claimIssuer), TOPIC_AML),
            "wire: claim issuer not trusted for AML"
        );

        // The signer EOA holds a purpose-3 CLAIM key on the issuer.
        require(
            d.claimIssuer.keyHasPurpose(keccak256(abi.encode(claimIssuerSigner)), PURPOSE_CLAIM),
            "wire: signer is not a purpose-3 claim key"
        );

        // Token is live.
        require(!d.token.paused(), "wire: token still paused");

        // Metadata is what we asked for.
        require(
            keccak256(bytes(d.token.name())) == keccak256(bytes(TOKEN_NAME)),
            "wire: token name mismatch"
        );
        require(
            keccak256(bytes(d.token.symbol())) == keccak256(bytes(TOKEN_SYMBOL)),
            "wire: token symbol mismatch"
        );
        require(d.token.decimals() == TOKEN_DECIMALS, "wire: token decimals mismatch");
    }

    function _hasTopic(uint256[] memory topics, uint256 topic) private pure returns (bool) {
        for (uint256 i = 0; i < topics.length; i++) {
            if (topics[i] == topic) return true;
        }
        return false;
    }

    /**
     * @dev Serializes the deployed addresses to packages/shared/addresses.local.json in the
     *      shape the address-book loader validates: { chainId, deployBlock, contracts }.
     */
    function _writeAddressBook(Deployed memory d) internal {
        string memory c = "contracts";
        vm.serializeAddress(c, "ClaimTopicsRegistry", address(d.claimTopicsRegistry));
        vm.serializeAddress(c, "TrustedIssuersRegistry", address(d.trustedIssuersRegistry));
        vm.serializeAddress(c, "IdentityRegistryStorage", address(d.identityRegistryStorage));
        vm.serializeAddress(c, "IdentityRegistry", address(d.identityRegistry));
        vm.serializeAddress(c, "ModularCompliance", address(d.compliance));
        vm.serializeAddress(c, "MaxInvestorsModule", address(d.maxInvestorsModule));
        vm.serializeAddress(c, "Token", address(d.token));
        vm.serializeAddress(c, "IdentityLibrary", address(d.identityLibrary));
        vm.serializeAddress(c, "ImplementationAuthority", address(d.implementationAuthority));
        vm.serializeAddress(c, "IdFactory", address(d.idFactory));
        string memory contractsJson = vm.serializeAddress(c, "ClaimIssuer", address(d.claimIssuer));

        string memory root = "addressBook";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeUint(root, "deployBlock", d.deployBlock);
        string memory json = vm.serializeString(root, "contracts", contractsJson);

        vm.writeJson(json, ADDRESS_BOOK_PATH);
        console2.log("Address book written to", ADDRESS_BOOK_PATH);
    }

    function _logAddresses(Deployed memory d) internal pure {
        console2.log("=== Tessera deployment (chainId 31337 local) ===");
        console2.log("deployBlock             ", d.deployBlock);
        console2.log("ClaimTopicsRegistry     ", address(d.claimTopicsRegistry));
        console2.log("TrustedIssuersRegistry  ", address(d.trustedIssuersRegistry));
        console2.log("IdentityRegistryStorage ", address(d.identityRegistryStorage));
        console2.log("IdentityRegistry        ", address(d.identityRegistry));
        console2.log("ModularCompliance       ", address(d.compliance));
        console2.log("MaxInvestorsModule      ", address(d.maxInvestorsModule));
        console2.log("Token (BER-A)           ", address(d.token));
        console2.log("IdentityLibrary         ", address(d.identityLibrary));
        console2.log("ImplementationAuthority ", address(d.implementationAuthority));
        console2.log("IdFactory               ", address(d.idFactory));
        console2.log("ClaimIssuer             ", address(d.claimIssuer));
    }
}
