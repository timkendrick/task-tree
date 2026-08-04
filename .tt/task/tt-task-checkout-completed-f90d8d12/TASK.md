---
title: "Allow `tt task checkout` of already-completed tasks"
status: DONE
created: 2026-08-03T15:50:05Z
updated: 2026-08-03T20:19:59Z
context: context/implementation-plan-fb143147
---

Currently, `tt task checkout` silently succeeds if the provided task is already completed, checking out the parent branch without changing the task status in the TASK.md frontmatter.

Let's change this such that running `tt task checkout` on an already completed task creates a checkout commit on the task branch that updates the status to `IN-PROGRESS` via the standard checkout flow.

Note that if the task branch already exists, the checkout should not automatically propagate any changes from the parent task to the newly-checked-out child task, rather it should merely add the checkout commit to the already-existing task branch. If the task branch does not already exist, a new branch should be created as per the standard checkout flow.

`tt task create --parent <parent-id>` with an already completed parent task should inherit this behavior: rather than failing with an error (scripts/cli/task/create:359), when run against a completed parent task branch, the command should first check out the parent to reopen it, then add the child task as per usual.

Update DESIGN.md and tests accordingly
