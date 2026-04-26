---
title: "Operation ID not being retrieved correctly when committing transactions"
status: IN-PROGRESS
created: 2026-04-26T16:10:24Z
updated: 2026-04-26T16:10:24Z
---
When committing a transaction via the `tt_commit_transaction` helper, `unknown` is being set for the `after_op`.

Investigate why this is happening, write a failing test and come up with a fix that makes the test pass.
