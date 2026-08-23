---
description: Audit indexer correctness and run its test suite
---

Verify the indexer still upholds its four guarantees.

1. Invoke the `indexer-correctness` subagent on `apps/indexer/**`.
2. Run the indexer test suite — idempotent replay, reorg rollback, restart-without-gaps.
3. Report each guarantee as HOLDS or BROKEN with evidence.
4. For any BROKEN guarantee, give the exact failure scenario and the fix.
