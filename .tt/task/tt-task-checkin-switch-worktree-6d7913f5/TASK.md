---
title: "`tt task checkin` not switching HEAD worktree alias"
status: IN-PROGRESS
created: 2026-04-05T10:07:45Z
updated: 2026-04-05T20:50:02Z
---
When running `tt task checkin --complete` from inside a task's dedicated jj worktree (without `TT_REPO` set), the `HEAD` virtual worktree alias symlink is not updated to point to the parent task's workspace after checkin completes.

**Depends on**: `task/jj-file-show-cwd-sensitivity-8b319182` must land first (the `root:` prefix fix is required before `find_worktrees_for_branch` can be fixed without causing regressions).
