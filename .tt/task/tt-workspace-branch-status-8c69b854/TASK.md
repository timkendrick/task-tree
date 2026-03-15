---
title: "Move branch status to `tt workspace` command"
status: TODO
created: 2026-03-15T12:56:14Z
updated: 2026-03-15T12:56:14Z
---
Currently, `tt task show` output exposes `branch:` and `worktree:` frontmatter. These aren't really properties of the task itself, rather where that task lives within the workspace, and therefore should be moved to `tt workspace branch <task-id>` and `tt workspace worktree <worktree-id>` commands respectively.

These commands should just emit the value to stdout so that they can be used as arguments to other commands.
