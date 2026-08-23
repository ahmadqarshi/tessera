---
description: Implement a portal screen from its Claude Design mockup
argument-hint: <portal: investor|admin> <screen name>
---

Implement the **$2** screen in the **$1** portal.

Follow the `screen-implementation` skill and the `design-tokens` skill. Steps:

1. Read `apps/web-$1/CLAUDE.md` for app-specific rules.
2. Locate the `$2` section in `apps/web-$1/design/` and read the actual markup — spacing,
   states, and copy are specified there. Match it exactly; do not redesign.
3. Fill in the per-screen checklist (reads, writes, form fields, states) before writing code.
4. Apply the wiring rules: reads via TanStack Query against the API; writes client-signed for
   investor actions, API mutations for admin privileged actions.
5. Implement every designed state — loading, empty, error, plus the screen's specific states.
6. Run `pnpm lint && pnpm typecheck`.
7. Invoke the `design-fidelity-reviewer` subagent and address any Must-fix findings.
