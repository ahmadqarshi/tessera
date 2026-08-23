# apps/web-investor — Investor portal (Next.js)

Public-facing portal for investors holding tokenized real estate. Chain mechanics stay behind
plain language; **compliance state is never softened or hidden**.

Design source: `design/Investor_Portal_dc.html` (static Claude Design mockup — visual contract).

## Screens (from the mockup, in order)

1. **Sign in** — wallet connect + SIWE. States: idle · connecting · waiting for signature ·
   signature rejected.
2. **Identity verification** — four states of one screen: connected → submitting → in review →
   verified.
3. **Offerings** — tranche grid + filters + empty state.
4. **Offering detail** — asset info, backing figure, compliance requirements panel, Invest CTA
   (disabled with explanation when unverified).
5. **Holdings / dashboard** — balances, **frozen amounts called out**, claim status.
6. **Transfer** — the most important screen. Live pre-check with **allowed** and **blocked**
   variants (both designed — implement both).
7. **Activity** — transfer history, counterparty address chips, tx hash links.

## Hard rules

- **Investor writes are client-signed.** `useWriteContract` → `useWaitForTransactionReceipt`.
  The user's own wallet signs. Never route an investor transfer through an API signer.
- **Never enable "Confirm & Sign" until `/transfers/precheck` returns `allowed: true`.** The
  point of this screen is that the user never pays gas on a transfer that would revert.
- Render the API's `reason` string **verbatim** in the blocked panel. Do not paraphrase,
  soften, or invent reasons client-side.
- Reads go through TanStack Query against the API. No direct chain reads for lists/balances.
- Spendable balance is always `balance - frozen`. Never present raw balance as spendable.
- After a confirmed tx, invalidate `['holdings']` and `['transactions']`.

## Conventions

- `'use client'` only where interactivity or wallet access is needed; keep shells as Server
  Components.
- Forms: react-hook-form + Zod. Validate `to` with viem `isAddress`; reject self-transfer.
- Amounts: `parseUnits` / `formatUnits` with the token's decimals. `bigint` only.
- Every address, hash, and on-chain amount uses the **mono** type style (see design-tokens skill).
- Ship loading (skeleton), empty, and error states for every data-driven view — they are in
  the mockup, so they are in scope.
