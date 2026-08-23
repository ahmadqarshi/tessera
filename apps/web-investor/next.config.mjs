/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@tessera/shared"],
  // Lint is a dedicated turbo task (`pnpm lint`); don't double-run it during the build.
  eslint: { ignoreDuringBuilds: true },
};

export default nextConfig;
