---
title: "Implement `tt worktree root` command"
status: DONE
created: 2026-05-12T06:26:31Z
updated: 2026-05-12T06:26:31Z
---
Task worktrees are forked from the canonical repository via `tt checkout --worktree`. This creates a new `jj workspace` within the `tt` virtual workspace folder.

It would be helpful to expose the path to the canonical repository to the user via a `tt worktree root` command (aliased as `tt root`) that prints the canonical repo path to stdout (common helpers should already exist to retrieve the canonical repo path).

Match the CLI style/conventions of other commands, and add tests.

Update DESIGN.md reflect the new command.
