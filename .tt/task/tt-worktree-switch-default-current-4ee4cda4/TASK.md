---
title: "Default to current worktree in `tt worktree switch`"
status: DONE
created: 2026-06-14T09:18:00Z
updated: 2026-06-14T09:29:40Z
context: context/implementation-plan-069b78e4
---
Currently, `tt worktree switch <worktree-path>` requires the path of a worktree to switch to.

If the command is invoked with no `<worktree-path>` and the current working directory lies within a `tt` worktree, the `<worktree-path>` should be populated automatically to the current worktree according to the working directory. This should also work when within the default 'canonical repo' workspace.

If the current working directory is not within a `tt` worktree, the command should exit with an error.

The implementation should share DRY VCS helper functions with the `worktree list` command (this may require extracting out any direct VCS interactions within the `list` command into shared functions).

Update DESIGN.md and unit tests to reflect the optional `<worktree-path>`.
