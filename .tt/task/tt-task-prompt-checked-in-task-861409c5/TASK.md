---
title: "Fix `tt task prompt` for a task checked in to its parent"
status: TODO
created: 2026-10-20T12:32:01Z
updated: 2026-10-20T12:32:01Z
---
## Background

`tt task prompt TASK_ID` prints the prompt for a task. It finds the branch to read from with `_task__find_branch`, which applies the "where to read" rule:

- For a task that has not been checked in, it returns the task's own branch.
- For a task merged by a complete checkin (`subtask: [x] TASK_ID` on the parent), it returns the parent branch.

`prompt` then derives the task suffix from that branch rather than from TASK_ID (`scripts/cli/task/prompt`, the explicit task ID case of "Resolve branch and task file"). For a checked-in task the suffix is the parent's, so `prompt` reads the parent's task file and context files.

`tt task show` resolves the same case correctly: it reads at the branch that `_task__find_branch` returns, but it derives the task file path from TASK_ID.

## Reproduction

```
◆  project/proj-…   "Project Title"
│
○  task/c-…         "Child Title"   (checked in with --complete)
```

1. Create a project and a child task.
2. Check out the child, add a checkpoint, and run `tt task checkin --complete`.
3. Run `tt task prompt <child-id>`.

Expected: `task: <child-id>`, the child's title and the child's body.

Actual:

```
---
task: project/proj-…
title: Project Title
---
```

## Defects

All three come from using the canonical branch as the task's identity:

- The task file path comes from the parent's suffix, so the title and body are the parent's.
- The context file paths come from the same suffix (`_path__task_context "$task_suffix" …`), so the context files are the parent's.
- The `task:` header prints `$branch`, the parent ID, not TASK_ID.

The code falls back to TASK_ID only when the branch is neither a task nor a project ID. `_task__find_branch` never returns such a branch.

## Goal

For an explicit TASK_ID, `prompt` reads TASK_ID's task file and context files at the branch that `_task__find_branch` returns, and prints TASK_ID in the `task:` header. Behavior for the current task (no TASK_ID) stays the same.

## Approach

- Derive the suffix and task file path from TASK_ID, as `tt task show` does. Remove the fallback chain.
- Keep a separate variable for the task ID and use it for the `task:` header. Keep `branch` as the read revision.
- Consider reading the title through `_task__read_title` or `_task__read_fields` at the canonical branch. The body still needs the content. See the open design question about body access in the frontmatter helper work.

## Tests

Add to `scripts/cli/task/prompt.test.sh`:

- `tt task prompt <child-id>` for a child checked in with `--complete` prints the child's ID, title and body, not the parent's.
- The same case with a context file on the child prints the child's context, not the parent's.
- `tt task prompt <task-id>` for a task that has not been checked in still reads the task's own branch. Pin this if no test covers it yet.

Run `scripts/test task/prompt`.

## Documentation

No change to `DESIGN.md` or `.agents/skills/tt/SKILL.md` is needed: the fix makes `prompt` match its documented behavior.
