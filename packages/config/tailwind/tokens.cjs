/**
 * Tessera design tokens — the machine-readable form of
 * `design/RWA Tokenization Design System.dc.html`, mirrored from
 * `.claude/skills/design-tokens/SKILL.md`.
 *
 * This file is the single source of truth. Components reference these tokens (via the
 * Tailwind preset) only — never a raw hex value.
 *
 * Governing principle: one primary; everything else is neutral or carries regulatory
 * meaning. Color is never decorative.
 */

const colors = {
  // App canvas.
  app: "#E7EBEF",

  // Primary — pine teal. 600 is the base.
  primary: {
    50: "#F2F8F7",
    100: "#E3F0EE",
    200: "#B9D8D3",
    300: "#7FB8B0",
    500: "#12786F",
    600: "#0E635C",
    700: "#0B4F4A",
    900: "#06302E",
    DEFAULT: "#0E635C",
  },

  // Neutral — cool gray.
  neutral: {
    "000": "#FFFFFF",
    "025": "#FAFBFC",
    "050": "#F7F9FA",
    100: "#F5F7F9",
    200: "#EDF0F3",
    300: "#DFE4E9",
    400: "#C7CED6",
    500: "#9AA4AF",
    600: "#6E7885",
    700: "#515B67",
    800: "#3A424D",
    900: "#262C35",
    950: "#161A20",
  },

  // Semantic — compliance states. Use only for the stated meaning, never decoratively.
  // Each carries foreground / background / border.
  verified: { fg: "#0E7A5F", bg: "#E6F4EF", bd: "#B7E0D0" }, // compliant, transfer allowed
  pending: { fg: "#9A6410", bg: "#FDF3E0", bd: "#F0DCAE" }, // in review, awaiting claim
  blocked: { fg: "#B42318", bg: "#FDECEA", bd: "#F5C9C3" }, // frozen, rejected, denied
  paused: { fg: "#5A6472", bg: "#EFF1F4", bd: "#D8DDE4" }, // disabled, dormant
};

// Typography: [fontSize, { lineHeight, letterSpacing, fontWeight }].
// UI is Space Grotesk; on-chain values (addresses, hashes, amounts, ids) are Roboto Mono.
const fontSize = {
  display: ["56px", { lineHeight: "1.05", letterSpacing: "-0.03em", fontWeight: "600" }],
  h1: ["32px", { lineHeight: "1.15", letterSpacing: "-0.02em", fontWeight: "600" }],
  h2: ["24px", { lineHeight: "1.2", letterSpacing: "-0.015em", fontWeight: "600" }],
  h3: ["18px", { lineHeight: "1.3", letterSpacing: "0", fontWeight: "600" }],
  // h4 is uppercase; apply `uppercase` utility at the call site.
  h4: ["13px", { lineHeight: "1.3", letterSpacing: "0.07em", fontWeight: "600" }],
  body: ["14px", { lineHeight: "1.65", letterSpacing: "0", fontWeight: "400" }],
  caption: ["12px", { lineHeight: "1.5", letterSpacing: "0", fontWeight: "400" }],
};

// The leading CSS variable is populated by `next/font` (see each app's layout); it resolves
// to the loaded Space Grotesk / Roboto Mono, with the literal stack as the fallback.
const fontFamily = {
  sans: ["var(--font-sans)", '"Space Grotesk"', "system-ui", "sans-serif"],
  mono: ["var(--font-mono)", '"Roboto Mono"', "ui-monospace", "SFMono-Regular", "monospace"],
};

// Spacing — 4px base.
const spacing = {
  xs: "4px",
  sm: "8px",
  md: "12px",
  lg: "16px",
  xl: "24px",
  "2xl": "32px",
  "3xl": "48px",
  "4xl": "80px",
};

// Radius — deliberately tight. Default for cards, inputs, buttons is 4px.
const borderRadius = {
  xs: "2px",
  sm: "4px",
  md: "6px",
  pill: "9999px",
};

// Elevation — subtle; this is a terminal, not a consumer app.
const boxShadow = {
  e0: "none",
  e1: "0 1px 2px rgba(22, 26, 32, 0.06), 0 1px 3px rgba(22, 26, 32, 0.04)",
};

module.exports = {
  colors,
  fontSize,
  fontFamily,
  spacing,
  borderRadius,
  boxShadow,
};
