---
title: "Implement `tt task current` CLI command"
status: DONE
created: 2026-03-15T09:29:32Z
updated: 2026-03-15T09:29:32Z
---
this command should list the current task ID.

This writes the task ID to stdout and exits with 0 (similarly to the `tt task parent` command which lists the parent task ID).

If there is no current task, i.e. user is currently on a non-task branch, this should exit with 1.

use the existing library helpers to determine the current task ID.

Update the design documentation and the bootstrap implementation.
