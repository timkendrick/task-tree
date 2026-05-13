---
title: "Prevent `tt task checkin` of completed files from incorrectly switching worktree"
status: IN-PROGRESS
created: 2026-05-13T20:12:33Z
updated: 2026-05-13T20:18:32Z
context: context/implementation-plan-prevent-checkin-head-switch-42873dc2
---
Currently, when checking a completed task into its parent task via `tt task checkin --complete`, the `HEAD` worktree symlink is updated to match the parent task.

This is correct behavior *iff* the `HEAD` worktree symlink currently points to the task being checked in. If the `HEAD` currently points to a different task, it should be left untouched.

Make sure this is clear in DESIGN.md, add a failing test to reproduce the current (incorrect) behavior, and then fix the bug.
