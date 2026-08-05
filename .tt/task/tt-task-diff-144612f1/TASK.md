---
title: "Implement `tt task diff` CLI command"
status: DONE
created: 2026-08-05T15:51:32Z
updated: 2026-08-05T15:56:35Z
context: context/implementation-plan-2b4273bb
context: context/handoff-strip-tt-metadata-file-contents-from-tt-task-diff-output-521a5cf4
subtask: [x] task/strip-tt-task-diff-metadata-contents-56f3485f
subtask: [x] task/tt-task-diff-output-format-4445d329
---
Let's create a new `tt task diff` command (aliased to `tt diff`), which shows the diff of the current branch's revision set since diverging from its parent branch.

Output can be relayed directly from the underlying VCS command (e.g. `jj diff`) - use context7 for API reference.

Update DESIGN.md and SKILL.md to reflect the new command.

See scripts/cli/task/revset for a similar existing command
