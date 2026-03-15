---
title: "Fix `--focus` flag behavior for `tt task list`"
status: DONE
created: 2026-03-15T09:29:31Z
updated: 2026-03-15T09:29:31Z
---
When run within a child branch, `tt task list --focus` has been observed incorrectly showing siblings of the parent task. 

This behavior is incorrect: only direct ancestors of the current task should be shown.
