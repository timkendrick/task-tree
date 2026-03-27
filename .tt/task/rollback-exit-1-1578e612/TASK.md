---
title: "Rollback transactions for non-zero exit codes"
status: TODO
created: 2026-03-27T21:59:41Z
updated: 2026-03-27T22:08:40Z
---
Various mutating `tt` commands exit with a non-zero exit code upon encountering failure scenarios.

These aren't caught by the `ERR` trap, leaving the unfinished transaction in a locked state.

Analyze all commands for explicit `exit` statements with a non-zero exit code, and make sure that the pending transaction is automatically rolled back for these explicit error scenarios.
