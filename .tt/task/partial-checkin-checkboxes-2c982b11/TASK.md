---
title: "Fix checkbox state for partially-checked-in tasks"
status: DONE
created: 2026-03-15T09:29:32Z
updated: 2026-03-15T09:29:32Z
---
Currently, if a task is checked out then checked back into its parent while still IN-PROGRESS, `tt task show` incorrectly represents the subtask with a `[x]` checkbox, whereas `tt task list` correctly represents it with a `[-]` checkbox.

The task's `status: TODO|IN-PROGRESS|DONE` frontmatter should be source of truth for the checkbox glyph.
