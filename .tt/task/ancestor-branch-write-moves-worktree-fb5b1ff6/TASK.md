---
title: "Writes to an ancestor branch move the invoking worktree onto it"
status: DONE
created: 2026-10-01T14:13:44Z
updated: 2026-10-01T14:13:44Z
---
A branch write to an ancestor of the task checked out in the current worktree can move that worktree onto the ancestor branch. The worktree then loses its task: `tt task current` reports the ancestor instead.

## Steps to reproduce

1. Check out a project in the canonical repository.
2. Create a task under the project, and check it out in a worktree:

   ```shell
   tt task checkout <project-id>
   tt task create --slug my-task --title "My task"
   tt task checkout <task-id> --worktree
   ```

3. From inside the task's worktree, write to the project branch:

   ```shell
   cd <task-worktree>
   tt task current                     # task/my-task-...
   tt task context add <project-id> --title notes --slug notes <<< "body"
   tt task current                     # project/... (expected: task/my-task-...)
   ```

4. Inspect the worktree position with `jj log`. The working-copy commit now sits on top of the new project tip. It no longer descends from the task branch.

The bug only triggers when the ancestor branch's tip is still an ancestor of the worktree's working-copy commit. This is the usual state right after `tt task create` or `tt task propagate`. Once the ancestor branch has moved on, later writes to it leave the worktree alone.

## Root cause

`_task__commit_on_branch` (`scripts/cli/lib/task.sh`) builds a bare commit on BRANCH, then reattaches the current worktree. It has two reattach modes:

- Default: `_worktree__reattach_current`. This rebases the working-copy commit onto the new tip whenever the old tip of BRANCH is an ancestor of it.
- `--reattach-on-branch`: `_worktree__reattach_current_on_branch`. This rebases the working-copy commit only when the worktree is checked out on BRANCH.

A task branch forks from its parent's tip. The default mode therefore treats a worktree on a child task as "on the line that moved", and rebases it onto the parent's new commit. The rebased working-copy commit then records the parent's `TASK.md` symlink, so the worktree switches task.

The function comment says to pass `--reattach-on-branch` whenever BRANCH may be an ancestor of the invoking worktree's branch. Only `tt task move` does so. These callers use the default mode, although each can write to an ancestor branch:

- `tt task context add` and `tt task context delete` (any `<task-id>`)
- `tt task edit` (any `<task-id>`)
- `tt task complete` (any `<task-id>`)
- `tt task create` (the write to the parent branch)
- `tt task delete` (the write to the parent branch)
- `tt task reorder` (both writes)

`_worktree__reattach_current` has no other callers. A worktree that descends from BRANCH without being on it should never follow BRANCH. One possible fix is to remove the default mode, and always reattach only a worktree that is on BRANCH. Then remove the `--reattach-on-branch` flag. Confirm this with the user before implementing it.

Possibly related: task/tt-task-create-parent-branch-cfe50365 reports a similar symptom for `tt task create --parent`.

## Regression tests

Add a test for each affected command. Each test writes to an ancestor branch from a child task's worktree, while the ancestor's tip is still an ancestor of the worktree. Check that the worktree stays on its own task and does not move.

## Clean up the test workaround

`scripts/cli/worktree/sync.test.sh` works around this bug. Its `setup_canonical_behind` fixture must leave the canonical repository behind the project branch without moving the task worktree. A `tt` write to the project from the task worktree would drag the worktree onto the project. The fixture therefore advances the project with the `advance_branch_bare` helper, which runs `jj` directly.

Once the bug is fixed:

1. In `setup_canonical_behind`, replace `advance_branch_bare "$PROJ_ID"` with a `tt` write issued from the task worktree:

   ```shell
   run_tt_in_worktree "$TASK_WT" task context add "$PROJ_ID" --title "proj-notes" \
     --slug "proj-notes" <<< "context body" >/dev/null 2>&1 || true
   ```

2. Delete the `advance_branch_bare` helper.
3. Run `scripts/test worktree/sync`.
