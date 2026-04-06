---
title: "Delete `tt workspace branch` command"
status: DONE
created: 2026-04-03T21:54:14Z
updated: 2026-04-06T16:49:22Z
context: context/implementation-plan-8341d0b1
---
The `tt workspace branch <task-id>` effectively just echoes back the provided `<task-id>` (having validated it).

This provides no real value beyond e.g. `tt task current` and should therefore be removed

Update DESIGN.md appropriately
