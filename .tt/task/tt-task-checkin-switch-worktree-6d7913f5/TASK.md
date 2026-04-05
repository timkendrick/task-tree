---
title: "`tt task checkin` not switching HEAD worktree alias"
status: TODO
created: 2026-04-05T10:07:45Z
updated: 2026-04-05T10:07:45Z
---
Currently, when completing a task that has a worktree checked out (by running `tt task checkin --complete` from within the worktree directory), the `HEAD` virtual worktree alias symlink is not updated to point to the parent task.

Additionally, if the `checkin` command (and any associated `--propagate` action) succeeds, the `jj` workspace should be forgotten and the working copy files from the checked-in task worktree should be deleted, unless an optional `--retain-worktree` flag is provided to the `tt task checkin` command.

Create failing unit tests to reproduce these scenarios, apply the fixes, and update DESIGN.md with any relevant changes.
