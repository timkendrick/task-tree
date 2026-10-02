---
title: "Implementation summary"
created: 2026-10-02T13:11:36Z
updated: 2026-10-02T13:11:36Z
---
# Implementation summary: propagate keeps the child's TASK.md

## Outcome

`tt task propagate` keeps every commit on a child's own line pointing `TASK.md` at the child. A worktree on the child reports the child as its current task after `tt worktree sync`. Propagate never creates an empty commit.

## Behavior

Terms, for child `C` and parent `P`:

- Moved commits: `P..C`.
- Root parents: `parents(roots(P..C))`, the commits the moved commits hang off. They are always in `P`'s history.

Cases:

- Up to date and behind: `C` is a strict ancestor of `P`, and `C` is not `DONE`.
  - `C` advances onto a new fork commit `[tt:task:<C-id>:fork] <C title>` on `P`'s tip.
  - The fork commit points `TASK.md` at `C`. The status does not change.
  - The behavior is the same under `--rebase` and `--merge`. The result is linear.
  - A `DONE` child is left where it is.
- Rebase:
  - If any root parent points `TASK.md` at `C`, propagate builds a fork commit on `P`'s tip and moves the moved commits onto it. The status does not matter.
  - Otherwise, the moved commits move onto `P`'s tip, as before. They include `C`'s own fork commit.
  - After a fork commit exists, a later propagate without a new checkin adds no second fork commit. The root parent is then `P`'s old tip, which points at `P`.
- Merge:
  - The merge commit has `C`'s old tip as first parent and `P`'s tip as second parent.
  - It is described as `[tt:task:<P-id>:propagate] <P title>`.
  - `TASK.md` is always restored into the merge from `C`'s old tip. The restore clears a conflict confined to `TASK.md`, and changes nothing when `TASK.md` already matches.
  - The restore runs before the worktree reattach and the bookmark advance. The merge is found again by its change ID.
- Conflicts:
  - Rebase refuses without `--force` when any moved commit, or any commit above `C`'s tip, conflicts. A later moved commit can cancel a conflict an earlier one introduced, so checking the tip alone is not enough.
  - Merge refuses without `--force` when the merge commit conflicts. The check runs after the restore.
- Titles come from the task file at each branch's tip. An unreadable file gives an empty title.
- Dry-run messages:
  - `[dry-run] fork <C> onto <P>`
  - `[dry-run] fork <C> onto <P>, then rebase <C> onto the fork commit`
  - `[dry-run] rebase <C> onto <P>`
  - `[dry-run] merge <P> into <C> as [tt:task:<P>:propagate]`

## Code changes

- `lib/vcs/jj.sh`: new `_jj__list_range_root_parent_commits REPO FROM TO` (`parents(roots(FROM..TO))`).
- `lib/repo.sh`: `_repo__list_range_root_parent_commits` pass-through.
- `lib/task.sh`:
  - New facade `_task__list_unmerged_root_parents REPO BASE_REV TASK_REV`.
  - Removed `_task__commit_resume` and `__task__write_nothing`.
- `task/propagate`:
  - New helpers: `branch_task_file`, `read_title`, `is_done`, `is_attached_to_own_line`, `build_fork_commit`, `propagate_one_fork`.
  - `is_checked_in` is renamed to `is_behind`. `is_partially_checked_in` and `create_resume_commit` are removed.
  - The merge path reuses the existing `_task__restore_symlink`. No new restore wrappers.
  - A failed range move now prints an error instead of exiting silently.
  - The header comment describes the new commits. `--help` does not change.

## Tests

- `lib/vcs/jj.test.sh`: the root-parent query.
- `lib/task.test.sh`:
  - `_task__list_unmerged_root_parents` after a partial checkin.
  - Full-range discovery does not classify a propagate merge.
  - A repeat checkin after `--rebase` propagation is classified as `historical`.
- `task/propagate.test.sh`:
  - Up to date: `IN-PROGRESS` child under rebase and merge, and a `DONE` child.
  - `tt task checkin --propagate` after a partial checkin.
  - Rebase after a partial checkin, then a second propagate with no new checkin.
  - Rebase of a `DONE` child that has an earlier partial checkin.
  - Nested grandchild.
  - Merge after a partial checkin.
  - Labels added to the existing graph-shape tests.
  - Dry-run messages.
  - A synced worktree on the child reports the child.
  - Conflict below the tip: refused without `--force`, accepted with it.
- `task/changelog.test.sh`: a propagate merge does not list the parent's work in the child's changelog.
- `task/checkin.test.sh`: comments updated.
- Suites run with concurrency 4:
  - `task/propagate`, `task/checkin`, `task/checkout`, `task/create`, `task/changelog`, `task/revset`, `task/diff`
  - `worktree`, `lib/vcs`, `lib/task`, `lib/repo`
  - Result: 1749 passed, 0 failed.

## Documentation

- `DESIGN.md`:
  - 4.3: propagate preserves the `TASK.md` invariant.
  - 6.0: new `:propagate` row. Propagate also creates `:fork` commits.
  - 6.8: terms, fork rule, merge label and restore, conflict check, worked examples.
  - 6.14: fork commits and propagate merges are not reported.
  - 6.15: propagate merges are not classified. Removed the `--rebase` cause of unchanged-symlink handoffs.
- `ARCHITECTURE.md`: new row for `list_range_root_parent_commits`.
- `.agents/skills/tt/SKILL.md`: unchanged, by decision.

## Caveats and follow-ups

- If `--force` is retried within the same second as a rolled-back propagate, jj can fail with "Newly-created commit ... already exists". The retry recreates identical rebased commits. This is not caused by this change. The `--force` test runs separately to avoid it.
- `branch_task_file` in `task/propagate` duplicates `_task__full_range_bookmark_task_file` in `lib/task.sh`. One shared facade could replace both.
