---
title: "Add worktree `teardown` hook"
status: TODO
created: 2026-08-11T13:50:07Z
updated: 2026-08-11T13:50:08Z
---
Currently there exists a `setup` hook which is invoked when a new `worktree` is checked out into the file system.

We should create an equivalent `teardown` hook which is invoked immediately before a worktree is deleted.

scripts/cli/worktree/delete

Update DESIGN.md and add unit tests to reflect the change
