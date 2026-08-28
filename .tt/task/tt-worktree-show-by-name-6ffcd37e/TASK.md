---
title: "Locate `tt worktree show` target by `--name` rather than `--task`"
status: IN-PROGRESS
created: 2026-08-28T09:56:36Z
updated: 2026-08-28T10:16:04Z
context: context/requirements-cee1558e
context: context/architecture-93395bd2
---
`tt worktree show` currently locates the target workspace via the currently-checked-out `--task` name.

 This does not necessarily uniquely identify the workspace (multiple workspaces can have the same task checked out), and can be confusing if a worktree currently has a different task than its 'canonical' task checked out.

Let's replace the existing `--task <task-id>` argument with a `--name <worktree-name>` argument that must exactly match the canonical name of the workspace as seen in scripts/cli/worktree/list

Update DESIGN.md and all tests

Leave no trace of the previous behavior ever having existed (including comments)
