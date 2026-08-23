/**
 * Shared Tailwind preset for both Tessera portals.
 *
 * Consumes the design tokens and exposes them under `theme.extend` so a component can only
 * ever reference a token (`bg-primary-600`, `text-verified-fg`, `rounded-sm`, `font-mono`)
 * and never a raw hex value. Both apps share this one source.
 */
const tokens = require("./tokens.cjs");

/** @type {import('tailwindcss').Config} */
module.exports = {
  theme: {
    extend: {
      colors: tokens.colors,
      fontFamily: tokens.fontFamily,
      fontSize: tokens.fontSize,
      spacing: tokens.spacing,
      borderRadius: tokens.borderRadius,
      boxShadow: tokens.boxShadow,
      backgroundColor: {
        app: tokens.colors.app,
      },
    },
  },
  plugins: [],
};
