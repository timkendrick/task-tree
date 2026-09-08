---
title: "Implement `tt worktree current` CLI command"
status: TODO
created: 2026-09-08T08:51:21Z
updated: 2026-09-08T08:51:21Z
---
Add a `tt worktree current` command that writes the 'name' of the current worktree (determined by using the existing common helpers to traverse up to the enclosing `.jj` root) to stdout

If there is no enclosing jj root, exit with an error

If the current jj root is the default workspace, exit with an error

See other `scripts/cli/worktree/*` commands for reference

Update DESIGN.md
