---
title: "Replace propagate/merge with rebase"
status: TODO
created: 2026-10-30T19:02:41Z
updated: 2026-10-30T19:02:41Z
---
Currently, `tt task propagate` can be used to 'broadcast' changes to child branches.

This is very slow in large repositories, and gets messy necessitating rollbacks if any branches contain conflicting changes etc.

Similarly the 'merge' propagate strategy is rarely used and complicates the graph topology model.

Let's change the 'push' model to a deliberate 'pull' strategy, by replacing the existing `tt task propagate` command with `tt task rebase [--task <optional-task>]` which always performs a shallow rebase from the task's immediate parent, removing all trace of the `--merge` propagation strategy and the `--propagate` command arguments.

Update DESIGN.md accordingly
