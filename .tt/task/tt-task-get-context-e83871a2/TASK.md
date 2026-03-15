---
title: "Implement `tt task get-context` command"
status: TODO
created: 2026-03-15T10:13:37Z
updated: 2026-03-15T10:13:37Z
---
Context can be added to a task via `tt task add-context`

There should exist a `tt task get-context [<context-id> [...<context-id>]] [--task <task-id>]` command that retrieves the relevant context file(s) (defaulting to all context files) from the specified task (defaulting to current task).

Script returns to stdout the raw contents of the specified context files (incuding frontmatter), concatenated if multiple are specified
