---
title: "Add `--switch` argument to `tt task checkin` CLI command"
status: IN-PROGRESS
description: "Currently when running the check-in command, if the task being checked in is completed, then the worktree working copy will switch to the parent branch. If however the task is not yet completed, the working copy will remain on the child task branch.\n\nLet's provide an optional `--switch` argument that will cause the working copy to switch to the parent branch regardless of whether the task being checked in is completed or not.\n\nThe behavior for checking in completed tasks is unaffected by the presence of this argument."
---
