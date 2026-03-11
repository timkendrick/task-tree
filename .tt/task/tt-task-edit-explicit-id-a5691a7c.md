---
title: "Fix `tt task edit <task-id>` (same-branch test)"
status: IN-PROGRESS
description: "When run from a parent task, the `tt task edit <child-task-id>` fails with output similar to the following:\n\n```\ntt task edit task/tt-task-propagate-from-96aca8f7\nWorking copy  (@) now at: lnpozsur 3991e32f (empty) (no description set)\nParent commit (@-)      : qytppykv 4850a766 Edit task: Fix `tt task propagate --from <parent-task>` (task/tt-task-propagate-from-96aca8f7)\nError: Refusing to move bookmark backwards or sideways: task/tt-task-propagate-from-96aca8f7\nHint: Use --allow-backwards to allow it.\n```\n\nIt appears the edit commit is created separately, but maybe the bookmark update fails? more investigation needed"
---
