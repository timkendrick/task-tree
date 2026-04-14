---
title: "Add `--reorder` flag to `tt task checkin`"
status: TODO
created: 2026-04-14T21:30:17Z
updated: 2026-04-14T21:30:17Z
---
Add an optional `--reorder` flag to `tt task checkin` that, after the merge commit is written to the parent branch, calls `tt task reorder <parent-id>` in **tidy mode** (no modifier) to canonicalise the parent's subtask frontmatter (sorts subtasks by status: IN-PROGRESS → TODO → DONE).

Implement via red/green/refactor TDD.

Also update `DESIGN.md` to document the new flag.

Note: reordering the task list has a high chance of introducing merge conflicts in checked-out sibling task branches. Do not attempt implementation until this problem has been addressed in a separate ticket (e.g. via a custom merge driver to resolve subtask merge conflicts)
