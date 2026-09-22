---
title: "Add optional `--propagate` flag to `tt task reorder` command"
status: TODO
created: 2026-09-22T16:32:31Z
updated: 2026-09-22T16:32:31Z
---
scripts/cli/task/reorder
scripts/cli/task/delete

Various `tt` commands allow an optional `--propagate` flag to propagate changes applied by the command

We should consider add a `[--propagate]` option to `tt task reorder` (plus also `tt task delete`, and any others where it would make sense).

For consistency, we should also consider whether to support additional `--propagate-…` option flags as seen in scripts/cli/task/checkin and standardize these across all commands that have a propagate phase.

note that propagating `reorder` actions is more likely than most commands to result in merge conflicts, so make sure to carefully plan how conflicts will be avoided / resolved before implementing (this would also ideally apply to all commands that have a propagate phase).

Update DESIGN.md
