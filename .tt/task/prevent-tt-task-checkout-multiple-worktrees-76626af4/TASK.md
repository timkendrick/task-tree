---
title: "Refuse to checkout multiple worktrees via `tt task checkout`"
status: IN-PROGRESS
created: 2026-04-06T15:28:10Z
updated: 2026-04-06T15:28:11Z
---
Currently, `tt task checkout --worktree[=<worktree-path>]` can be used to check out a copy of the path in a new worktree.

The resulting `jj` workspace will be named after the task (this is how the workspace is identified as belonging to this task).

If a workspace has already been created for the task, and the `--worktree` or `--worktree=<existing-worktree-path>` is provided (where `<existing-worktree-path> is the filesystem path of the task's existing `jj` workspace), the command should silently succeed.

If, however, a `--worktree=<new-worktree-path>` is provided and the `<new-worktree-path>` does not match the filesystem path of the task's existing `jj` workspace, the command should exit with an error code.

Confirm whether this is the existing behavior; if not, come up with a failing test and fix the behavior.

Update DESIGN.md to clarify this behavior.
