---
title: "Implement `tt task list-context` CLI command"
status: TODO
created: 2026-03-21T09:04:51Z
updated: 2026-03-21T09:04:52Z
---
Add a `tt task list-context [<task-id>]` CLI command that lists the context IDs for the provided task (defaulting to current task) to stdout:

```shell
$ tt task list-context task/foo-12345678
context/bar-87654321
context/baz-qux-abcdef01
```

Support the same flags as `tt task get-context` (with the exception of the `<context-id>` argument)

Update @DESIGN.md
