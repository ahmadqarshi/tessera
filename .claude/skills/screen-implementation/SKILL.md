---
name: screen-implementation
description: Use when implementing or modifying any portal screen or UI component in apps/web-investor or apps/web-admin — turning a Claude Design mockup in design/ into wired React components, or adding data/state/behavior to an existing screen. Covers the read/write wiring rules, form and amount conventions, and required component states.
---

# Screen implementation

Turn a screen from the `design/` mockup into production React components wired to the stack.
**Do not redesign.** Match the mockup exactly; only add data, state, and behavior.

## Before writing code

1. Open the workspace `CLAUDE.md` for the screen list and app-specific rules.
2. Open the relevant section of `design/*.html` and read the actual markup — spacing, states,
   and copy are all specified there.
3. Load the `design-tokens` skill for the token mapping.
4. Identify the screen's reads, writes, and states using the checklist below.

## Stack

Next.js App Router + TypeScript · wagmi v2 + viem · RainbowKit · SIWE → JWT · TanStack Query
against the NestJS API (`NEXT_PUBLIC_API_URL`) · react-hook-form + Zod.

Server Components for static shell; `'use client'` only for interactivity or wallet access.

## The two wiring rules

**Rule 1 — Reads.** Lists, balances, holder counts, investor status, transfers, and audit
entries come from the **indexer-backed API** via TanStack Query. Do **not** read the chain for
these. Use wagmi `useReadContract` only for values that are inherently live and unindexed.

**Rule 2 — Writes, split by portal.**

| Portal | Path | Mechanism |
| --- | --- | --- |
| `web-investor` | investor's own action (transfer) | **Client-signed**: `useWriteContract` → `useWaitForTransactionReceipt` |
| `web-admin` | any privileged action | **API mutation**: POST endpoint, backend agent wallet signs server-side |

Privileged = mint, distribute, pause/unpause, freeze address, partial freeze, forced transfer,
issue/revoke claim, register identity. **Never client-sign these.** `useWriteContract` must not
appear anywhere in `web-admin`.

## Conventions

- **Amounts are `bigint`.** `parseUnits` / `formatUnits` at boundaries only; never JS `number`
  arithmetic on balances. Serialize as decimal strings over the wire.
- **Addresses** typed as viem `Address`, validated with `isAddress` in the Zod schema.
- **Mono type style** for every address, tx hash, on-chain amount, block number, and ID.
  Rule from the design system: *if a human cannot retype it from memory, it is set in mono.*
- **Spendable balance is `balance - frozen`.** Never present raw balance as spendable.
- Reason strings from the API render **verbatim**. Never paraphrase or invent client-side.

## Required states

Every data-driven component ships: **loading** (skeleton, per the mockup's shimmer),
**empty**, **error**, and **success**. Buttons show disabled/pending during signing or
in-flight requests. Toasts on success and failure. After a confirmed write, invalidate the
affected query keys (in `web-admin`, always also `['audit']`).

## Output shape

Co-locate per screen: a container component, a typed hook layer (queries + mutations), Zod
schemas, and presentational subcomponents. Reuse design-system components already in the
project rather than creating near-duplicates. TypeScript strict, no `any`.

## Per-screen checklist

Fill this in before generating:

```
Screen name:
Purpose (one line):
Reads (API endpoints):
Reads (chain, only if live):     [usually: none]
Writes (endpoint OR contract fn; state which rule-2 path):
Form fields + Zod validation:
Key states (the specific empty/blocked/pending cases in the mockup):
```

## Worked example — Investor Transfer

```
Screen name: Investor Transfer
Purpose: Send tokens to another wallet with a live compliance pre-check before signing.
Reads (API): GET /me/holdings  → tokens + spendable (balance − frozen)
Reads (chain): none
Writes:
  - Pre-check: POST /transfers/precheck { token, to, amount } → { allowed, reason }
    debounced ~400ms on form change
  - Execute: CLIENT-SIGNED, wagmi useWriteContract → Token.transfer(to, amount)
    on receipt, invalidate ['holdings'] and ['transactions']
Form fields:
  token   required, one of the user's held tokens
  to      required, isAddress, ≠ self
  amount  required, > 0, ≤ spendable (parseUnits with token decimals)
Key states:
  ALLOWED  → green pre-check panel, enable "Confirm & Sign"
  BLOCKED  → red panel with API `reason` verbatim, submit disabled
  signing / confirming → spinner, inputs locked
  success  → toast + tx hash (mono, explorer link)
  no wallet → SIWE connect prompt instead of the form
```

**The dependency is the point:** submit stays disabled until the pre-check returns
`allowed: true`, so the user never pays gas on a transfer that would revert.
