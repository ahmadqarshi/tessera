// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";

import { IdentityRegistry } from "@erc-3643/contracts/registry/implementation/IdentityRegistry.sol";
import { Token } from "@erc-3643/contracts/token/Token.sol";
import { Identity } from "@onchain-id/solidity/contracts/Identity.sol";
import { IdFactory } from "@onchain-id/solidity/contracts/factory/IdFactory.sol";
import { ClaimIssuer } from "@onchain-id/solidity/contracts/ClaimIssuer.sol";

import { Deploy } from "../../script/Deploy.s.sol";
import { Seed } from "../../script/Seed.s.sol";

/**
 * @title TREXFixture — a live, fully wired T-REX suite for unit tests.
 *
 * @notice `setUp()` deploys and seeds the whole ERC-3643 stack in-memory by REUSING the exact
 *         helpers that the production scripts run:
 *           • {Deploy._deployAndWire} — the entire deploy + wiring path, verbatim.
 *           • {Seed._onboardVerifiedInvestor} / {Seed._registerInvestor} — identity creation,
 *             registration, and the consensus-critical ERC-735 claim-signing recipe, verbatim.
 *         Because the fixture calls the scripts' own code rather than re-implementing it, the
 *         test suite and the deploy path cannot drift: a change to the wiring order or the claim
 *         digest breaks both at once. That is the whole point of inheriting {Deploy} and {Seed}
 *         here instead of copying their bodies.
 *
 *         `vm.startBroadcast(pk)` inside those helpers sets `msg.sender`/owner correctly under
 *         `forge test` (verified: the deployer ends up owning the suite), so the reused code
 *         behaves identically whether driven by `forge script` or by this fixture.
 *
 * ── Investor cast (extends the seed's) ──────────────────────────────────────────────────────
 *   A  verified, DE — identity + KYC + AML claims. Holds {AMOUNT_A}.        (from Seed)
 *   B  verified, LU — identity + KYC + AML claims. Holds {AMOUNT_B}.        (from Seed)
 *   C  NO identity at all — never registered.                              (from Seed)
 *   D  registered (identity created + registerIdentity'd) but NO claims.   (NEW here)
 *
 *   C and D are two *distinct* negative paths: C fails `isVerified` because it has no identity
 *   in the registry; D fails because its identity carries none of the required claim topics.
 *   The seed only creates C, so the fixture adds D to cover the second failure mode.
 *
 * ── Keys (self-contained; the standard Anvil mnemonic, matching .env.example indices) ────────
 *   #0 deployer & ClaimIssuer management · #1 claim signer (purpose 3) · #2 agent
 *   #3 investor A · #4 investor B · #5 investor C · #6 investor D
 */
abstract contract TREXFixture is Test, Deploy, Seed {
    // The standard Foundry/Anvil test mnemonic (see .env.example ANVIL_MNEMONIC). Keeping the
    // keys here rather than reading env makes the fixture deterministic and clone-and-run.
    string internal constant MNEMONIC = "test test test test test test test test test test test junk";

    // Investor D's country. Irrelevant to the assertion D exercises — D fails verification on its
    // MISSING claims, not its jurisdiction — so any valid ISO 3166-1 code works. 40 = Austria.
    uint16 internal constant COUNTRY_D = 40;

    // Live suite handles, resolved once in setUp.
    Token internal token;
    IdentityRegistry internal identityRegistry;
    ClaimIssuer internal claimIssuer;
    IdFactory internal idFactory;

    // Role wallets.
    address internal deployer;
    address internal agent;
    address internal signer;

    // Investor wallets and their ONCHAINID addresses (identity == address(0) where none exists).
    address internal investorA;
    address internal identityA;
    address internal investorB;
    address internal identityB;
    address internal investorC;
    address internal investorD;
    address internal identityD;

    /// @dev Inert override: two `run()` entrypoints are inherited (Deploy's and Seed's) and must
    ///      be disambiguated. The fixture is not a script — `setUp()` drives everything — so this
    ///      is intentionally empty and never called.
    function run() external override(Deploy, Seed) { }

    function setUp() public virtual {
        // ── Keys (deployer #0 also owns the ClaimIssuer management key) ─────────────────────
        uint256 deployerPk = vm.deriveKey(MNEMONIC, 0);
        uint256 signerPk = vm.deriveKey(MNEMONIC, 1);
        uint256 agentPk = vm.deriveKey(MNEMONIC, 2);
        deployer = vm.addr(deployerPk);
        signer = vm.addr(signerPk);
        agent = vm.addr(agentPk);

        // ── Deploy + wire the full suite via the production path ─────────────────────────────
        // claimIssuerManagement == deployer, as {Deploy} requires for the single-key manual path.
        Deployed memory d = _deployAndWire(deployerPk, deployer, agent, deployer, signer);
        token = d.token;
        identityRegistry = d.identityRegistry;
        claimIssuer = d.claimIssuer;
        idFactory = d.idFactory;

        // ── Unpause as the agent ────────────────────────────────────────────────────────────
        // The Token initializes PAUSED (Token.sol:128); {Deploy.run} unpauses as the agent, and
        // {Deploy._deployAndWire} does not, so the fixture does it here — a token (agent) op.
        vm.prank(agent);
        token.unpause();

        // Metadata sanity — asserted once here (Deploy.s.sol asserts it too, but only in run()).
        assertEq(token.name(), TOKEN_NAME, "token name");
        assertEq(token.symbol(), TOKEN_SYMBOL, "token symbol");
        assertEq(token.decimals(), TOKEN_DECIMALS, "token decimals");

        // ── Seed the investors by reusing Seed's onboarding helpers ─────────────────────────
        Ctx memory c = Ctx({
            token: d.token,
            identityRegistry: d.identityRegistry,
            idFactory: d.idFactory,
            claimIssuer: d.claimIssuer,
            deployerPk: deployerPk,
            agentPk: agentPk,
            signerPk: signerPk
        });

        // A and B: fully verified (identity + KYC + AML), same salts/countries as the seed.
        (investorA, identityA) =
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 3), "halvorsen-capital-ag", COUNTRY_DE);
        (investorB, identityB) =
            _onboardVerifiedInvestor(c, vm.deriveKey(MNEMONIC, 4), "orbis-family-office", COUNTRY_LU);

        // C: a bare wallet, never given an identity — the seed's negative fixture.
        investorC = vm.addr(vm.deriveKey(MNEMONIC, 5));

        // D: registered but unverified — identity created + registerIdentity'd, but NO claims.
        // Reuses only the register half of onboarding; {_addKycAmlClaims} is deliberately skipped.
        (investorD, identityD) =
            _registerInvestor(c, vm.deriveKey(MNEMONIC, 6), "vestry-unclaimed-fixture", COUNTRY_D);

        // ── Primary distribution to the two verified holders (agent-signed mint) ────────────
        vm.startPrank(agent);
        token.mint(investorA, AMOUNT_A);
        token.mint(investorB, AMOUNT_B);
        vm.stopPrank();
    }
}
