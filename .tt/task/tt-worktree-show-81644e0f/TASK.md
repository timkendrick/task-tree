---
title: "Rename `tt workspace worktree` CLI command to `tt worktree show`"
status: IN-PROGRESS
created: 2026-04-03T21:21:13Z
updated: 2026-04-06T13:37:40Z
context: context/rename-worktree-plan-b8471e4f
---
Currently, `tt workspace worktree <task-id>` can be used to locate the path of the worktree for a given task.

This should be renamed to `tt worktree show <task-id>` for consistency with other worktree-related commands.

Update DESIGN.md
