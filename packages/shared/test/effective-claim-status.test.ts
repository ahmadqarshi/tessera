import { describe, expect, it } from "vitest";
import {
  EFFECTIVE_CLAIM_REASONS,
  effectiveClaimStatus,
  type EffectiveClaimStatus,
} from "@tessera/shared";

// Exhaustive, table-driven coverage of the single claim-status resolver. Every combination of
// (chain row absent/present, revoked, present, expiresAt past/future/null) is enumerated with a
// hand-written expected status — the expected values are NOT recomputed from the resolver's own
// logic, so a reordered precedence branch fails a row instead of silently agreeing with itself.
//
// This lives in @tessera/shared, next to the resolver it guards: the resolver is a shared constant
// consumed by the API read layer and Phases 4 and 5, so its test belongs in the same workspace
// rather than in apps/api.
describe("effectiveClaimStatus", () => {
  const now = new Date("2026-08-29T00:00:00.000Z");
  const past = new Date(now.getTime() - 1_000);
  const future = new Date(now.getTime() + 1_000);

  type ExpiresKind = "past" | "future" | "null";
  const expiresFor = (kind: ExpiresKind): Date | null =>
    kind === "past" ? past : kind === "future" ? future : null;

  interface Row {
    label: string;
    chain: { revoked: boolean; present: boolean } | null;
    expires: ExpiresKind;
    expected: EffectiveClaimStatus;
  }

  const rows: Row[] = [
    // No chain row yet — always PENDING_SUBMISSION regardless of off-chain expiry.
    { label: "no chain row, expiry past", chain: null, expires: "past", expected: "PENDING_SUBMISSION" },
    { label: "no chain row, expiry future", chain: null, expires: "future", expected: "PENDING_SUBMISSION" },
    { label: "no chain row, no expiry", chain: null, expires: "null", expected: "PENDING_SUBMISSION" },

    // Revoked wins over present=false and over expiry.
    { label: "revoked, present, expiry past", chain: { revoked: true, present: true }, expires: "past", expected: "REVOKED" },
    { label: "revoked, present, expiry future", chain: { revoked: true, present: true }, expires: "future", expected: "REVOKED" },
    { label: "revoked, present, no expiry", chain: { revoked: true, present: true }, expires: "null", expected: "REVOKED" },
    { label: "revoked, not present, expiry past", chain: { revoked: true, present: false }, expires: "past", expected: "REVOKED" },
    { label: "revoked, not present, expiry future", chain: { revoked: true, present: false }, expires: "future", expected: "REVOKED" },
    { label: "revoked, not present, no expiry", chain: { revoked: true, present: false }, expires: "null", expected: "REVOKED" },

    // Not revoked, not present -> REMOVED wins over expiry.
    { label: "removed, expiry past", chain: { revoked: false, present: false }, expires: "past", expected: "REMOVED" },
    { label: "removed, expiry future", chain: { revoked: false, present: false }, expires: "future", expected: "REMOVED" },
    { label: "removed, no expiry", chain: { revoked: false, present: false }, expires: "null", expected: "REMOVED" },

    // Present, not revoked -> expiry decides.
    { label: "present, expiry past -> EXPIRED", chain: { revoked: false, present: true }, expires: "past", expected: "EXPIRED" },
    { label: "present, expiry future -> ACTIVE", chain: { revoked: false, present: true }, expires: "future", expected: "ACTIVE" },
    { label: "present, no expiry -> ACTIVE", chain: { revoked: false, present: true }, expires: "null", expected: "ACTIVE" },
  ];

  for (const row of rows) {
    it(`${row.label} -> ${row.expected}`, () => {
      const result = effectiveClaimStatus({ expiresAt: expiresFor(row.expires) }, row.chain, now);
      expect(result.status).toBe(row.expected);
      expect(result.reason).toBe(EFFECTIVE_CLAIM_REASONS[row.expected]);
    });
  }

  it("treats expiresAt exactly equal to now as EXPIRED (inclusive boundary)", () => {
    const result = effectiveClaimStatus({ expiresAt: new Date(now) }, { revoked: false, present: true }, now);
    expect(result.status).toBe("EXPIRED");
  });

  it("defaults `now` to the current time when omitted", () => {
    const longAgo = new Date("2000-01-01T00:00:00.000Z");
    const result = effectiveClaimStatus({ expiresAt: longAgo }, { revoked: false, present: true });
    expect(result.status).toBe("EXPIRED");
  });
});
