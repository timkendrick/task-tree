---
title: "Implement `tt task revset` CLI command"
status: TODO
created: 2026-05-12T12:04:08Z
updated: 2026-05-12T12:04:08Z
---
Let's add a `tt task revset [--task <task-id>] [--git]` command (aliased as `tt revset`) that returns a range specifying all unmerged commits on the provided task bookmark (defaulting to the current task) - i.e. all the commits on the task branch since the it most recently diverged from its parent branch.

If the `--task` is omitted and the current branch has commits beyond the task bookmark, these trailing commits will be included in the range. If the `--task` is not specified, these trailing commits will not be included.

If the task cannot be located (either because it does not exist or because the command is not run from within a valid `tt` project), the command will exit with an error message rather than trying to recover.

When invoked without the `--git` argument, the range returned will be a `jj` revset (see context7 docs for more info on jj revset syntax).

When invoked with the `--git` argument, it must be a valid `<from>..<to>` git commit range, where `<from>` and `<to>` are determined by extracting the `commit_id` from the given jj change revision (e.g. `jj log --no-graph --revision <rev> --template commit_id`). `<from>` will presumably refer to the merge-base of the parent branch and the child branch, and `<to>` will be the tip of the child branch (or the most recent commit on the current barnch if `--task` is not specified).

Refer to other commands for conventions.

Make sure to add tests and document the command in DESIGN.md.
