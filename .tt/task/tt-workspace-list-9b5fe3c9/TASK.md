---
title: "Implement `tt workspace list` CLI command"
status: TODO
created: 2026-04-03T20:10:17Z
updated: 2026-04-03T20:10:17Z
---
`tt` worktrees (`jj` workspaces) can be created using the `tt checkout --worktree` command.

running `tt workspace list` should show a list of all `jj` workspaces for the current repo and their corresponding `tt` task branches.

`jj` workspaces that do not currently have `tt` task/project bookmarks checked out in their direct ancestry should be shown, but without a task ID

let's discuss output format options (suggest some alternatives)

Allow passing custom workspace options (e.g. `--repo`) via CLI args - see other `workspace` commands for reference.

Add to DESIGN.md
