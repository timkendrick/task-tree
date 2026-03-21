---
title: "Implement `tt task delete-context` command"
status: IN-PROGRESS
created: 2026-03-15T10:40:57Z
updated: 2026-03-15T10:40:57Z
---
Context can be added to a task via `tt task add-context`

There should exist a `tt task delete-context <context-id> [...<context-id>] [--task <task-id>]` command that deletes the relevant context file(s) from the specified task (defaulting to current task), removing both the context file and the `context:` entry from the task's frontmatter.
