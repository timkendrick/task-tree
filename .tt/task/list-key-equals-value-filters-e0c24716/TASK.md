---
title: "Allow `key=value` form in `list` command arguments"
status: TODO
created: 2026-11-13T13:48:07Z
updated: 2026-11-13T13:48:07Z
---
`tt task list` and `tt worktree list` accept `--<key> <value>` filter arguments.

For convenience, these commands should both also accept `--<key>=value` forms (normalized during arg parsing)
