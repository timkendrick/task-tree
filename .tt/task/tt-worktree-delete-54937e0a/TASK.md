---
title: "Implement `tt worktree delete` CLI command"
status: TODO
created: 2026-04-05T21:03:09Z
updated: 2026-04-05T21:03:10Z
---
Allow deleting previously-checked-out task worktrees via `tt worktree delete --task <task-id> [--worktree=<worktree-path>] [--force]`.

Locate the worktree via the mandatory `<task-id>` argument; with the `--worktree=<worktree-path>` argument used to disambiguate tasks checked out in multiple worktrees. If the `--worktree` argument is provided, it must have the provided `<task-id>` task checked out as its most recent task bookmark.

If the worktree cannot be located (i.e. no worktree exists with the provided task bookmark as its direct ancestor), exit with an error.

If the worktree contains changes in its working copy, or if the worktree contains additional commits more recent than the task bookmark, exit with an error unless the `--force` flag is specified.

Forget the `jj` workspace, then remove all files from the worktree path

Any errors should bubble to be captured by the `ERR` trap

Update DESIGN.md accordingly.
