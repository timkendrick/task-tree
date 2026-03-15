---
title: "Implement `tt task prompt` CLI command"
status: IN-PROGRESS
created: 2026-03-15T12:45:09Z
updated: 2026-03-15T12:45:10Z
---
Add a `tt task prompt [<task-id>]` command that can be used as a self-contained prompt to implement a given task (defaulting to the current task).

The prompt should write the following to stdout:

```
Implement task: <task-title>

<task-body>

---

<task-context>

---

Use the following commands for more context:

<example-commands>

```

...with the relevant content taken from the task in question.

The example commands should be a selection of useful `tt` commands (with minimal one-line description) to help orient the reader within the codebase - e.g. `tt task tree --focus` to see task within the overall hierarchy, `tt task current` / `tt task parent` to get (parent) task name, etc
