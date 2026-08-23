---
description: Security-review the Solidity workspace and run the full test suite
---

Audit the contracts workspace.

1. Invoke the `solidity-auditor` subagent on `contracts/src/**` and `contracts/script/**`.
2. Run `forge test -vvv`, then `forge test --match-path 'test/invariant/*' -vvv`.
3. Run `forge coverage` and report uncovered branches in `src/modules/`.
4. Summarize findings by severity. For each Critical or High, propose a concrete fix and the
   missing test that would have caught it.
5. Do not push if any Critical or High finding is open.
