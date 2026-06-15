---
title: "Fix conflict when propagating checked-out parent to child"
status: TODO
created: 2026-06-15T14:53:14Z
updated: 2026-06-15T14:53:16Z
---
scripts/cli/task/propagate

Consider the following sequence of events:

- parent task is created
- child task is created as a child of parent task
- parent task is checked out
- child task is checked out
- parent task is propagated to child task

This causes a conflict in the root `TASK.md` symlink as both parent and child tasks have modified the symlink since the child was branched from the parent.

The correct behavior in this case is to use the ':theirs' version of the `TASK.md` symlink during the rebase part of the `tt task propagate` rebase operation, as the child is effectively an 'overlay' of the parent version.

This is in some respects the opposite of the scripts/cli/task/checkin command, whose handoff commit deletes the changes to the child branch `TASK.md`
