---
title: "Show current worktree by default in `tt worktree show`"
status: TODO
created: 2026-09-08T08:44:22Z
updated: 2026-09-08T08:44:22Z
---
The `tt worktree show` command specifies a mandatory `--name <worktree-path>` command that determines which worktree's path to show.

Let's make this argument optional, defaulting to the current worktree (determined by using the existing common helpers to traverse up to the enclosing `.jj` root)

If there is no enclosing jj root, exit with an error

If the current jj root is the default workspace, exit with an error

See other `scripts/cli/worktree/*` commands for reference

Update DESIGN.md
