---
title: "Fix `tt task move` end state"
status: IN-PROGRESS
created: 2026-03-23T08:03:01Z
updated: 2026-03-23T08:03:01Z
---
Currently, when moving an unrelated task by running `tt task move --task <task-id> --parent <new-parent-id>`, the operation succeeds correctly but the HEAD ends up on the `<new-parent-id>` branch rather than the task where we originally started.

This has been confirmed when `<new-parent-id>` is the parent of the current task; the bug could also potentially exist in all cases where `<task-id>` is not the current task.

Make sure that the HEAD is reset properly when reparenting other tasks.
