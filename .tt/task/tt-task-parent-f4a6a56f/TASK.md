---
title: "Implement `tt task parent` CLI command"
status: DONE
created: 2026-03-15T09:29:31Z
updated: 2026-03-15T09:29:31Z
---
A `tt task parent` command would be useful to establish task context e.g. when chaining commands together.

Usage: `tt task parent [<task-id]`, defaults to current task.

Outputs just the parent task ID to stdout.

If there is no parent (or multiple parents), exit with a non-zero exit code.

Use existing helper functions to get parent.

This will need to be added to the design document.
