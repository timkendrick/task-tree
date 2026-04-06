---
title: "Clean up task worktree after `tt task checkin` completes"
status: IN-PROGRESS
created: 2026-04-05T20:49:45Z
updated: 2026-04-06T20:08:16Z
context: context/implementation-plan-bf8e904d
---
After a successful `tt task checkin --complete`, if the checked-in task had a dedicated jj worktree, the worktree should be cleaned up automatically: the jj workspace should be forgotten (`jj workspace forget`) and the working copy files deleted from disk. A `--retain-worktree` flag should suppress both operations.

Update DESIGN.md accordingly.


- **Default**: on complete checkin (status DONE), forget the jj workspace and `rm -rf` the worktree directory.
- **`--retain-worktree`**: skip both operations; leave workspace registered and files on disk.
- **Partial checkin** (status IN-PROGRESS): never delete the worktree.


This was originally part of task/tt-task-checkin-switch-worktree-6d7913f5, split out so the HEAD-switch bug and its blocker (`task/jj-file-show-cwd-sensitivity-8b319182`) can be fixed independently.

The existing checkin code already has a broken attempt at cleanup (`scripts/cli/task/checkin`, post-checkin cleanup block) — it uses a broken workspace-name lookup pipeline that pipes path into `jj workspace list` via `xargs`, which doesn't work. Replace it with the correct implementation using `jj workspace list -T 'name ++ ": " ++ root ++ "\n"'` and `canonical_path` path comparison.

**Depends on**:

- `task/tt-worktree-delete-54937e0a` (worktree deletion)
- `task/jj-file-show-cwd-sensitivity-8b319182` (the `root:` prefix fix must land first) and `task/tt-task-checkin-switch-worktree-6d7913f5` (the `find_worktrees_for_branch` fix provides `canonical_path` and the correct workspace listing).


- Worktree deleted after complete checkin (default)
- `--retain-worktree` keeps the worktree
- Partial checkin does NOT delete the worktree

Failing tests for these scenarios have already been written in `scripts/cli/task/checkin.test.sh` as part of task/tt-task-checkin-switch-worktree-6d7913f5.
