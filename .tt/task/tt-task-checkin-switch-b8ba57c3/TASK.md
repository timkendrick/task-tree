---
title: "Switch to parent branch after `tt task checkin` CLI command"
status: DONE
created: 2026-03-15T09:29:31Z
updated: 2026-03-15T09:29:31Z
---
Currently when running the check-in command, if the task being checked in is completed, then the worktree working copy will switch to the parent branch. If however the task is not yet completed, the working copy will remain on the child task branch.

Conceptually, if checking out a task switches to that task's branch, checking in should switch back to the parent branch, so we should switch to the parent branch in all scenarios.

The behavior for checking in completed tasks is unaffected.
