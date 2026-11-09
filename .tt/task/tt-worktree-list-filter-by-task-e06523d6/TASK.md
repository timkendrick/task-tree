---
title: "Allow filtering `tt worktree list` items by task fields"
status: TODO
created: 2026-11-09T15:42:56Z
updated: 2026-11-09T15:42:56Z
---
`tt worktree list` currently shows which task each worktree has checked-out (if any).

Let's additionally allow `--task <task-id>` and `--task.<key> <value>` filters (e.g. `--task.status DONE`) that filter worktrees by their active task, with the `--task.<key>` filtering using the identical underlying key names / predicates from `tt task list`.

Update DESIGN.md / SKILL.md accordingly.

scripts/cli/worktree/list
scripts/cli/task/list
