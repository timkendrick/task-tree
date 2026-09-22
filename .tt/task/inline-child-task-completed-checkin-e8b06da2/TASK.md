---
title: "Consider updating worktree branch to parent when checking-in completed inline child task"
status: TODO
created: 2026-09-22T11:15:28Z
updated: 2026-09-22T11:15:28Z
---
A common workflow is to check out an ad-hoc 'inline' subtask into the current task's worktree via `tt task checkout $(tt create --parent $(tt current))`, then work on the subtask, then `tt task checkin --complete`, all without changing directory.

The checkin leaves the current worktree on the subtask, which is conceptually simple (checkin doesn't change worktree branches) but feels counterintuitive when a user is 'completing' a task.

Let's consider adding a convenience feature that checks out the parent task on the target worktree in this scenario, and whether that has any negative ramifications on various edge cases.

Proposed behavior:

if the following conditions are true:

- task being checked in is `status: DONE` (or `--complete` flag has been passed to `tt task checkin`)
- target worktree is the canonical worktree for the immediate parent of the task being checked in

…the target worktree has its branch tip switched to the parent branch (i.e. a new child commit of the parent bookmark, which now sits at the `checkin` commit)
