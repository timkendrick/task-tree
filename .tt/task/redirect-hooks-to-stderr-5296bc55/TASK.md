---
title: "Redirect hook script output to stderr"
status: IN-PROGRESS
created: 2026-09-01T09:47:34Z
updated: 2026-09-01T09:47:35Z
---
Currently, the output of hook scripts is redirected directly to stdio of the main `tt` process.

This causes problems when attempting to chain commands (e.g. `cd "$(tt task checkout --worktree "$(tt create)")" fails if there exists a `.tt/hooks/setup` which prints to stdout)

Let's fix this by ensuring that all hooks' stdout is redirected to stderr
