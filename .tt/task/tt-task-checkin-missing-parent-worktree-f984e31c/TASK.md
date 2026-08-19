---
title: "`tt task checkin --complete` leaves dangling `HEAD` symlink when parent task not checked out"
status: IN-PROGRESS
created: 2026-08-19T13:11:17Z
updated: 2026-08-19T13:11:17Z
---
scripts/cli/task/checkin
scripts/cli/worktree/switch
scripts/cli/workspace/repo

When checking in a completed task (or running `tt task checkin --complete`) when the `HEAD` worktree is set to the completed task's worktree, the `HEAD` symlink is automatically updated to point to the parent task's worktree.

In the scenario where the child task is checked out to its own worktree but the parent task is not, the auto-switch operation leaves the repository in an inconsistent state, with the `HEAD` symlink pointing to a directory that doesn't exist.

Rather than relying on implicit behavior, let's make the work tree switch explicit by determining whether to switch worktrees based on a `tt task checkin --switch` flag. If the flag is not specified, the worktree switch is skipped.

If the `--switch` flag is specified, and the parent task is not checked out anywhere, to avoid dangling symlinks the `HEAD` symlink should instead be pointed to the canonical `tt workspace repo` root directory.

Update DESIGN.md and tests appropriately.
