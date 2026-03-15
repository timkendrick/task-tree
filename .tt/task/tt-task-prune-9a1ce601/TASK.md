---
title: "Implement `tt task prune` CLI command"
status: TODO
created: 2026-03-15T09:34:08Z
updated: 2026-03-24T21:54:58Z
---
When subtasks are checked into their parent task via `tt task checkin`, they have the option of passing the `--delete` flag, which will delete the subtask entirely, leaving no record of the subtask in the parent branch.

If this was not provided, the subtask will remain on the parent branch indefinitely, both in the parent task's `subtask:` frontmatter, and in the subtask's task file.

Let's implement a `tt task prune [--task <task-id>]` command that deletes all completed subtasks from the specified task, defaulting to the current task (both subtask frontmatter and task file).

Ideally, some of the functionality can be reused across this command and the `tt task checkin --delete` command via shared helper functions.

It may also be desirable to delete just the VCS branches for the checked-in children, leaving the task files and subtask frontmatter intact.

Alias the command as `tt prune` and describe it in @DESIGN.md.
