---
title: "Return worktree path in `tt task checkout` command output"
status: IN-PROGRESS
created: 2026-06-14T10:06:49Z
updated: 2026-06-14T10:12:35Z
context: context/implementation-plan-802ca86a
---
Currently, `tt task checkout` allows checking out a task either in the current worktree or in a separate worktree via the `--worktree` flag.

Either way, the path of the `tt` worktree that is checked out should be logged to stdout at the end of the script to allow piping into other commands.

All other `tt task checkout` output (including delegated external commands) should therefore be written to stderr, not stdout.

Update DESIGN.md and unit tests accordingly.
