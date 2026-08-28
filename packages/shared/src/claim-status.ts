// The single, canonical resolver for a claim's effective status. It joins the API-owned claim
// row (`claims`) with the indexer-owned chain row (`claim_chain_state`) — the two halves of the
// deliberate single-writer split — into one status an operator or investor can act on.
//
// Written ONCE, here, so Phases 4 and 5 (and the API read layer) share identical precedence.
// Never reimplement this precedence anywhere else: a second copy drifts the moment someone
// reorders two branches, and the disagreement is invisible until a regulator asks why the two
// portals show different states for the same claim.

/**
 * The resolved status of a claim once the off-chain lifecycle and on-chain reality are joined.
 * This is a superset of the DB `ClaimStatus` enum: it adds ACTIVE / REVOKED / REMOVED, which are
 * facts about the chain, not about what the operator did.
 */
export type EffectiveClaimStatus =
  | "PENDING_SUBMISSION"
  | "ACTIVE"
  | "REVOKED"
  | "REMOVED"
  | "EXPIRED";

/** Minimal shape of the API-owned `claims` row this resolver needs. */
export interface EffectiveClaimInput {
  /** Off-chain expiry. `null` means the claim never expires. */
  expiresAt: Date | null;
}

/**
 * Minimal shape of the indexer-owned `claim_chain_state` row. Pass `null`/`undefined` when the
 * indexer has not yet observed this claim on chain (no chain row exists).
 */
export interface EffectiveClaimChainInput {
  /** The ClaimIssuer has revoked the claim on chain. */
  revoked: boolean;
  /** The claim is present on the identity (ClaimAdded/ClaimChanged, not ClaimRemoved). */
  present: boolean;
}

/** A resolved status paired with a regulator-repeatable reason, rendered verbatim by the UI. */
export interface EffectiveClaimResult {
  status: EffectiveClaimStatus;
  reason: string;
}

/**
 * Regulator-repeatable reason strings, one per resolved status. Exported so the portals and the
 * audit log quote the exact same sentence rather than paraphrasing.
 */
export const EFFECTIVE_CLAIM_REASONS: Record<EffectiveClaimStatus, string> = {
  PENDING_SUBMISSION:
    "No on-chain claim record exists yet; the signed claim has not been submitted to the investor's identity.",
  ACTIVE: "The claim is present on chain, has not been revoked, and is within its validity period.",
  REVOKED: "The claim issuer has revoked this claim on chain; it is no longer valid.",
  REMOVED: "The claim has been removed from the investor's identity and is no longer present on chain.",
  EXPIRED: "The claim's off-chain expiry has passed and it must be re-issued.",
};

/**
 * Resolve a claim's effective status from the API-owned claim row and the optional indexer-owned
 * chain row. Precedence (do not reorder):
 *
 *   1. no chain row              -> PENDING_SUBMISSION
 *   2. chain row, revoked        -> REVOKED
 *   3. chain row, not present    -> REMOVED
 *   4. expiresAt in the past     -> EXPIRED
 *   5. otherwise                 -> ACTIVE
 *
 * @param claim  the API-owned claim row (only `expiresAt` is consulted)
 * @param chain  the indexer-owned chain row, or null/undefined if none has been observed
 * @param now    the reference instant for expiry (defaults to the current time)
 */
export function effectiveClaimStatus(
  claim: EffectiveClaimInput,
  chain: EffectiveClaimChainInput | null | undefined,
  now: Date = new Date(),
): EffectiveClaimResult {
  if (!chain) {
    return { status: "PENDING_SUBMISSION", reason: EFFECTIVE_CLAIM_REASONS.PENDING_SUBMISSION };
  }
  if (chain.revoked) {
    return { status: "REVOKED", reason: EFFECTIVE_CLAIM_REASONS.REVOKED };
  }
  if (!chain.present) {
    return { status: "REMOVED", reason: EFFECTIVE_CLAIM_REASONS.REMOVED };
  }
  if (claim.expiresAt !== null && claim.expiresAt.getTime() <= now.getTime()) {
    return { status: "EXPIRED", reason: EFFECTIVE_CLAIM_REASONS.EXPIRED };
  }
  return { status: "ACTIVE", reason: EFFECTIVE_CLAIM_REASONS.ACTIVE };
}
