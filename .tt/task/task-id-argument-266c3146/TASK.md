---
title: "Support `[<task-id>]` positional argument across multiple commands"
status: DONE
created: 2026-03-15T09:29:32Z
updated: 2026-03-15T09:29:32Z
---
Currently the `complete` command allows an optional task ID to be specified as an argument.

This behavior should be carried across to other commands that would benefit from a task argument:

- `tt task checkin`
- `tt task add-context`
- `tt task describe`
