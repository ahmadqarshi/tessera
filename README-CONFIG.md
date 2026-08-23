# Tessera — Claude Code configuration bundle

Drop these into your monorepo root. Structure:

```
CLAUDE.md                                    root rules
contracts/CLAUDE.md
apps/api/CLAUDE.md
apps/indexer/CLAUDE.md
apps/web-investor/CLAUDE.md
apps/web-admin/CLAUDE.md
.claude/
  skills/
    screen-implementation/SKILL.md           mockup -> wired React
    trex-contracts/SKILL.md                  ERC-3643 / ONCHAINID
    indexer-patterns/SKILL.md                reorg-safe indexing
    design-tokens/SKILL.md                   Tessera tokens
  agents/
    solidity-auditor.md
    design-fidelity-reviewer.md
    indexer-correctness.md
  commands/
    implement-screen.md                      /implement-screen <portal> <screen>
    audit-contracts.md                       /audit-contracts
    verify-indexer.md                        /verify-indexer
    deploy-local.md                          /deploy-local
docs/
  SCAFFOLD-PROMPT.md                         first prompt to run
  TASKS.md                                   ordered build task list
```

## Order of operations

1. Empty dir -> copy this bundle in (keep the paths).
2. Copy design mockups:
   - Investor_Portal_dc.html            -> apps/web-investor/design/
   - Admin_Console_dc.html              -> apps/web-admin/design/
   - RWA_Tokenization_Design_System_dc.html -> both design/ folders
3. Open Claude Code, run the prompt in docs/SCAFFOLD-PROMPT.md.
4. Work through docs/TASKS.md in order.

Note: the workspace CLAUDE.md files sit inside dirs the scaffold creates. If Claude Code
complains about pre-existing files, that is expected and fine - it should merge, not overwrite.
