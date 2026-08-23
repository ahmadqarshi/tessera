import type { Metadata } from "next";
import type { ReactNode } from "react";
import localFont from "next/font/local";
import { Providers } from "./providers";
import "./globals.css";

// Fonts are bundled locally (see src/fonts, OFL-licensed) so the app builds offline with no
// Google Fonts network dependency. UI is Space Grotesk; on-chain values are Roboto Mono.
const spaceGrotesk = localFont({
  src: "../fonts/SpaceGrotesk[wght].ttf",
  variable: "--font-sans",
  weight: "300 700",
  display: "swap",
});
const robotoMono = localFont({
  src: "../fonts/RobotoMono[wght].ttf",
  variable: "--font-mono",
  weight: "100 700",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Tessera · Agent Console",
  description: "Operator console for RWA compliance — every privileged action is audited.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${spaceGrotesk.variable} ${robotoMono.variable}`}>
      <body className="min-h-screen bg-app font-sans text-neutral-900 antialiased">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
