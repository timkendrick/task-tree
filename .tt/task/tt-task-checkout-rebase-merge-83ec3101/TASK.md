---
title: "Add `--rebase` / `--merge` arguments to `tt task checkout`"
status: IN-PROGRESS
created: 2026-08-03T16:25:08Z
updated: 2026-08-03T16:25:09Z
---
Currently, checking out a task via `tt task checkout` does not pull any changes from the parent task.

Let's add optional (mutually-exclusive) `--rebase` / `--merge` options that, when specified, first pulls any changes from the parent task to the child task via the standard propagate command (scripts/cli/task/propagate) before checking out the child branch (see the equivalent `--rebase` / `--merge` options in scripts/cli/task/checkin).

Update DESIGN.md and tests accordingly.
