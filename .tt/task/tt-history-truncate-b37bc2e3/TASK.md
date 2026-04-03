---
title: "Add `tt history truncate` CLI command"
status: TODO
created: 2026-04-03T21:30:24Z
updated: 2026-04-03T21:30:25Z
---
Add a `tt history truncate [-n <num-entries>]` command that truncates the `.tt/history` to only the last `n` lines.

This command should ensure we're not currently mid-transaction.

Update DESIGN.md
