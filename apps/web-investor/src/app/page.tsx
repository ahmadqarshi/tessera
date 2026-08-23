import { ConnectButton } from "@rainbow-me/rainbowkit";

export default function HomePage() {
  return (
    <main className="mx-auto flex min-h-screen max-w-3xl flex-col justify-center gap-xl px-lg">
      <header className="flex flex-col gap-sm">
        <span className="text-h4 uppercase text-primary-600">Tessera · Investor Portal</span>
        <h1 className="text-h1 text-neutral-900">
          Tokenized real-world assets for verified investors.
        </h1>
        <p className="max-w-prose text-body text-neutral-600">
          Scaffold placeholder — investor screens land in Phase 4. Compliance state is never
          softened or hidden.
        </p>
      </header>

      <div>
        <ConnectButton />
      </div>

      <p className="text-caption text-neutral-500">
        On-chain values render in mono, e.g.{" "}
        <code className="font-mono text-neutral-700">0x7A3f9B…9C21</code>.
      </p>
    </main>
  );
}
