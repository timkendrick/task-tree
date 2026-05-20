---
title: "Identify `tt worktree` commands by worktree path"
status: DONE
created: 2026-05-20T16:23:21Z
updated: 2026-05-20T16:23:21Z
---
The various `tt worktree` commands are inconsistent in how they identify the target worktree.

Let's standardize around a convention whereby the jj workspace path is the canonical way to identify a worktree, and is provided via a required positional arg, and commands that locate the worktree(s) for a given task use `--task <task-id>`

Changes:

- `tt worktree delete --task <task-id> [--worktree=<path>]` => `tt worktree delete <worktree-path>`
- `tt worktree switch <task-id>` => `tt worktree switch <worktree-path>`
- `tt worktree show <task-id>` => `tt worktree show --task <task-id>`
- `tt worktree list [--task <task-id>]` => no changes

Update DESIGN.md and unit tests accordingly
