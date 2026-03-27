---
title: "Ensure implicit bookmark is up-to-date"
status: TODO
created: 2026-03-27T21:55:55Z
updated: 2026-03-27T21:55:55Z
---
Various `tt` commands that accept an optional `<task-id>` as input read their task ID from the current branch's closest task bookmark commit in the current working copy's direct ancestry.

This can lead to counterintuitive behavior when the working copy contains changes that have been committed via `jj commit` but which have not yet advanced the task bookmark to the updated commit, e.g. via `tt task checkin`.

Note that this should only apply to implicit default `<task-id>` arguments: if the task ID is specified explicitly, the command should use the existing behavior of taking the existing bookmark commit as the reference commit.

This has been fixed for `tt task checkin` - see task/tt-task-checkin-bookmark-2823aba1

Analyze the other existing commands and locate which commands exhibit the behavior, create test repositories to verify the behavior, fix the command implementation (making sure to `tt checkpoint`) and verify that the fix works.
