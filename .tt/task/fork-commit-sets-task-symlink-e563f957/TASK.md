---
title: "Set TASK.md symlink at task creation via fork commit"
status: IN-PROGRESS
created: 2026-10-02T09:07:18Z
updated: 2026-10-02T13:14:44Z
context: context/implementation-summary-e46ebcd3
---
## Goal

Make the root `TASK.md` symlink agree with the branch topology at all times.

Today `tt task checkout` does two jobs:

- It sets the task status to `IN-PROGRESS`.
- It points `TASK.md` at the task file.

Until a task is first checked out, its branch inherits the parent's `TASK.md`. The symlink then names the parent task, although the commits belong to the child branch.

This task separates the two jobs:

- `tt task create` points `TASK.md` at the new task in the first commit of the new branch.
- `tt task checkout` changes the task status only.

## Invariant

Every commit on a task's own line has `TASK.md` pointing at that task's task file.

The symlink changes only at the two ends of a task branch:

- Entering the branch: the first commit of the branch points `TASK.md` at the task.
- Leaving the branch: the checkin handoff commit points `TASK.md` back at the parent. This already exists and does not change.

```
P line:  ... -- [C:create] (stub + subtask; TASK.md -> P) ------------- [C:checkin] (TASK.md -> P)
                    \                                                   /
         C line:     [C:fork] (TASK.md -> C) -- [C:edit] -- work -- [C:handoff] (TASK.md -> P)
```

## Required changes

### Child task creation (`tt task create`, parent task file found)

- The commit on the parent branch does not change. It stays `[tt:task:<task-id>:create] <title>`. It writes the stub task file and registers the `subtask:` entry.
- The first commit on the child branch changes:
  - Its message becomes `[tt:task:<task-id>:fork] <title>`.
  - It writes the same stub content as today. The stub is byte-identical to the parent's copy, so it adds no tree change.
  - It also writes the `TASK.md` symlink pointing at the child task file.
- The `[tt:task:<task-id>:edit] <title>` commit that follows does not change.

### Parentless branch creation (`tt task create --project`, and children without a parent task file)

- The first commit of the branch changes its message to `[tt:task:<id>:new] <title>`.
- It writes the stub task file, as today.
- It also writes the `TASK.md` symlink pointing at the new task file.
- The `[tt:task:<id>:edit] <title>` commit that follows does not change.

### Shared fork helper

Add a `lib/task.sh` helper that builds the fork commit as a bare commit:

- Inputs: the repository, the task ID, and the base revision to build on.
- Writes the `TASK.md` symlink pointing at the task file.
- Describes the commit as `[tt:task:<task-id>:fork] <title>`. The title comes from the task file.
- Prints the new commit ID.
- Moves no bookmark and reattaches no worktree. Callers decide where the commit lands.

The follow-up propagate task reuses this helper. Design its interface for both callers:

- `tt task create` builds the fork commit as the first commit of a new branch, with the stub file.
- `tt task propagate` builds a fork commit on the parent's tip without a bookmark move.

Choose the exact split between the helper and `_task__commit_new_branch` during implementation.

### Checkout (`tt task checkout`)

- Checkout no longer creates or changes `TASK.md`.
- Checkout of a `TODO` or `DONE` task still creates `[tt:task:<task-id>:checkout] <title>`. The commit changes only `status: IN-PROGRESS` in the task file.
- Build the checkout commit as a bare commit on the task branch, with `_task__commit_on_branch` or an equivalent helper. Then advance the bookmark, and create the worktree or start the working copy on top of the new tip.
- Remove the in-worktree symlink write and the working-copy commit from the checkout command.
- Keep the current behavior for a dirty working copy under `--force`. `jj new` snapshots the uncommitted edits into the old working-copy commit, and the checkout commit never contains them.
- Checkout of an `IN-PROGRESS` task still creates no commit.
- `--rebase` and `--merge` behavior does not change in this task.

### Existing branches

No backwards compatibility is required. Existing `TODO` branches created under the old model keep `TASK.md` pointing at their parent. Do not add migration or self-healing logic.

## Areas to verify

- Full task range discovery (`_task__get_full_range_records`) classifies checkins by the `TASK.md` change in the handoff commit. Confirm that fork commits do not create new `historical`, `child` or `path` components. Run the `tt task revset --all`, `tt task diff` and `tt task changelog` suites.
- Current-task resolution (`_worktree__resolve_branch_at`) reads `TASK.md` from the working-copy commit. A worktree on a never-checked-out task now resolves to that task rather than to its parent. Check `tt task current`, `tt task show`, `tt task tree --focus` and `tt worktree list` for any assumption that a `TODO` branch resolves elsewhere.
- `tt task rename` retargets `TASK.md` wherever it points into the renamed directory. Confirm that it rewrites fork commits correctly.
- `tt task move`, `tt task delete` and `tt task publish` handle `TASK.md` explicitly. Confirm that they still behave correctly.
- Checkin validation inspects the paths an unmerged range changes. Confirm that the `TASK.md` change in the fork commit does not trip it.

## Tests

- `task/create`:
  - The child's first commit is `[tt:task:<task-id>:fork] <title>`, and its parent is the parent's create commit.
  - `TASK.md` points at the child task file on the fork commit and at the child bookmark.
  - The parent's create commit leaves `TASK.md` pointing at the parent.
  - A project's first commit is `[tt:task:<project-id>:new] <title>`, and it points `TASK.md` at the project task file.
- `task/checkout`:
  - The first checkout of a `TODO` task changes only the task file. The commit diff does not include `TASK.md`.
  - Reopening a `DONE` task changes only the status.
  - Update any test that expects checkout to create the symlink, or that expects the `Created TASK.md -> ...` log line.
  - A dirty working copy under `--force` still stays out of the checkout commit.
- Current-task resolution: a worktree placed on a never-checked-out task reports that task as current.
- Run the full suites for `task/create`, `task/checkout`, `task/checkin`, `task/rename`, `task/move`, `task/delete`, `task/publish`, `task/changelog`, `task/revset`, `task/diff`, `task/current`, `task/show`, `task/tree` and `worktree`. See `DEVELOPER.md` for filters and `--parallel`.

## Documentation

- `DESIGN.md`:
  - Section 4.3: state the invariant.
  - Section 6.0: update the commit table with `:fork`, `:new` and the narrower `:checkout`. Update the lifecycle diagrams.
  - Section 6.1: describe the fork commit and the `:new` commit. Remove "The `TASK.md` symlink is created when the task is first checked out".
  - Section 6.2: checkout changes status only. The current-task paragraph no longer depends on checkout.
  - Section 9: update the workflow steps that mention symlink creation at checkout.
  - Search for every other mention of the symlink being created at checkout, and update it.
- `.agents/skills/tt/SKILL.md`: update "creates TASK.md symlink on first checkout" in the standard workflow.
- `ARCHITECTURE.md` and the `lib/task.sh` public surface header: list the new helper.
