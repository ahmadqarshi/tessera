import type { Config } from "tailwindcss";
import preset from "@tessera/config/tailwind";

const config: Config = {
  presets: [preset],
  content: ["./src/**/*.{ts,tsx}"],
};

export default config;
