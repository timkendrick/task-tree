---
title: "Implement `tt task changelog` CLI command"
status: TODO
created: 2026-08-21T09:33:38Z
updated: 2026-08-21T09:33:39Z
---
Add a new `tt task changelog [--task <task-id>] [--since <revision>]` command (alias `tt changelog`) that shows all work checked into the given `<task-id>` branch (defaulting to the current task), either as subtask checkins or as checkpoints directly to the task branch, since the most recent common ancestor of the tip of the task branch and `<revision>` (defaulting to the most recent common ancestor of the task branch and its parent branch), a.k.a. the 'reference commit'.

If the task or target revision cannot be located, or there is no common ancestor, exit with an error.

If there were no subtask checkins or checkpoints made directly to the task branch, exit successfully with no output written to stdout.

The task branch checkpoint commits are the direct ancestors of the task bookmark whose commit message starts with `[tt:task:<task-id>:checkpoint] `.

Update DESIGN.md as appropriate.

## Output syntax

The output should contain the following sections, with consecutive sections separated by 2 newlines:

- [If any subtasks have been checked into the task branch in since the reference commit] Tree of tasks showing task ID and resolved task title (flagging any 'partial' tasks whose status is still IN-PROGRESS), resolving task title and status from the task branch's checked-in version of the task (*not* the task's canonical branch, which may have moved on since checkin)
- [If any checkpoints made directly to the task branch in since the reference commit] Flat list of checkpoint descriptions, each of which has git commit 8-char sha (use the immutable Git commit ID, not the mutable jj change ID) followed by first line of the checkpoint commit message (omitting `[tt:task:<task-id>:checkpoint] ` prefix)

Section separators should 'collapse' (i.e. omitted conditional sections should not be surrounded by newlines).

All task IDs and git commit IDs should be surrounded by backticks. In-progress tasks should be flagged with an `[IN-PROGRESS]` marker.

### Example

```
- `task/foo-abc123` - Foo task
  - `task/foo-subtask-1-abc123` - Foo subtask 1
  - `task/foo-subtask-2-abc123` - Foo subtask 1
- `task/bar-abc123` - Bar task
  - `task/bar-subtask-1-abc123` - Bar subtask 1
    - `task/bar-subtask-1-subtask-1-abc123` [IN-PROGRESS] - Bar subtask 1.1
- `task/baz-abc123` - Baz task

- `abcd1234` Regenerate types
- `cdef5678` Fix deployment issues
```

Related commands:

scripts/cli/task/revset
