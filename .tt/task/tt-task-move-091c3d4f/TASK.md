---
title: "Implement `tt task move` CLI command"
status: DONE
created: 2026-03-15T09:29:31Z
updated: 2026-03-22T21:09:45Z
---
Allow reparenting tasks via `tt task move [--task <task-id>] --parent <parent-task-id>`

Move the specified task (defaults to current task) to the specified parent. Remove the task from the subtasks of the existing parent of the task, add it to the subtasks of the specified parent, and rebase the commit range from the merge base of the old parent bookmark and the task bookmark onto the new parent.

jj's change ID mechanism should ensure that child branches effectively 'come with' the branch that is being moved.

Check for working copy changes before moving the branch, and refuse to move the task if the working copy is not empty (see other commands for examples)

If either the task or the parent doesn't exist, return a non-zero exit code.

If moving a task which is not the current task, capture the current revision before moving the task, and restore that revision after the branch has been moved successfully.

Add a `tt move` alias.

Update DESIGN.md with the command reference.
