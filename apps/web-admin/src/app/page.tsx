import { ConnectButton } from "@rainbow-me/rainbowkit";

export default function HomePage() {
  return (
    <main className="mx-auto flex min-h-screen max-w-3xl flex-col justify-center gap-xl px-lg">
      <header className="flex flex-col gap-sm">
        <span className="text-h4 uppercase text-primary-600">Tessera · Agent Console</span>
        <h1 className="text-h1 text-neutral-900">
          Operator console for RWA compliance.
        </h1>
        <p className="max-w-prose text-body text-neutral-600">
          Scaffold placeholder — operator screens land in Phase 5. Density over comfort; every
          privileged action is confirmed and audited.
        </p>
      </header>

      <div>
        <ConnectButton />
      </div>

      <p className="text-caption text-neutral-500">
        Compliance states are color-coded:{" "}
        <span className="rounded-sm border border-verified-bd bg-verified-bg px-xs text-verified-fg">
          verified
        </span>{" "}
        <span className="rounded-sm border border-blocked-bd bg-blocked-bg px-xs text-blocked-fg">
          blocked
        </span>
        .
      </p>
    </main>
  );
}
