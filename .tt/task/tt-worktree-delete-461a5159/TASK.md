---
title: "Implement `tt worktree delete` CLI command"
status: DONE
created: 2026-04-03T21:18:18Z
updated: 2026-04-03T21:18:19Z
---
Worktrees (`jj` workspaces) can be created via `tt task checkout --worktree`. This creates a new `jj` workspace pointing to the task bookmark.

Users should be able to easily delete worktrees when they are no longer needed.

Add `tt worktree delete <task-id> [--worktree=<worktree-path>] [--force]`, where the `<task-id>` is mapped to the worktree name using the existing logic for locating task worktrees.

The optional `--worktree=<worktree-path>` can be used to disambiguate tasks whose bookmarks are currently checked out in multiple workspaces.

If the task `status` is `DONE`, the `jj` workspace will be forgotten and the worktree files will be deleted.

If the status is not `DONE`, the command is not allowed to proceed, unless the optional `--force` argument was provided.

If the specified worktree is the current working copy worktree, the command will refuse to proceed regardless of the `--force` argument.

Update DESIGN.md
