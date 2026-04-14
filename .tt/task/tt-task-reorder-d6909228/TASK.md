---
title: "Implement `tt task reorder` CLI command"
status: DONE
created: 2026-03-24T22:10:28Z
updated: 2026-04-14T20:57:17Z
context: context/implementation-plan-1599cc6b
---
Implement `tt task reorder` CLI command (aliased as `tt reorder`)

See @DESIGN.md

Additional functionality: when called with no before/after reordering operation, instead 'tidy' the specified task file by reordering the frontmatter:

1. `title`
2. `status`
3. `created`
4. `updated`
5. any `label` entries, retaining their current relative order
5. any `context` entries, retaining their current relative order
6. any `subtask` entries, ordered by their respective task status (first `IN-PROGRESS`, then `TODO`, then `DONE`). Apart from this categorization ordering, subtasks should retain their current relative order (ordering of subtasks should remain stable within the respective status categories).

Update DESIGN.md to reflect this additional functionality.
