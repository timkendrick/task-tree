---
title: "Omit main repository from `find_worktrees_for_branch` output"
status: IN-PROGRESS
created: 2026-09-02T07:50:49Z
updated: 2026-09-02T07:50:50Z
---
Various commands rely on the `find_worktrees_for_branch` helper to locate the corresponding 'working copy' for a given task.

This currently scans all `jj` workspaces, as determined by `list_worktree_entries` output, selecting all worktrees that have the task currently checked out - however this incorrectly lists the main repository as a worktree entry, allowing it to be (wrongly) selected by the `find_worktrees_for_branch` helper.

This should be changed to omit the main repository (compared by resolving symlinks to obtain canonical path).

Note that this issue might disappear if the task/standardize-vcs-operations-d5419005 refactor task eliminates working copy manipulations in favour of 'bare' repository operations
