// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import { AbstractModule } from "@erc-3643/contracts/compliance/modular/modules/AbstractModule.sol";
import {
    IModularCompliance
} from "@erc-3643/contracts/compliance/modular/IModularCompliance.sol";
import { IToken } from "@erc-3643/contracts/token/IToken.sol";

/**
 * @title MaxInvestorsModule — a distinct-holder cap for an ERC-3643 token.
 *
 * @notice A custom {ModularCompliance} module (the only kind CLAUDE.md permits us to add — we
 *         extend via {IModule}, never fork the audited core) that limits how many distinct
 *         wallets may hold a non-zero balance of the bound token. It exists to model a common
 *         private-placement constraint: e.g. a Reg D 506(b) offering capped at 99 investors, or
 *         a fund that must stay under the 100-holder Investment Company Act threshold.
 *
 * ── How the count stays correct: an incremental mirror, never a loop ────────────────────────
 *   The module keeps its OWN mirror of each holder's balance (`_balances`) and a running
 *   `_investorCount`, both keyed by compliance. Every lifecycle hook nudges the mirror by the
 *   transferred value and adjusts the count only on a **zero ↔ non-zero crossing**. There is no
 *   iteration over holders anywhere — the count is maintained in O(1) per hook, so gas is flat
 *   regardless of how many investors exist (CLAUDE.md: "No unbounded loops over holders").
 *
 *   Why a self-maintained mirror rather than reading `token.balanceOf`? The compliance calls
 *   these hooks AFTER the token has already moved the balance (Token: `_transfer` then
 *   `compliance.transferred`), so a post-move `balanceOf` cannot tell us the holder's PRIOR
 *   balance — the very thing a crossing test needs. Mirroring also keeps every hook free of
 *   external calls, so the module needs no reentrancy guard (contracts/NOTES.md §2).
 *
 *   ⚠️ Binding requirement, now ENFORCED on-chain: the mirror starts empty, so this module must be
 *   added to a compliance BEFORE its token has any holders — exactly what {Deploy} guarantees
 *   (addModule precedes the first mint). Binding to a compliance whose token already holds balances
 *   would start the count below reality, and the cap would then silently UNDER-enforce (the worst
 *   compliance failure mode: it looks like success while the true holder set passes the legal
 *   threshold the module exists to protect). We refuse that binding: {isPlugAndPlay} returns false
 *   so {ModularCompliance.addModule} consults {canComplianceBind}, which rejects any compliance
 *   whose bound token already has holders. See {canComplianceBind} for how "zero holders" is
 *   established in O(1) without a holder scan, and why its single external call does NOT reintroduce
 *   a reentrancy surface in the hooks (contracts/NOTES.md §8).
 *
 * ── The cap is enforced on ONE side only, on purpose (contracts/NOTES.md §7.1) ──────────────
 *   {moduleCheck} is the pre-flight the compliance consults from `canTransfer`, and it is the
 *   ONLY place the cap is enforced. It gates holder-initiated moves — `transfer`, `transferFrom`,
 *   and `mint` (mint runs gate 3, `Token.mint` → `canTransfer`). But `forcedTransfer` deliberately
 *   skips `canTransfer` (NOTES §7.1): an agent break-glass transfer can therefore create a holder
 *   past the cap. When that happens {moduleTransferAction} still fires, so the count keeps tracking
 *   REALITY — it is allowed to exceed `maxInvestors`. The cap is thus **advisory on agent paths and
 *   enforced only on holder-initiated ones**. The action hooks reflect what happened; the check
 *   hook decides what is allowed.
 *
 *   Consequence for correctness: {moduleTransferAction} (and the mint/burn actions) MUST NEVER
 *   revert. A revert there would bubble up through `compliance.transferred` and brick the agent's
 *   `forcedTransfer` — and, worse, `recoveryAddress`, which is built on `forcedTransfer`. The
 *   action hooks therefore use saturating arithmetic and carry no business-rule `require`s; only
 *   the {AbstractModule} access guard (`onlyComplianceCall`) can stop them, and that guard is
 *   satisfied on every real call because the bound compliance is the caller.
 *
 * ── A note on the missing "rejection" event ─────────────────────────────────────────────────
 *   A cap-triggered rejection cannot emit an event: {IModule.moduleCheck} is `view` (a `view`
 *   override may not widen state mutability), so the rejection path has no writable frame. The
 *   rejection is observable instead as the `"Transfer not possible"` revert the Token raises when
 *   `canTransfer` returns false. State transitions that DO happen in a non-view frame are emitted:
 *   {MaxInvestorsSet} on a cap change, and {HolderCountChanged} whenever an action hook moves the
 *   distinct-holder count across a zero ↔ non-zero crossing (the indexer's holder-count signal).
 */
contract MaxInvestorsModule is AbstractModule {
    // ── Per-compliance state (a single module instance can serve many compliances) ──────────
    // Keyed by compliance so the module is reusable; the action hooks key by `msg.sender` (the
    // calling compliance) and `moduleCheck` keys by its `_compliance` argument — both resolve to
    // the same compliance for any real call.

    /// @dev Maximum distinct holders permitted per compliance. **Zero is an intentional
    ///      "unlimited" sentinel, not an accident of a fresh mapping.** An unconfigured module
    ///      (`_maxInvestors == 0`) enforces nothing, so it is FAIL-OPEN by design.
    ///
    ///      This is a deliberate choice on a compliance contract, where fail-open is normally the
    ///      wrong instinct — recorded here and in contracts/NOTES.md §9 so it is a decision, not an
    ///      assumption:
    ///        • It is the canonical T-REX module convention (e.g. unset = no limit), and CLAUDE.md
    ///          forbids surprising deviations from the vendored patterns.
    ///        • The alternative — a fail-CLOSED default where an unset cap blocks every move —
    ///          would brick the required wiring order: `addModule` precedes `setMaxInvestors`
    ///          precedes the first `mint`, so a fail-closed default would make that first mint's
    ///          {moduleCheck} return false and revert, breaking `contracts:deploy:local` on a
    ///          fresh clone (CLAUDE.md rule 4). Plug-and-play add-before-configure requires an
    ///          add-time default that permits, i.e. fail-open.
    ///        • The fail-open WINDOW is bounded: by the binding invariant (this NatSpec, above) the
    ///          module is added before the token has holders, so the only interval where the cap
    ///          is 0 is between `addModule` and `setMaxInvestors`, when the count is 0 anyway.
    ///          "Enforces nothing" therefore never applies to a token that already has investors
    ///          on the deploy path.
    ///      Residual risk: an operator binding this module to a NEW compliance in production and
    ///      forgetting to call {setMaxInvestors} silently gets no cap. Mitigate at WIRE TIME, not
    ///      by changing the sentinel — {Deploy} asserts the cap reads back as configured after
    ///      wiring (script/Deploy.s.sol), which is the correct place to catch a missing cap.
    mapping(address => uint256) private _maxInvestors;

    /// @dev Current distinct-holder count per compliance (wallets with a non-zero mirror balance).
    mapping(address => uint256) private _investorCount;

    /// @dev The module's own mirror of holder balances, per compliance. The source of the
    ///      zero ↔ non-zero crossings that drive {_investorCount}. Never read from the token.
    mapping(address => mapping(address => uint256)) private _balances;

    /**
     * @dev Emitted when the cap is (re)configured for a compliance. `_compliance` is the bound
     *      compliance the cap applies to; `_maxInvestors` is the new cap (0 = unlimited).
     */
    event MaxInvestorsSet(address indexed _compliance, uint256 _maxInvestors);

    /**
     * @dev Emitted whenever the distinct-holder count for `_compliance` actually changes — i.e. on
     *      a zero ↔ non-zero mirror crossing inside a mint/burn/transfer action hook. `_newCount` is
     *      the count AFTER the crossing. Routine moves that create no crossing (top-ups, partial
     *      burns, transfers between existing holders) emit nothing, so the event fires exactly on the
     *      transitions the indexer cares about. This lets the indexer track holder counts directly
     *      rather than re-deriving them from `Transfer` logs — which is both slower and drifts after a
     *      reorg rollback. Emitting cannot revert, so it respects the "action hooks never revert"
     *      doctrine (see {moduleTransferAction}).
     */
    event HolderCountChanged(address indexed _compliance, uint256 _newCount);

    // ── Configuration ───────────────────────────────────────────────────────────────────────

    /**
     * @notice Set the distinct-holder cap for the calling compliance.
     * @dev `onlyComplianceCall`, so the caller must be a bound compliance. In practice this is
     *      reached through `ModularCompliance.callModuleFunction`, which is `onlyOwner` — so the
     *      effective authority is "the compliance's owner", per the module spec. Setting a cap
     *      below the current holder count is permitted: it does not evict anyone (the module never
     *      moves tokens), it just blocks further holder-creating transfers until the count falls
     *      back under the new cap. Set to 0 to disable the cap entirely.
     * @param _max the new cap (0 = unlimited).
     */
    function setMaxInvestors(uint256 _max) external onlyComplianceCall {
        _maxInvestors[msg.sender] = _max;
        emit MaxInvestorsSet(msg.sender, _max);
    }

    // ── Lifecycle hooks (state-mutating; called by the bound compliance) ─────────────────────

    /**
     * @dev See {IModule-moduleTransferAction}. A transfer is a debit of `_from` and a credit of
     *      `_to`, applied in that order. Ordering the debit first makes every count case fall out
     *      of two independent crossings, with no special-casing:
     *        • transfer to an EXISTING holder, sender keeps a balance → no crossing → count same.
     *        • transfer that ZEROES the sender (to an existing holder) → one down-crossing → −1.
     *        • transfer that CREATES the receiver (sender keeps a balance) → one up-crossing → +1.
     *        • transfer that both zeroes the sender AND creates the receiver → −1 then +1 → net 0.
     *        • self-transfer (`_from == _to`): debit then credit of the same wallet by the same
     *          value nets to its prior balance; if it held exactly `_value` the balance dips to 0
     *          (−1) and back to `_value` (+1) → net 0, matching intuition that a self-transfer
     *          changes nothing.
     *      Never reverts (saturating debit) so agent forced transfers and recovery cannot brick.
     */
    function moduleTransferAction(address _from, address _to, uint256 _value)
        external
        override
        onlyComplianceCall
    {
        _decreaseBalance(msg.sender, _from, _value);
        _increaseBalance(msg.sender, _to, _value);
    }

    /**
     * @dev See {IModule-moduleMintAction}. A mint credits `_to` from nothing; it increments the
     *      count only if `_to` was not already a holder (mint to an existing holder → unchanged).
     *      The cap on mint is enforced separately by {moduleCheck} (mint runs gate 3), so this
     *      action only needs to keep the mirror accurate.
     */
    function moduleMintAction(address _to, uint256 _value) external override onlyComplianceCall {
        _increaseBalance(msg.sender, _to, _value);
    }

    /**
     * @dev See {IModule-moduleBurnAction}. A burn debits `_from`; it decrements the count only if
     *      the burn takes the holder to exactly zero (a burn that leaves a remainder → unchanged).
     *      Never reverts (saturating debit).
     */
    function moduleBurnAction(address _from, uint256 _value) external override onlyComplianceCall {
        _decreaseBalance(msg.sender, _from, _value);
    }

    // ── Compliance pre-flight (view; the ONLY place the cap is enforced) ─────────────────────

    /**
     * @dev See {IModule-moduleCheck}. Returns false only when the move would push a NEW wallet
     *      over a configured cap: the receiver currently holds nothing in the mirror AND the count
     *      is already at (or above) `maxInvestors`. A move to an existing holder is always allowed
     *      by this module — it cannot raise the count. Mint arrives here as `_from == address(0)`
     *      and is gated identically: a mint to a brand-new wallet at the cap is rejected.
     *
     *      Deliberately conservative: it does not credit the sender's possible exit. A transfer of
     *      a holder's ENTIRE balance to a brand-new wallet is net-zero for the count, yet this
     *      returns false at the cap — because a pre-flight cannot assume the sender will actually
     *      drop to zero, and erring strict keeps the "holders ≤ cap" invariant intact on every
     *      holder-initiated path. The only way past the cap is the agent's `forcedTransfer`, which
     *      skips this check entirely (NOTES §7.1).
     */
    function moduleCheck(
        address,
        /* _from */
        address _to,
        uint256 _value,
        address _compliance
    )
        external
        view
        override
        returns (bool)
    {
        uint256 cap = _maxInvestors[_compliance];
        if (cap == 0) {
            return true; // unconfigured / disabled → no limit
        }
        bool createsHolder = _value > 0 && _balances[_compliance][_to] == 0;
        if (createsHolder && _investorCount[_compliance] >= cap) {
            return false;
        }
        return true;
    }

    // ── Getters ──────────────────────────────────────────────────────────────────────────────

    /// @notice Current distinct-holder count tracked for `_compliance`. May legitimately exceed
    ///         {maxInvestors} after an agent `forcedTransfer` created a holder past the cap.
    function investorCount(address _compliance) external view returns (uint256) {
        return _investorCount[_compliance];
    }

    /// @notice The configured cap for `_compliance` (0 = unlimited).
    function maxInvestors(address _compliance) external view returns (uint256) {
        return _maxInvestors[_compliance];
    }

    /// @notice The module's mirrored balance for `_holder` under `_compliance`. Exposed for tests
    ///         and off-chain reconciliation; equals `token.balanceOf(_holder)` whenever the module
    ///         was bound before the first mint (the deploy-time invariant).
    function mirroredBalance(address _compliance, address _holder) external view returns (uint256) {
        return _balances[_compliance][_holder];
    }

    // ── IModule metadata ─────────────────────────────────────────────────────────────────────

    /**
     * @dev See {IModule-canComplianceBind}. Enforces the binding requirement documented at the
     *      contract level: the module may only bind to a compliance whose token has NO holders yet,
     *      because the mirror initializes empty and cannot recover a pre-existing holder set without
     *      a forbidden holder scan.
     *
     *      "Zero holders" is established in O(1), not by iterating: a token's `totalSupply() == 0`
     *      is equivalent to "no wallet holds a non-zero balance" (supply > 0 implies at least one
     *      holder; supply == 0 implies none). So we bind iff the bound token's supply is zero. A
     *      compliance with no token bound yet (`getTokenBound() == address(0)`) is trivially safe —
     *      there is nothing to under-count — so we permit it and short-circuit before the external
     *      call (calling `totalSupply()` on the zero address would revert).
     *
     *      ⚠️ Reentrancy note (keeps contracts/NOTES.md §8 valid): this makes ONE external call —
     *      `token.totalSupply()` — but it lives in this `view` function, reached only from
     *      `ModularCompliance.addModule` at BIND TIME, never from a transfer/mint/burn action hook.
     *      The action hooks ({moduleTransferAction}/{moduleMintAction}/{moduleBurnAction}) remain
     *      free of external calls, so the "hooks make no external call → no reentrancy guard needed"
     *      finding in §8 is unchanged. Do not read this call as invalidating §8: §8 is about the
     *      hook call path, and this call is off it.
     */
    function canComplianceBind(address _compliance) external view override returns (bool) {
        address boundToken = IModularCompliance(_compliance).getTokenBound();
        if (boundToken == address(0)) {
            return true; // no token bound yet → no holders to under-count → safe to bind
        }
        return IToken(boundToken).totalSupply() == 0;
    }

    /// @dev See {IModule-isPlugAndPlay}. FALSE — we deliberately opt OUT of plug-and-play so that
    ///      `ModularCompliance.addModule` runs the {canComplianceBind} gate above. Returning true
    ///      would let the module bind to a token that already has holders, silently starting the
    ///      mirror below reality and making the cap under-enforce (see the contract-level note).
    function isPlugAndPlay() external pure override returns (bool) {
        return false;
    }

    /// @dev See {IModule-name}. Stable identifier used by tooling and the address book.
    function name() external pure override returns (string memory _name) {
        return "MaxInvestorsModule";
    }

    // ── Internal mirror maintenance ────────────────────────────────────────────────────────────

    /**
     * @dev Credit `_holder` by `_value` in the mirror for `_compliance`, incrementing the count on
     *      a zero → non-zero crossing. Checked addition: an overflow here is impossible in practice
     *      (the mirror sums to the token's totalSupply, which would overflow in the token first),
     *      and if it somehow occurred it would signal a desync worth surfacing loudly.
     */
    function _increaseBalance(address _compliance, address _holder, uint256 _value) private {
        uint256 prev = _balances[_compliance][_holder];
        if (prev == 0 && _value > 0) {
            uint256 newCount = _investorCount[_compliance] + 1;
            _investorCount[_compliance] = newCount;
            emit HolderCountChanged(_compliance, newCount);
        }
        _balances[_compliance][_holder] = prev + _value;
    }

    /**
     * @dev Debit `_holder` by `_value` in the mirror for `_compliance`, decrementing the count on a
     *      non-zero → zero crossing. BOTH the balance debit and the count decrement use SATURATING
     *      math (clamp at 0) rather than checked subtraction: this hook must never revert (see the
     *      contract-level note on forced transfers), so making the decrement literally unable to
     *      underflow — rather than relying on the binding invariant to keep it from underflowing —
     *      matches the doctrine exactly. For a correctly-bound module (which {canComplianceBind} now
     *      enforces) neither clamp ever engages: `_value` never exceeds the mirrored balance and the
     *      count is never decremented below the true holder set. The clamps are belt-and-braces
     *      guards that only fire under an impossible desync, and even then keep the hook non-reverting.
     */
    function _decreaseBalance(address _compliance, address _holder, uint256 _value) private {
        uint256 prev = _balances[_compliance][_holder];
        uint256 next = _value >= prev ? 0 : prev - _value;
        _balances[_compliance][_holder] = next;
        if (prev > 0 && next == 0) {
            uint256 count = _investorCount[_compliance];
            if (count > 0) {
                count -= 1;
                _investorCount[_compliance] = count;
                emit HolderCountChanged(_compliance, count);
            }
        }
    }
}
