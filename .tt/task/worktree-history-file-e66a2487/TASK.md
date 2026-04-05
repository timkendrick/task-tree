---
title: "Ensure `.tt/history` creation upon worktree checkout"
status: IN-PROGRESS
created: 2026-04-04T09:20:22Z
updated: 2026-04-04T09:20:22Z
---
Currently, `tt workspace init` creates an empty gitignored `.tt/history` file.

When creating a new `jj workspace` via `tt task checkout --worktree`, the history file is not created, leading to errors like the following:

```shell
$ tt checkout --switch --worktree task/absolute-workspace-symlink-path-46b9b1e4
Creating workspace: /Users/tim/Sites/task-tree/task/absolute-workspace-symlink-path-46b9b1e4
Created workspace in "../../task/absolute-workspace-symlink-path-46b9b1e4"
Working copy  (@) now at: xvrtuqps 02732837 (empty) (no description set)
Parent commit (@-)      : vrnqnuom 731df898 task/absolute-workspace-symlink-path-46b9b1e4 | Edit task: Ensure absolute path when updating `.tt/workspace` symlink (task/absolute-workspace-symlink-path-46b9b1e4)
Added 167 files, modified 0 files, removed 0 files
Initializing task: task/absolute-workspace-symlink-path-46b9b1e4
Created TASK.md -> .tt/task/absolute-workspace-symlink-path-46b9b1e4/TASK.md
Working copy  (@) now at: xvrtuqps 33b72a04 Begin task: Ensure absolute path when updating `.tt/workspace` symlink (task/absolute-workspace-symlink-path-46b9b1e4)
Parent commit (@-)      : vrnqnuom 731df898 task/absolute-workspace-symlink-path-46b9b1e4 | Edit task: Ensure absolute path when updating `.tt/workspace` symlink (task/absolute-workspace-symlink-path-46b9b1e4)
Moved 1 bookmarks to xvrtuqps 33b72a04 task/absolute-workspace-symlink-path-46b9b1e4 | Begin task: Ensure absolute path when updating `.tt/workspace` symlink (task/absolute-workspace-symlink-path-46b9b1e4)
Working copy  (@) now at: xnsuyzyq e0d08317 (empty) (no description set)
Parent commit (@-)      : xvrtuqps 33b72a04 task/absolute-workspace-symlink-path-46b9b1e4 | Begin task: Ensure absolute path when updating `.tt/workspace` symlink (task/absolute-workspace-symlink-path-46b9b1e4)
Switching to task/absolute-workspace-symlink-path-46b9b1e4
Updated HEAD -> ./task/absolute-workspace-symlink-path-46b9b1e4
sed: /Users/tim/Sites/task-tree/HEAD/.tt/history: No such file or directory
```

Create a failing test to replicate the scenario before implementing the fix.

Update DESIGN.md with any changed behavior.
