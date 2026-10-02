---
title: "Implementation summary"
created: 2026-10-02T13:14:44Z
updated: 2026-10-02T13:14:44Z
---
# Implementation summary: TASK.md set at task creation via fork commit

## Outcome

Every commit on a task's own line points `TASK.md` at that task's task file. The first commit of a task branch sets the symlink. `tt task checkout` changes only the task status. A worktree on a task that was never checked out reports that task as current.

## Behavior

- Child task with a parent task file (`tt task create`):
  - The parent's `[tt:task:<task-id>:create] <title>` commit does not change. It writes the stub and the `subtask:` entry, and leaves `TASK.md` pointing at the parent.
  - The child branch starts on `[tt:task:<task-id>:fork] <title>`. It points `TASK.md` at the child and writes the same stub. The stub is identical to the parent's copy, so `TASK.md` is the only tree change.
  - The `[tt:task:<task-id>:edit] <title>` commit follows as before.
- Parentless branch (`tt task create --project`, or a child of a bookmark that is not a task or project branch):
  - The branch starts on `[tt:task:<id>:new] <title>`. It writes the stub and points `TASK.md` at it.
  - The `[tt:task:<id>:edit] <title>` commit follows as before.
- Checkout:
  - Checkout of a `TODO` or `DONE` task creates `[tt:task:<task-id>:checkout] <title>`. The commit changes only `status: IN-PROGRESS`.
  - The commit is built bare on the task branch, and the bookmark advances to it. Checkout then creates the worktree or starts the working copy on the new tip.
  - Checkout no longer writes `TASK.md` and no longer logs `Created TASK.md -> ...`.
  - Under `--force`, uncommitted edits stay in the old working-copy commit. The checkout commit never contains them. This also holds when the working copy already sits on the task.
  - Checkout of an `IN-PROGRESS` task creates no commit. `--rebase` and `--merge` do not change.
- Move (`tt task move`):
  - Rebasing the task's range onto the new parent conflicted on `TASK.md`. The fork commit points it at the task, and the new parent's line points it at the new parent.
  - After the move, each moved root takes `TASK.md` from its own pre-move commit. The commits above it inherit the symlink. The invoking worktree is then refreshed.
  - The same restore fixes a root that sits above a partial checkin. Such a root would otherwise inherit `TASK.md -> new parent`.
  - Under the old model, the conflict already happened whenever the task and the new parent had both been checked out.
- Existing branches are not migrated. A `TODO` branch created under the old model still points `TASK.md` at its parent.

## Code changes

- `lib/task.sh`:
  - New `_task__write_symlink ROOT TASK_SUFFIX`: stages `TASK.md -> .tt/task/<suffix>/TASK.md`.
  - New `_task__commit_fork REPO TASK_ID BASE_REV TITLE [-- WRITER_FN ARGS...]`: builds the fork commit as a bare commit. It moves no bookmark and reattaches no worktree. `TITLE` is required, because the stub at creation still carries a placeholder title. The writer is optional, so propagate can build a fork commit with the symlink only.
  - New `_task__start_branch REPO BRANCH REV [--allow-backwards]`: points a new or re-created bookmark at a commit. It replaces `_task__commit_new_branch`.
  - New `_task__restore_symlink REPO SOURCE_REV TARGET_REV`: sets `TASK.md` in one commit from another.
  - Header and comments describe the symlink as planted by the branch's fork commit.
- `lib/repo.sh`, `lib/vcs/jj.sh`: new `_repo__restore_path` / `_jj__restore_path REPO SOURCE_REV TARGET_REV PATH`, a bare path-scoped `jj restore`.
- `lib/frontmatter.sh`: new `_frontmatter__set_status FILE STATUS`. `task/complete` and `task/checkout` both use it.
- `lib/worktree.sh`: the `_worktree__resolve_branch_at` comment names the fork commit.
- `task/create`:
  - The child case builds the fork commit with `_task__commit_fork`, then calls `_task__start_branch`.
  - The parentless cases build the `:new` commit with `_task__commit_detached`, then call `_task__start_branch`.
- `task/checkout`: the status commit goes through `_task__commit_on_branch` before the working copy moves. The in-worktree symlink write and the working-copy commit are removed.
- `task/move`: records the range roots by change ID before the move, then restores `TASK.md` into each moved root.

## Verification

- Full-range discovery: a fork commit has one parent and does not change the task file. It is never a merge candidate or a `path` component. The `task/revset`, `task/diff` and `task/changelog` suites pass.
- Current-task resolution: a worktree on a never-checked-out task now resolves to that task. No command assumed otherwise. The `task/current`, `task/show`, `task/tree` and `worktree` suites pass.
- Rename: the rewrite retargets `TASK.md` wherever it points into the old directory. That includes fork commits.
- Delete and publish: no changes needed.
- Checkin validation: it inspects only paths under `.tt/task/`, so the root `TASK.md` change in the fork commit does not trip it.

## Tests

- `lib/task.test.sh`:
  - `_task__write_symlink`, `_task__commit_fork` (with and without a writer, project IDs, invalid arguments) and `_task__start_branch`.
  - A worktree on a never-checked-out task resolves to that task.
- `lib/vcs/jj.test.sh`: `_jj__restore_path` restores one path, descendants inherit it, and a matching path rewrites nothing.
- `lib/frontmatter.test.sh`: `_frontmatter__set_status` rewrites only the frontmatter field.
- `harness/harness.sh`: new `get_symlink_target_at_rev` and `assert_task_symlink_at_rev`.
- `task/create.test.sh`: the fork commit and its parent, `TASK.md` on the fork, the child bookmark and the parent's create commit, the project `:new` commit, and a child of a non-task bookmark.
- `task/checkout.test.sh`: the checkout commit changes only the task file, only the status changes on first checkout and on reopen, and dirty `--force` (including a working copy parked on the task).
- `task/current.test.sh`: `tt task current` on a never-checked-out task.
- `task/move.test.sh`: the moved line keeps `TASK.md` on the task, for a never-checked-in task and a partially checked-in task. Both tests fail without the restore.
- The full suite passes.

## Documentation

- `DESIGN.md`:
  - Section 4.3 states the invariant, with a diagram.
  - Section 5.4 updates the create, checkout and find entries.
  - Section 6.0 updates the commit table (`:new`, `:fork`, the narrower `:checkout`) and both lifecycle diagrams.
  - Section 6.1 describes the fork and `:new` commits.
  - Section 6.2 covers the status-only checkout commit and current-task resolution before checkout.
  - Section 6.10.1 notes that rename retargets the fork commit's symlink.
  - Section 6.11 adds the move restore step.
  - Section 6.15 explains why fork commits are not classified.
  - Section 9 updates workflow steps 3 and 4.
- `.agents/skills/tt/SKILL.md`: standard workflow steps 1 and 2.
- `ARCHITECTURE.md`: branch-start helpers, the `restore_path` backend operation, and the symlink source in current-task resolution.
