---
title: "Implement `tt task list` CLI command"
status: TODO
created: 2026-09-25T16:47:06Z
updated: 2026-09-25T16:47:06Z
---
Let's create a `tt task list [--all]` command (aliased to `tt list`) that when invoked shows the names of all 'active' tasks in the current repository, and with the optional `--all` argument additionally includes completed tasks.

We need to determine what criteria we use to determine task existence - e.g. using graph topology to locate project roots and traversing task file subtask records via their canonical task branches to locate all descendant tasks, or if we only care about tasks that have a canonical VCS branch, adapting the existing single-pass algorithm from the `tt task select` command. It might make sense to implement a quick VCS branch check for the 'active' version, with a slow path that introspects task files for the `--all` version.

We should take this opportunity to ensure that whatever mechanism we use to determine the full task list should be shared across all commands that compute this set (`tt task tree` etc).

Pay attention to the time complexity of whatever mechanism we use to determine whether a task exists, as this can quickly blow up.

Whatever approach we use should accommodate the fact that this command will likely gain additional filtering arguments in the future.

The `tt task list` command, combined with an off-the-shelf 'picker' utility application such as fzf, provides a superset of the existing `tt select` behavior.

The `tt select` command (and any associated documentation and environment variables) should therefore be removed as part of this task.

update DESIGN.md accordingly

scripts/cli/task/select
scripts/cli/task/tree
