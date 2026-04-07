---
title: "Analyze cross-worktree transactions"
status: TODO
created: 2026-04-07T10:57:11Z
updated: 2026-04-07T10:57:12Z
---
Various commands (e.g. `tt task checkout --switch`, `tt task checkin --complete`) have follow-on actions that switch worktreesas part of the command.

If the command is triggered from within the virtual HEAD symlink directory, this has potential to cause inconsistency in the `.tt/history` transaction log, as the working directory starts off in one physical filesystem directory and ends up in a different physical directory as a result of the symlink update, so there is a chance that the command writes the transaction's start operation ID in one `.tt/history` file and the end operation ID in another.

Analyze all existing commands that switch workspace, and ask questions to determine what the correct behavior should be (either completing the transaction before the switch, resolving the physical path of the history file so that only the original worktree is updated, etc).

Ensure all prescribed behavior is recorded in DESIGN.md as part of the task.
