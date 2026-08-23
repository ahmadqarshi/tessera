// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { Test } from "forge-std/Test.sol";

import { Token } from "@erc-3643/contracts/token/Token.sol";

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

    /// @dev Upper bound on a single mint. Comfortably below the point where a depth-64 run of mints
    ///      could overflow `totalSupply` (64 × 1e6 × 1e18 ≪ 2²⁵⁶), so mints never revert on overflow.
    uint256 internal constant MAX_MINT = 1_000_000e18;

    // ── Ghost state (see contract doc) ───────────────────────────────────────────────────────
    uint256 public ghostForcedTransfers;
    uint256 public ghostNetSupply;

    constructor(Token _token, address _agent, address[] memory _actors) {
        token = _token;
        agent = _agent;
        actors = _actors;
        // Seed the net-supply ghost with whatever the fixture already minted (A + B). From here on
        // every mint/burn keeps it exact, so `totalSupply == ghostNetSupply` holds from the start.
        ghostNetSupply = _token.totalSupply();
    }

    // ── Holder-initiated move ────────────────────────────────────────────────────────────────

    /**
     * @dev A normal ERC-20 `transfer`, pranked from the sender. May revert for a legitimate reason
     *      the fuzzer should be free to hit — the cap (`moduleCheck` rejects the (cap+1)-th holder),
     *      an unverified receiver (C/D), a frozen wallet, or the paused state — so it is wrapped in
     *      try/catch: we care about the state AFTER whatever the token decided, not about forcing a
     *      success. Amount is bound to [1, balance]; a zero-value move reverts in ModularCompliance
     *      (`_value > 0`) and would only waste runs, so senders with an empty balance are skipped.
     */
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        if (balance == 0) {
            return;
        }
        uint256 amount = bound(amountSeed, 1, balance);

        vm.prank(from);
        try token.transfer(to, amount) { } catch { }
    }

    // ── Agent operations ─────────────────────────────────────────────────────────────────────

    /**
     * @dev Agent `forcedTransfer`. Its real predicate is: caller is an agent, `amount <= balance`,
     *      and `isVerified(_to)` — and it is INDEPENDENT of either party's freeze flag (NOTES.md
     *      §7.1). So frozen actors are intentionally NOT excluded: an agent must be able to seize
     *      from, or reassign onto, a quarantined wallet. On success we bump {ghostForcedTransfers}
     *      (the cap invariant keys off it) and assert the auto-unfreeze arithmetic on the sender.
     */
    function forcedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
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
    function mint(uint256 toSeed, uint256 amountSeed) external {
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 1, MAX_MINT);

        vm.prank(agent);
        try token.mint(to, amount) {
            ghostNetSupply += amount;
        } catch { }
    }

    /**
     * @dev Agent `burn`, bound to [1, balance]. Auto-unfreezes any shortfall, so it never reverts
     *      for a funded holder; the try/catch is belt-and-braces. Asserts the same shortfall
     *      arithmetic as {forcedTransfer} and folds the burn into {ghostNetSupply}.
     */
    function burn(uint256 fromSeed, uint256 amountSeed) external {
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
    function freezePartialTokens(uint256 whoSeed, uint256 amountSeed) external {
        address who = _actor(whoSeed);
        uint256 freezable = token.balanceOf(who) - token.getFrozenTokens(who); // no underflow (inv 3)
        uint256 amount = bound(amountSeed, 0, freezable);

        vm.prank(agent);
        token.freezePartialTokens(who, amount);
    }

    /**
     * @dev Agent `unfreezePartialTokens`, bound to [0, frozen] so `frozen >= amount` always holds
     *      and the call is legal by construction.
     */
    function unfreezePartialTokens(uint256 whoSeed, uint256 amountSeed) external {
        address who = _actor(whoSeed);
        uint256 amount = bound(amountSeed, 0, token.getFrozenTokens(who));

        vm.prank(agent);
        token.unfreezePartialTokens(who, amount);
    }

    /// @dev Agent whole-wallet freeze toggle. Never reverts; it changes only whether the holder
    ///      paths (`transfer`) may touch this wallet — forced transfers ignore the flag entirely.
    function setAddressFrozen(uint256 whoSeed, bool freeze) external {
        address who = _actor(whoSeed);
        vm.prank(agent);
        token.setAddressFrozen(who, freeze);
    }

    /// @dev Global pause. try/catch because `pause()` carries `whenNotPaused` (calling it while
    ///      already paused reverts); we want the fuzzer to attempt it in either state.
    function pause() external {
        vm.prank(agent);
        try token.pause() { } catch { }
    }

    /// @dev Global unpause; `whenPaused`, so try/catch for the already-unpaused case.
    function unpause() external {
        vm.prank(agent);
        try token.unpause() { } catch { }
    }

    // ── Views ────────────────────────────────────────────────────────────────────────────────

    /// @notice The fixed actor universe, exposed so the invariant contract iterates the same set.
    function getActors() external view returns (address[] memory) {
        return actors;
    }

    // ── Internal ─────────────────────────────────────────────────────────────────────────────

    /// @dev Map a fuzzer seed onto one of the fixed actors. `bound` (never `assume`) so no call is
    ///      discarded — every fuzzer step lands on a real party.
    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }
}
