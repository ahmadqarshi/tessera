import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { foundry, polygonAmoy } from "viem/chains";

// WalletConnect project id is optional for local dev; a placeholder keeps RainbowKit happy.
const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? "tessera-local-demo";

export const wagmiConfig = getDefaultConfig({
  appName: "Tessera Agent Console",
  projectId,
  chains: [foundry, polygonAmoy],
  ssr: true,
});
