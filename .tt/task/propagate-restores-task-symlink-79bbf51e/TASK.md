---
title: "Propagate restores the child's TASK.md symlink"
status: DONE
created: 2026-10-02T09:07:22Z
updated: 2026-10-02T13:11:36Z
context: context/implementation-summary-b8ee9352
---
## Goal

Make `tt task propagate` keep each child branch's `TASK.md` pointing at the child task.

This task depends on the fork commit task. That task establishes this invariant: every commit on a task's own line has `TASK.md` pointing at that task. Propagate must preserve it.

## Problem

Propagate updates child `C` onto the tip of parent `P`. In three situations `C` ends up with `TASK.md` pointing at `P`:

- Up to date: `C`'s whole history is already in `P`'s history, typically after a partial checkin. Propagate creates an empty, undescribed "resume" commit on `P`'s tip. The commit inherits `TASK.md -> P`.
- Rebase after a partial checkin: the commits that moved do not touch `TASK.md`. On `P`'s tip they inherit `TASK.md -> P`.
- Merge after a partial checkin: the merge base has `TASK.md -> C`, and `P`'s side changed it to `P` in the handoff. jj resolves the merge to `TASK.md -> P` without a conflict.

Current-task resolution reads `TASK.md` from the working-copy commit. After `tt worktree sync`, a worktree on `C` therefore reports `P` as the current task.

The trailing resume call after a rebase or a merge does nothing today. Its destination defaults to the child's own tip, so `_task__commit_resume` returns early.

## Definitions

- Moved commits: the commits in `C`'s history that are not in `P`'s history (`P..C`). Rebase moves these commits.
- Attachment commits: the parents of the roots of the moved commits (`parents(roots(P..C))`). They are always in `P`'s history.

## Fork rule

`C` needs a new fork commit in two cases:

- Up to date: `C` is a strict ancestor of `P`, and `C` is not `DONE`. This is the existing trigger, and it does not change.
- Rebase: any attachment commit has `TASK.md` pointing at `C`. An attachment commit like this is a `C` commit that an earlier checkin brought into `P`.

When the attachment commits point at `P`, the moved commits include `C`'s own fork commit. The rebase replays that commit, which keeps `TASK.md -> C`.

### Worked examples

Never checked in. The attachment commit points at `P`, so no fork commit is needed:

```
o  W1                  <- C    TASK.md -> C
o  F1 [C:fork]                 TASK.md -> C
| o  Pwork             <- P    TASK.md -> P
|/
o  P1 [C:create]               TASK.md -> P   (attachment commit)
```

Result: `Pwork -- F1 -- W1`. This is a plain rebase.

Partially checked in, then more work. The attachment commit points at `C`, so a fork commit goes underneath:

```
o  W2                  <- C    TASK.md -> C
| o  Pwork             <- P    TASK.md -> P
| o    Pci1 [C:checkin]        TASK.md -> P
| |\
| | o  Hc1 [C:handoff]         TASK.md -> P
|/ /
o |  W1                        TASK.md -> C   (attachment commit, already in P)
o |  F1 [C:fork]               TASK.md -> C
|/
o  P0
```

Result: `Pwork -- F2 [C:fork] -- W2`.

Nested: grandchild `G` was checked into `C` after `C`'s partial checkin. The attachment commit is `W1`, which points at `C`, so a fork commit goes underneath. A plain rebase onto `Pwork` conflicts on `TASK.md` in `G`'s fork commit. With `F2` underneath, the rebase is clean. A scratch-repository probe confirmed both outcomes.

After a fork commit `F2` exists and `P` advances again without a new checkin, the only root is `F2`. Its attachment commit is `P`'s old tip, which points at `P`. No new fork commit is created.

## Required changes

### Up to date

- Keep the trigger: `C` is a strict ancestor of `P`, and `C` is not `DONE`.
- Build a fork commit on `P`'s tip with the shared fork helper from the fork commit task.
  - Message: `[tt:task:<C-id>:fork] <C title>`.
  - Content: `TASK.md` points at `C`'s task file. The status does not change.
- Reattach the invoking worktree only when it sits on `C` (`_worktree__reattach_current`). Then advance `C`'s bookmark and report out-of-sync worktrees.
- Apply this behavior under both `--rebase` and `--merge`. The result is linear under both strategies.

### Rebase

- Before rebasing, list the attachment commits and read `TASK.md` at each one.
- If any attachment commit points at `C`:
  - Build a fork commit on `P`'s tip without moving any bookmark.
  - Move the moved commits onto the fork commit with `_task__move_unmerged_range`, using `P` as the base. `C`'s bookmark follows.
- Otherwise, move the moved commits onto `P`'s tip, as today.
- Run the conflict check after the move. Keep the `--force` behavior.
- Do not add a trailing commit.

### Merge

- Create the merge commit with `C`'s old tip as the first parent and `P`'s tip as the second parent. The parent order does not change.
- Describe every propagate merge as `[tt:task:<P-id>:propagate] <P title>`. The ID is the incoming task, as in checkin merges.
- Always restore `TASK.md` from `C`'s old tip into the merge:
  ```
  jj --ignore-working-copy restore --from <C-old-tip> --into <merge> 'root-file:"TASK.md"'
  ```
  - The restore prints `Nothing changed.` and rewrites nothing when `TASK.md` already matches.
  - It also clears a conflict on `TASK.md`.
  - Add a `_jj__` wrapper for path-scoped restore, a `_repo__` pass-through and a `_task__` facade.
- Run the restore before the worktree reattach and the bookmark advance, while the merge has no descendants.
- The restore rewrites the merge commit. Resolve the merge's new commit ID through its change ID.
- Run the conflict check after the restore, so a conflict confined to `TASK.md` does not block the merge.
- Do not add a trailing commit.

### Removal and cleanup

- Remove `create_resume_commit`, `_task__commit_resume` and `__task__write_nothing`, and their header listings.
- `is_partially_checked_in` actually tests that `C` is not `DONE` and that `P` has commits `C` lacks. Rename it to match what it checks, or fold it into the up-to-date trigger.
- Update the `--dry-run` messages to name the fork commit and the merge.

## Areas to verify

- Changelog follows first parents and treats only `[tt:task:<id>:checkin]` merges as checkins. Confirm that propagate merges and fork commits do not appear as checkins or checkpoints in `C`'s changelog.
- Full task range discovery classifies two-parent merges by the `TASK.md` change in the second parent. The second parent of a propagate merge is `P`'s bookmark tip, and that tip is never a handoff commit. Confirm with tests that propagate merges are not classified as `historical` or `child` components.
- `jj restore` with `--into` rewrites the target commit. Confirm that no worktree or bookmark refers to the old merge commit ID afterwards.

## Tests

Add these to `scripts/cli/task/propagate.test.sh` unless noted otherwise:

- Up to date, `IN-PROGRESS` child, rebase strategy:
  - `C`'s tip is `[tt:task:<C-id>:fork] <C title>`, and its parent is `P`'s tip.
  - `TASK.md` points at `C`.
  - The status does not change.
- Up to date, merge strategy: the same linear result.
- Up to date, `DONE` child: no commit is created, and the bookmark does not move.
- `tt task checkin --propagate` after a partial checkin creates the fork commit on the checked-in child immediately.
- Rebase after a partial checkin with more work:
  - The fork commit is the root of the range, and it sits on `P`'s tip.
  - Every commit on `C`'s line points `TASK.md` at `C`.
- Rebase of a never-checked-in child: no fork commit is added, and the range length does not change. Keep `test_task_propagate__rebase_graph_shape`.
- Rebase after a previous fork commit, with no new checkin: no second fork commit is added.
- Rebase of a `DONE` child that has an earlier partial checkin: a fork commit is added, and the status stays `DONE`.
- Nested grandchild (the probe scenario): no conflicts. `TASK.md` points at `C` on `C`'s line and at `G` on `G`'s commits.
- Merge after a partial checkin:
  - The result is a single merge described as `[tt:task:<P-id>:propagate] <P title>`.
  - The first parent is `C`'s old tip, and the second parent is `P`'s tip.
  - `TASK.md` points at `C`. There are no conflicts and no extra commit.
- Merge of a never-checked-in child: the label is added. Extend `test_task_propagate__merge_graph_shape`.
- End to end: after propagate and `tt worktree sync`, `tt task current` in `C`'s worktree prints `C`.
- `task/changelog`: after a merge propagation, `C`'s changelog does not list `P`'s work.
- Update the comment in `scripts/cli/task/checkin.test.sh` that mentions resume commits.
- Run the `task/propagate`, `task/checkin`, `task/checkout`, `task/create`, `task/changelog`, `task/revset`, `task/diff` and `worktree` suites.

## Documentation

- `DESIGN.md`:
  - Section 6.0: add `[tt:task:<P-id>:propagate]` to the commit table, and note that propagate also creates `:fork` commits.
  - Section 6.8: describe the up-to-date fork commit, the fork rule for rebase, the merge label and the `TASK.md` restore. Include the worked examples. State that propagate never creates empty commits.
  - Section 6.14: confirm that the description of how merge commits are read still holds.
- `.agents/skills/tt/SKILL.md`: update the `tt task propagate` section if any user-facing behavior description changes.
- `ARCHITECTURE.md` and the module headers of `lib/task.sh`, `lib/repo.sh` and `lib/vcs/jj.sh`: add the restore wrapper, and remove the resume helpers.
