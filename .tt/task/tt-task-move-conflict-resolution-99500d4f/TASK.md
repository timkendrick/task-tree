---
title: "Auto-resolve TASK.md conflicts after tt task move rebase"
status: IN-PROGRESS
created: 2026-03-22T21:35:26Z
updated: 2026-03-22T21:35:26Z
---
When `tt task move` rebases a task's unmerged commit range onto a new parent, the rebase can produce a conflict in the task's TASK.md file. This happens because the task's TASK.md on its own branch (e.g. with `status: IN-PROGRESS` and `subtask:` entries) diverges from the new parent's version of that file (which the new parent doesn't have at all, or has a different version of).

This is the same class of conflict that `tt task propagate` can encounter. The correct resolution for TASK.md conflicts after a move is to keep the task branch's own TASK.md (since the task file belongs to the task being moved).

## Expected behaviour

After `tt task move` performs the rebase, detect any conflicts in the moved task's TASK.md and auto-resolve them by keeping the task's own version of the file (the "ours" side of the conflict). This is always correct because:

1. The task's TASK.md belongs to the task — the new parent's version of that file (if any) is irrelevant.
2. This mirrors how `tt task checkin` resolves the TASK.md conflict at merge time (via the handoff commit).

## Implementation notes

After the `jj rebase` step in `tt task move`, check whether the moved task bookmark has any conflicts (`has_conflicts`). If so:

1. Create a new WC on the task bookmark tip.
2. Restore the task's TASK.md from its pre-rebase version (i.e. from the task bookmark's own branch, before the rebase introduced the conflict) using `jj restore --from <task_id> -- <task_file>` or by writing it directly.
3. Commit: `Resolve conflicts: <title> (<task-id>)`.
4. Advance the task bookmark.

Alternatively, investigate whether `jj rebase` supports a conflict resolution strategy that would avoid the conflict entirely.
