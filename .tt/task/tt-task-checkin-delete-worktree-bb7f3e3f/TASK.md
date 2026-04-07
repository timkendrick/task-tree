---
title: "`tt task checkin` not removing task worktree"
status: TODO
created: 2026-04-07T07:49:12Z
updated: 2026-04-15T08:10:13Z
---
When running `tt task checkin` on a completed task (`status: DONE`), if that task currently has a worktree checked out, the worktree should be deleted unless the `--retain-worktree` flag is specified.

This appears not to be working.

Confirm the bug via reproducing in a test repo, and write a failing unit test to confirm the behavior.

Once the behavior has been reproduced, present your findings to the user with potential solutions.

Once an approach has been confirmed, implement a fix and update DESIGN.md as appropriate.

Some questions to bear in mind when analyzing this issue:

- What happens when the command is run in the current worktree?
- Which transaction log will the operation write to? Are there multiple transactions at play? (see task/analyze-cross-worktree-transactions-35b7b43d)
- Which task will the worktree 'come to rest' on if the checkin succeeds with `--retain-worktree`? Will this present difficulties for future worktree deletion?
