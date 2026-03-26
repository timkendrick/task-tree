---
title: "Move task directory in `tt task move`"
status: TODO
created: 2026-03-26T08:37:39Z
updated: 2026-03-26T08:37:39Z
---
Currently, `tt task move` only copies the `TASK.md` file from the old branch `jj` history, silently succeeding if the task file was not found in the history.

This needs to change to copy the whole directory, and to fail the overall operation if the copy fails, rather than silently succeeding.
