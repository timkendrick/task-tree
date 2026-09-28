---
title: "Prevent deleting worktree if its files are in use"
status: TODO
created: 2026-09-28T14:21:46Z
updated: 2026-09-28T14:21:46Z
---
Currently, `tt worktree delete` forgets the underlying jj workspace and attempts to delete its filesystem contents.

This second part can fail if the filesystem is currently in use (e.g. serving a long-running web server from the workspace directory), leaving the repository in an inconsistent partially-deleted state.

Let's help avoid this scenario by using standard POSIX commands (e.g. `lsof +D <workspace-dir>`) to test whether any files within the workspace are currently in use, aborting the operation with an informative error message that lists the owner processes if so.

This check should be skipped if the `--force` flag is passed.
