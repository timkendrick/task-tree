---
title: "Implement `tt task current` CLI command"
status: IN-PROGRESS
description: "this command should list the current task ID.\n\nThis writes the task ID to stdout and exits with 0 (similarly to the `tt task parent` command which lists the parent task ID).\n\nIf there is no current task, i.e. user is currently on a non-task branch, this should exit with 1.\n\nuse the existing library helpers to determine the current task ID.\n\nUpdate the design documentation and the bootstrap implementation."
---
