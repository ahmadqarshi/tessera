// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { Token } from "@erc-3643/contracts/token/Token.sol";
import { IIdentityRegistry } from "@erc-3643/contracts/registry/interface/IIdentityRegistry.sol";

/**
 * @title TokenHandler — the bounded action surface the invariant fuzzer drives.
 *
 * @notice Invariant fuzzing works by calling random functions on a target contract in a random
 *         order with random arguments, then checking the `invariant_*` assertions after every call.
 *         Pointing the fuzzer straight at {Token} would waste almost every call on a revert — an
 *         unbounded amount overflows, a random `msg.sender` is not an agent, a random receiver is
 *         unverified. This handler is the standard remedy: it exposes ONE method per meaningful
 *         action, each of which (a) picks its parties from a small, fixed actor set, (b) bounds its
 *         amount into the legal range, and (c) sends the call from the correct signer. The result is
 *         that the overwhelming majority of fuzzer calls do real work and move real state, so the
 *         256×64 = ~16k calls a run actually explore the state machine instead of bouncing off guards.
 *
 * ── The actor set (fixed; supplied by the invariant contract) ────────────────────────────────
 *   Investors A and B are the two seeded, verified holders; E and F are verified but start empty;
 *   C and D are the two unverified negatives (C has no identity, D is registered with no claims).
 *   Every token-crediting path (`mint`, `transfer`, `forcedTransfer`) gates on `isVerified(_to)`,
 *   so C and D can never be made to hold — attempts to credit them revert and are swallowed. That
 *   is deliberate: keeping the unverified pair in the set continuously exercises the eligibility
 *   gate (and keeps invariant 5 honest) without ever creating an illegal holder.
 *
 * ── Who signs what ───────────────────────────────────────────────────────────────────────────
 *   `transfer` is holder-initiated, so it is pranked from the sending investor. Every other action
 *   here is an agent operation (mint/burn/forcedTransfer/freeze/pause), pranked from the agent
 *   wallet. This mirrors the production split in CLAUDE.md: investors client-sign their own moves;
 *   privileged operations are agent-signed.
 *
 * ── Ghost variables (expected state the stateless invariants cannot recompute) ────────────────
 *   • {ghostForcedTransfers} — how many forced transfers have executed. The holder cap can only be
 *     breached via `forcedTransfer` (it skips `moduleCheck`, NOTES.md §7.1), so the cap invariant is
 *     only asserted while this counter is zero. See {TokenInvariants} invariant 2.
 *   • {ghostNetSupply} — mint/burn-driven expected `totalSupply`, seeded with the fixture's
 *     primary distribution so it stays exact from block zero. Cross-checks solvency against a source
 *     independent of summing balances.
 *
 * ── Auto-unfreeze is asserted HERE, at the exact path (task invariant 6) ──────────────────────
 *   `burn` and `forcedTransfer` both silently unfreeze the shortfall when the moved amount exceeds
 *   the free balance (Token.sol). That arithmetic is a per-call postcondition, not a global state
 *   predicate, so it is asserted inline in those two actions the instant the move succeeds — a far
 *   tighter check than any stateless invariant could express. The file-level invariant 6 then only
 *   has to re-affirm `frozen <= balance` holds afterwards (which it does after every action).
 */
contract TokenHandler is Test {
    Token public immutable token;
    address public immutable agent;

    /// @dev The complete universe of parties. Only these addresses ever hold or move the token, so
    ///      the invariant contract can compute ground truth by iterating exactly this set.
    address[] internal actors;

    /// @dev `actors` partitioned by verification status at construction (fixed for the run — this
    ///      handler exposes no claim-revocation action, so no actor ever crosses the boundary). Used
    ///      only to BIAS a `transfer` recipient toward the verified set; both partitions stay live in
    ///      the pick so the unverified path is still attempted (see {_recipient}).
    address[] internal verifiedActors;
    address[] internal unverifiedActors;

    /// @dev Upper bound on a single mint. Comfortably below the point where a depth-64 run of mints
    ///      could overflow `totalSupply` (64 × 1e6 × 1e18 ≪ 2²⁵⁶), so mints never revert on overflow.
    uint256 internal constant MAX_MINT = 1_000_000e18;

    // ── Ghost state (see contract doc) ───────────────────────────────────────────────────────
    uint256 public ghostForcedTransfers;
    uint256 public ghostNetSupply;

    // ── Call-distribution tally (diagnostic, asserts nothing) ────────────────────────────────
    /// @dev Per-action invocation counter, keyed by the action name (a ≤32-byte string literal,
    ///      implicitly a bytes32). Bumped by {countCall} on ENTRY — so it counts every time the
    ///      fuzzer selected the action, including calls that early-return (empty balance) or whose
    ///      inner op reverts inside try/catch. This measures how the fuzzer's ~depth calls per run
    ///      are apportioned across the 9 selectors, surfacing any action the scheduler starves.
    mapping(bytes32 => uint256) public calls;
    uint256 public totalCalls;

    /// @dev The 9 action keys, in the order {callSummary} reports them.
    bytes32[9] internal ACTIONS = [
        bytes32("transfer"),
        "forcedTransfer",
        "mint",
        "burn",
        "freezePartialTokens",
        "unfreezePartialTokens",
        "setAddressFrozen",
        "pause",
        "unpause"
    ];

    /// @dev Tally one invocation of `key` before running the action body.
    modifier countCall(bytes32 key) {
        calls[key]++;
        totalCalls++;
        _;
    }

    /// @dev Per-action EFFECTIVE counter, bumped only when the underlying token op actually MUTATED
    ///      state: the call returned successfully AND did non-trivial work (moved a non-zero amount,
    ///      or flipped a flag). Always <= {calls}; the gap is where the fuzzer spent a selection that
    ///      touched no state — an empty-balance early return, a legitimately swallowed revert (cap,
    ///      frozen, paused, unverified receiver, pause-while-paused), or a no-op write (a zero-amount
    ///      freeze/unfreeze, a redundant freeze-flag toggle). Reported next to {calls} in {callSummary}.
    mapping(bytes32 => uint256) public effectiveCalls;
    uint256 public totalEffective;

    /// @dev Record that `key` did real state-mutating work this call.
    function _bumpEffective(bytes32 key) private {
        effectiveCalls[key]++;
        totalEffective++;
    }

    constructor(Token _token, address _agent, address[] memory _actors) {
        token = _token;
        agent = _agent;
        actors = _actors;
        // Seed the net-supply ghost with whatever the fixture already minted (A + B). From here on
        // every mint/burn keeps it exact, so `totalSupply == ghostNetSupply` holds from the start.
        ghostNetSupply = _token.totalSupply();

        // Partition actors by verification once. isVerified is settled for every actor by the time
        // the handler is constructed (identities + claims are wired in the fixture/invariant setUp).
        IIdentityRegistry ir = _token.identityRegistry();
        for (uint256 i = 0; i < _actors.length; i++) {
            if (ir.isVerified(_actors[i])) {
                verifiedActors.push(_actors[i]);
            } else {
                unverifiedActors.push(_actors[i]);
            }
        }
    }

    // ── Holder-initiated move ────────────────────────────────────────────────────────────────

    /**
     * @dev A normal ERC-20 `transfer`, pranked from the sender. Still wrapped in try/catch — it may
     *      revert for a legitimate reason the fuzzer should be free to hit (the cap rejects the
     *      (cap+1)-th holder, an unverified receiver, a frozen wallet) — but two guaranteed-doomed
     *      classes are pruned up front so selections aren't spent on reverts that teach nothing new:
     *      - `token.paused()` ⇒ every ordinary `transfer` reverts `whenNotPaused`; that path is
     *        already pinned by AgentControls.t.sol, so re-hitting it here only dilutes coverage.
     *      - an empty-balance sender (a zero-value move also reverts in ModularCompliance on
     *        `_value > 0`). `from` is therefore biased toward actors that currently hold a non-zero
     *        balance (uniform fallback when nobody holds); an empty `from` early-returns and models
     *        nothing — transfer-from-empty is already covered in the unit suite.
     *      The receiver is biased ~75% toward the verified set so a transfer can actually clear the
     *      eligibility gate, while ~25% still target the unverified pair — deliberately, so
     *      TokenInvariants invariant 5 (no unverified holder) keeps attempting the path it guards and
     *      never goes vacuous. Amount is bound to [1, balance].
     */
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed)
        external
        countCall("transfer")
    {
        if (token.paused()) {
            return;
        }
        address from = _holder(fromSeed);
        address to = _recipient(toSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) {
            return; // fallback picked an empty actor (nobody holds) — nothing to move
        }
        uint256 amount = bound(amountSeed, 1, balance);

        vm.prank(from);
        try token.transfer(to, amount) {
            _bumpEffective("transfer");
        } catch { }
    }

    // ── Agent operations ─────────────────────────────────────────────────────────────────────

    /**
     * @dev Agent `forcedTransfer`. Its real predicate is: caller is an agent, `amount <= balance`,
     *      and `isVerified(_to)` — and it is INDEPENDENT of either party's freeze flag (NOTES.md
     *      §7.1). So frozen actors are intentionally NOT excluded: an agent must be able to seize
     *      from, or reassign onto, a quarantined wallet. On success we bump {ghostForcedTransfers}
     *      (the cap invariant keys off it) and assert the auto-unfreeze arithmetic on the sender.
     */
    function forcedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed)
        external
        countCall("forcedTransfer")
    {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, balance);

        uint256 frozenBefore = token.getFrozenTokens(from);
        uint256 free = balance - frozenBefore; // frozen <= balance (invariant 3) ⇒ no underflow

        vm.prank(agent);
        try token.forcedTransfer(from, to, amount) {
            ghostForcedTransfers++;
            _bumpEffective("forcedTransfer"); // amount is bound to [1, balance] ⇒ always a real move
            // Auto-unfreeze: forcing past the free balance drops the lien by exactly the shortfall,
            // never more. Holds for a self-transfer too — the unfreeze is computed off `from` alone.
            uint256 expectedFrozen = amount > free ? frozenBefore - (amount - free) : frozenBefore;
            assertEq(
                token.getFrozenTokens(from),
                expectedFrozen,
                "forcedTransfer unfroze exactly the shortfall (amount - free), no more"
            );
            assertLe(
                token.getFrozenTokens(from),
                token.balanceOf(from),
                "frozen <= balance immediately after a forced transfer"
            );
        } catch { }
    }

    /**
     * @dev Agent `mint`. Bound to [1, {MAX_MINT}]; a zero-value mint reverts in ModularCompliance.
     *      May revert when it would create the (cap+1)-th holder — `mint` DOES run `moduleCheck`
     *      (gate 3) — or when `_to` is unverified (C/D); both are swallowed. On success the mint is
     *      folded into {ghostNetSupply}.
     */
    function mint(uint256 toSeed, uint256 amountSeed) external countCall("mint") {
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 1, MAX_MINT);

        vm.prank(agent);
        try token.mint(to, amount) {
            ghostNetSupply += amount;
            _bumpEffective("mint"); // amount bound to [1, MAX_MINT] ⇒ a successful mint always mints
        } catch { }
    }

    /**
     * @dev Agent `burn`, bound to [1, balance]. Auto-unfreezes any shortfall, so it never reverts
     *      for a funded holder; the try/catch is belt-and-braces. Asserts the same shortfall
     *      arithmetic as {forcedTransfer} and folds the burn into {ghostNetSupply}.
     */
    function burn(uint256 fromSeed, uint256 amountSeed) external countCall("burn") {
        address from = _actor(fromSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, balance);

        uint256 frozenBefore = token.getFrozenTokens(from);
        uint256 free = balance - frozenBefore;

        vm.prank(agent);
        try token.burn(from, amount) {
            ghostNetSupply -= amount;
            _bumpEffective("burn"); // amount bound to [1, balance] ⇒ a successful burn always burns
            uint256 expectedFrozen = amount > free ? frozenBefore - (amount - free) : frozenBefore;
            assertEq(
                token.getFrozenTokens(from),
                expectedFrozen,
                "burn unfroze exactly the shortfall (amount - free), no more"
            );
            assertLe(
                token.getFrozenTokens(from),
                token.balanceOf(from),
                "frozen <= balance immediately after a burn"
            );
        } catch { }
    }

    /**
     * @dev Agent `freezePartialTokens`, bound to the legal range [0, balance - frozen] so the
     *      token's `balance >= frozen + amount` guard always holds and the call cannot revert —
     *      under `fail_on_revert = true`, this doubles as an assertion that a legal freeze succeeds.
     */
    function freezePartialTokens(uint256 whoSeed, uint256 amountSeed)
        external
        countCall("freezePartialTokens")
    {
        address who = _actor(whoSeed);
        uint256 freezable = token.balanceOf(who) - token.getFrozenTokens(who); // no underflow (inv 3)
        uint256 amount = bound(amountSeed, 0, freezable);

        vm.prank(agent);
        token.freezePartialTokens(who, amount);
        if (amount > 0) {
            _bumpEffective("freezePartialTokens"); // amount==0 is a legal no-op write, not a mutation
        }
    }

    /**
     * @dev Agent `unfreezePartialTokens`, bound to [0, frozen] so `frozen >= amount` always holds
     *      and the call is legal by construction.
     */
    function unfreezePartialTokens(uint256 whoSeed, uint256 amountSeed)
        external
        countCall("unfreezePartialTokens")
    {
        address who = _actor(whoSeed);
        uint256 amount = bound(amountSeed, 0, token.getFrozenTokens(who));

        vm.prank(agent);
        token.unfreezePartialTokens(who, amount);
        if (amount > 0) {
            _bumpEffective("unfreezePartialTokens"); // amount==0 is a legal no-op write
        }
    }

    /// @dev Agent whole-wallet freeze toggle. Never reverts; it changes only whether the holder
    ///      paths (`transfer`) may touch this wallet — forced transfers ignore the flag entirely.
    function setAddressFrozen(uint256 whoSeed, bool freeze)
        external
        countCall("setAddressFrozen")
    {
        address who = _actor(whoSeed);
        bool changed = token.isFrozen(who) != freeze; // a redundant re-toggle mutates nothing
        vm.prank(agent);
        token.setAddressFrozen(who, freeze);
        if (changed) {
            _bumpEffective("setAddressFrozen");
        }
    }

    /// @dev Global pause. try/catch because `pause()` carries `whenNotPaused` (calling it while
    ///      already paused reverts); we want the fuzzer to attempt it in either state.
    function pause() external countCall("pause") {
        vm.prank(agent);
        try token.pause() {
            _bumpEffective("pause"); // succeeds only whenNotPaused ⇒ success == the flag flipped
        } catch { }
    }

    /// @dev Global unpause; `whenPaused`, so try/catch for the already-unpaused case.
    function unpause() external countCall("unpause") {
        vm.prank(agent);
        try token.unpause() {
            _bumpEffective("unpause"); // succeeds only whenPaused ⇒ success == the flag flipped
        } catch { }
    }

    // ── Views ────────────────────────────────────────────────────────────────────────────────

    /// @notice The fixed actor universe, exposed so the invariant contract iterates the same set.
    function getActors() external view returns (address[] memory) {
        return actors;
    }

    /// @notice Print the per-action call distribution. Called from {TokenInvariants-invariant_callSummary}
    ///         so Foundry surfaces it once in the run report. Asserts nothing — it is a diagnostic on
    ///         how the fuzzer apportioned this sequence's calls across the 9 selectors, and how many of
    ///         those selections actually mutated state (`effective`). A low effective/selected ratio
    ///         flags an action the fuzzer keeps picking but that mostly no-ops (empty balance, swallowed
    ///         revert, no-op write) — a subtler starvation than a low selection share alone would show.
    function callSummary() external view {
        console2.log("== TokenHandler call distribution (this sequence) ==");
        console2.log(
            string.concat(_pad("action"), _padNum("selected"), _padNum("effective"), "   eff/sel")
        );
        for (uint256 i = 0; i < ACTIONS.length; i++) {
            bytes32 a = ACTIONS[i];
            uint256 sel = calls[a];
            uint256 eff = effectiveCalls[a];
            uint256 ratioBps = sel == 0 ? 0 : (eff * 10_000) / sel;
            console2.log(
                string.concat(
                    _pad(a),
                    _padNum(vm.toString(sel)),
                    _padNum(vm.toString(eff)),
                    "   ",
                    _bpsToPct(ratioBps),
                    "%"
                )
            );
        }
        uint256 totalRatioBps = totalCalls == 0 ? 0 : (totalEffective * 10_000) / totalCalls;
        console2.log(
            string.concat(
                _pad("TOTAL"),
                _padNum(vm.toString(totalCalls)),
                _padNum(vm.toString(totalEffective)),
                "   ",
                _bpsToPct(totalRatioBps),
                "%"
            )
        );
    }

    /// @dev Right-pad an action label to 22 chars so the console column lines up.
    function _pad(bytes32 label) private pure returns (string memory) {
        string memory s = _toString(label);
        bytes memory b = bytes(s);
        if (b.length >= 22) {
            return s;
        }
        bytes memory out = new bytes(22);
        for (uint256 i = 0; i < 22; i++) {
            out[i] = i < b.length ? b[i] : bytes1(" ");
        }
        return string(out);
    }

    /// @dev Right-align a numeric (or header) string in an 11-char column so the counts line up.
    function _padNum(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 width = 11;
        if (b.length >= width) {
            return s;
        }
        bytes memory out = new bytes(width);
        uint256 pad = width - b.length;
        for (uint256 i = 0; i < width; i++) {
            out[i] = i < pad ? bytes1(" ") : b[i - pad];
        }
        return string(out);
    }

    /// @dev Render basis points (0–10000) as a "12.34" percentage string.
    function _bpsToPct(uint256 bps) private pure returns (string memory) {
        uint256 whole = bps / 100;
        uint256 frac = bps % 100;
        return string.concat(vm.toString(whole), ".", frac < 10 ? "0" : "", vm.toString(frac));
    }

    /// @dev Decode a right-NUL-padded bytes32 label back to its string.
    function _toString(bytes32 label) private pure returns (string memory) {
        uint256 len;
        while (len < 32 && label[len] != 0) {
            len++;
        }
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = label[i];
        }
        return string(out);
    }

    // ── Internal ─────────────────────────────────────────────────────────────────────────────

    /// @dev Map a fuzzer seed onto one of the fixed actors. `bound` (never `assume`) so no call is
    ///      discarded — every fuzzer step lands on a real party.
    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev A `transfer` recipient, biased ~75% verified / ~25% unverified. The class is chosen from
    ///      `seed % 4` (one of four buckets is the unverified class); the within-class index is drawn
    ///      from a decorrelated hash of the same seed so it doesn't track the class bit. Keeping the
    ///      unverified pair reachable — never pruning it — is what keeps invariant 5 non-vacuous. If
    ///      either partition were empty we fall back to a uniform pick so the handler stays robust.
    function _recipient(uint256 seed) internal view returns (address) {
        bool wantUnverified = (seed % 4 == 0); // ~25% of picks
        uint256 idx = uint256(keccak256(abi.encode(seed)));
        if (wantUnverified && unverifiedActors.length > 0) {
            return unverifiedActors[bound(idx, 0, unverifiedActors.length - 1)];
        }
        if (verifiedActors.length > 0) {
            return verifiedActors[bound(idx, 0, verifiedActors.length - 1)];
        }
        return _actor(seed);
    }

    /// @dev A `transfer` sender, biased toward actors that currently hold a non-zero balance. Bounded
    ///      scan over the fixed actor set (≤6). Falls back to a uniform pick when nobody holds — that
    ///      pick then early-returns on the empty-balance guard, so the fallback is a safe no-op. This
    ///      is a coverage optimisation only: it never invents a holder (holdings come from real
    ///      mints/transfers), it just stops spending selections on senders guaranteed to be empty.
    function _holder(uint256 seed) internal view returns (address) {
        address[] memory holders = new address[](actors.length);
        uint256 n;
        for (uint256 i = 0; i < actors.length; i++) {
            if (token.balanceOf(actors[i]) > 0) {
                holders[n++] = actors[i];
            }
        }
        if (n == 0) {
            return _actor(seed);
        }
        return holders[bound(seed, 0, n - 1)];
    }
}
