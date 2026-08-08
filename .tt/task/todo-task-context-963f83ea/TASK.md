---
title: "Allow adding context to TODO tasks"
status: DONE
created: 2026-08-08T08:20:21Z
updated: 2026-08-08T08:20:22Z
---
Currently, the `tt task context add` command will only append context files to already-checked-out tasks.

Let's relax this description, allowing the user to add context to tasks which have not yet been checked out (similar to how task files can be edited before the task is checked out).

The same behavior should be applied to any other task context editing commands.

Update DESIGN.md and update tests to exercise this path.

scripts/cli/task/context/add
