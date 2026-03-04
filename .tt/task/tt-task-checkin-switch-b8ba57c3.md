---
title: "Add `--switch` argument to `tt task checkin` CLI command"
status: IN-PROGRESS
description: "Currently when running the check-in command, if the task being checked in is completed, then the worktree working copy will switch to the parent branch. If however the task is not yet completed, the working copy will remain on the child task branch.\n\nConceptually, if checking out a task switches to that task's branch, checking in should switch back to the parent branch, so we should switch to the parent branch in all scenarios.\n\nThe behavior for checking in completed tasks is unaffected."
---
