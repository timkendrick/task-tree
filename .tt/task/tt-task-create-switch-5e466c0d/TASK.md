---
title: "Allow switching worktree via `tt task create --checkout --worktree --switch`"
status: TODO
created: 2026-05-18T15:56:44Z
updated: 2026-05-18T15:56:45Z
---
Currently, `tt task create` allows passing a `--checkout` flag to invoke a follow-up `tt task checkout` command, and an optional `--worktree[=<path>]` flag that is relayed to the `checkout` command.

We should also support a `--switch` flag that is relayed to the `tt task checkout` command. This is only valid when the `--checkout` flag is specified.

Update DESIGN.md to reflect this, and add unit tests.
