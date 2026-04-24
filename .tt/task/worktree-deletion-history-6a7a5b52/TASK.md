---
title: "Skip final history transaction when deleting worktree working copy"
status: TODO
created: 2026-04-24T07:50:25Z
updated: 2026-04-24T07:50:26Z
---
scripts/cli/worktree/delete

Currently, when deleting a worktree, the final `tt_commit_transaction` attempts to update the history entry log, which fails because the working copy (including the history file) has been deleted.

Given that the history is not persisted to the repository, the transaction commit step can safely be skipped as the history file will already have been deleted entirely.
