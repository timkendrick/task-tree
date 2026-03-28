---
title: "Rename anonymous `<task-id>` arguments"
status: TODO
created: 2026-03-28T08:53:30Z
updated: 2026-03-28T08:54:26Z
---
Various commands accept an anonymous `<task-id>` parameter, while others require a `--task` prefix.

Let's standardize all commands for consistency.

Update all commands and @DESIGN.md that accept anonymous `<task-id>` parameters and replace with prefixed `--task <task-id>` parmeters.
