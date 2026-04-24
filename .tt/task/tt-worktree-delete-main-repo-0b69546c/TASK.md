---
title: "Prevent deleting canonical repo via `tt worktree delete`"
status: IN-PROGRESS
created: 2026-04-24T12:39:46Z
updated: 2026-04-24T12:39:46Z
---
`tt worktree delete` can be used to delete worktrees that have been forked from the canonical repo.

It is unspecified what will happen if this is run within the main repository (i.e. not a jj workspace).

Ensure that running `tt worktree delete` on the main repository exits with an error rather than attempting to delete the main workspace.

Update DESIGN.md to reflect this.
