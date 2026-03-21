---
title: "Add `--expand-context` flag to `tt task show` command"
status: DONE
created: 2026-03-15T12:53:20Z
updated: 2026-03-15T12:53:20Z
---
Currently, `tt task show` outputs metadata, a listing of context files and subtasks, and task body.

Let's add an optional `tt task show [--expand-context]` flag that additionally writes the content of the context files (separated by `---` separators) after the body section of the `tt task show` output` for a fully-contained task overview.
