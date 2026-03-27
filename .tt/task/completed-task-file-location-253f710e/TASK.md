---
title: "Fix completed task file location"
status: TODO
created: 2026-03-27T21:48:05Z
updated: 2026-03-27T21:48:05Z
---
Various `tt` commands that accept a `<task-id>` as input locate the task branch for the given task, and use the task branch name as the task ID when locating the task file. For completed tasks that have been checked into their parent branches, this incorrectly identifies the parent task ID rather than the specified task ID.

This has been fixed for `tt task show` - see task/tt-task-show-completed-0db3cf3d

Analyze the other existing commands and locate which commands exhibit the behavior, create test repositories to verify the behavior, fix the command implementation (making sure to `tt checkpoint`) and verify that the fix works.
