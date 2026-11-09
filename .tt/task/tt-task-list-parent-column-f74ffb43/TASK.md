---
title: "Add `parent` column to `tt task list`"
status: TODO
created: 2026-11-09T15:53:59Z
updated: 2026-11-09T15:53:59Z
---
`tt task list` currently allows viewing (and filtering by) various task fields.

Let's add an extra synthetic `parent` field that contains the task ID of the task's parent, or a standard conventional fallback for project tasks that have no parent.

This field can be used for filtering, e.g. `--task.parent task/my-parent-task-abcd1234`
