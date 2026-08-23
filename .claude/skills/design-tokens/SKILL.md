---
name: design-tokens
description: Use when styling any UI, creating components, configuring Tailwind, or translating a Claude Design mockup into code. Contains the Tessera design tokens — colors, semantic compliance states, typography scale, spacing, radii — extracted from the design system mockup.
---

# Tessera design tokens

Extracted from `design/RWA_Tokenization_Design_System_dc.html`. That file is the visual
contract; these tokens are its machine-readable form. **Never invent values outside this set.**

## Governing principles (from the design system)

- **One primary. Everything else is neutral or carries regulatory meaning.** Color is never
  decorative — if something is green, an operator will act on it.
- **If a human cannot retype it from memory, it is set in mono.** Absolute rule.
- Radii are deliberately tight. Density over comfort in the agent console.

## Color

**Primary — pine teal**

| Step | Hex |
| --- | --- |
| 50 | `#F2F8F7` |
| 100 | `#E3F0EE` |
| 200 | `#B9D8D3` |
| 300 | `#7FB8B0` |
| 500 | `#12786F` |
| 600 (base) | `#0E635C` |
| 700 | `#0B4F4A` |
| 900 | `#06302E` |

**Neutral — cool gray**

`000 #FFFFFF` · `025 #FAFBFC` · `050 #F7F9FA` · `100 #F5F7F9` · `200 #EDF0F3` ·
`300 #DFE4E9` · `400 #C7CED6` · `500 #9AA4AF` · `600 #6E7885` · `700 #515B67` ·
`800 #3A424D` · `900 #262C35` · `950 #161A20`

App background: `#E7EBEF`.

**Semantic — compliance states.** Each has foreground / background / border. Use only for the
meaning stated; never decoratively.

| State | Meaning | fg | bg | bd |
| --- | --- | --- | --- | --- |
| **Verified** | Compliant, eligible, transfer allowed | `#0E7A5F` | `#E6F4EF` | `#B7E0D0` |
| **Pending** | In review, awaiting issuer claim | `#9A6410` | `#FDF3E0` | `#F0DCAE` |
| **Blocked** | Frozen, rejected, transfer denied | `#B42318` | `#FDECEA` | `#F5C9C3` |
| **Paused** | Disabled, dormant, no action possible | `#5A6472` | `#EFF1F4` | `#D8DDE4` |

Dark theme: surfaces darken and lift (base `#0D1015`); semantic hues brighten to hold contrast.
Ratios are preserved — a Blocked row must read identically in either theme.

## Typography

- **UI:** `"Space Grotesk", system-ui, sans-serif` — geometric, tight, unsentimental.
- **On-chain values:** `"Roboto Mono", monospace` — addresses, hashes, amounts, block numbers, IDs.

| Token | Size / line-height / tracking / weight |
| --- | --- |
| display | 56 / 1.05 / −3% / 600 |
| h1 | 32 / 1.15 / −2% / 600 |
| h2 | 24 / 1.20 / −1.5% / 600 |
| h3 | 18 / 1.30 / 0 / 600 |
| h4 | 13 / 1.30 / +7% / 600 · **uppercase** |
| body | 14 / 1.65 / 0 / 400 |
| caption | 12 / 1.50 / 0 / 400 |

## Spacing — 4px base

`xs 4` · `sm 8` · `md 12` · `lg 16` · `xl 24` · `2xl 32` · `3xl 48` · `4xl 80`

## Radius — tight

`xs 2` · `sm 4` · `md 6` · `pill 999`

Default for cards, inputs, and buttons is **4px**. Do not round more.

## Elevation

`e0` flat · `e1` card. Keep shadows subtle — this is a terminal, not a consumer app.

## On-chain primitives (domain components)

- **Address chip** — truncated **6/4** (`0x7A3f9B…9C21`), copy on click, shows a registry
  label when known (`northgate.eth`), badge variants for `FROZEN` / `unassigned`, and an
  external-link affordance for tx hashes.
- **Claim / topic chips** — `KYC ✓`, `AML ✓`, `Accredited ✓`, `Tax residency ◷`. Hover reveals
  **issuer and expiry**. A claim always names its issuer.
- **Transfer pre-check panel** — states its reason in words an operator could repeat to a
  regulator. Allowed (Verified palette) / Blocked (Blocked palette).

## Tailwind mapping

Expose these as `theme.extend` in `packages/config` so both apps share one source:
`colors.primary.*`, `colors.neutral.*`, `colors.verified|pending|blocked|paused.{fg,bg,bd}`,
`fontFamily.sans` / `fontFamily.mono`, `borderRadius.{xs,sm,md}`, plus the spacing scale.
Component classes reference tokens only — no raw hex in components.
