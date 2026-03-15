---
title: "Fix `tt task edit <task-id>`"
status: DONE
created: 2026-03-15T09:29:31Z
updated: 2026-03-15T09:29:31Z
---
When run from a parent task, the `tt task edit <child-task-id>` fails with output similar to the following:

```
tt task edit task/tt-task-propagate-from-96aca8f7
Working copy  (@) now at: lnpozsur 3991e32f (empty) (no description set)
Parent commit (@-)      : qytppykv 4850a766 Edit task: Fix `tt task propagate --from <parent-task>` (task/tt-task-propagate-from-96aca8f7)
Error: Refusing to move bookmark backwards or sideways: task/tt-task-propagate-from-96aca8f7
Hint: Use --allow-backwards to allow it.
```

It appears the edit commit is created separately, but maybe the bookmark update fails? more investigation needed
