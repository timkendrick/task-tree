---
title: "Retain worktree when checking in with `--delete`"
status: TODO
created: 2026-11-13T13:55:12Z
updated: 2026-11-13T13:55:12Z
---
When running `tt task checkin --delete`, if that task currently has a worktree checked out, the worktree is currently deleted unless the `--retain-worktree` flag is specified.

Let's remove this behavior (including the `--force` variant) to avoid accidental file loss, forcing the user to explicitly choose to delete a worktree's file contents.

Update DESIGN.md
