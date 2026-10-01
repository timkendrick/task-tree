---
title: "Prevent checkpoint message editor when invoked via non-interactive script"
status: IN-PROGRESS
created: 2026-10-01T09:15:10Z
updated: 2026-10-01T09:15:10Z
---
scripts/cli/task/checkpoint

Currently, if no `--message` flag is passed to `tt task checkpoint`, the command launches an interactive editor session to provide the checkin message.

This hangs indefinitely awaiting stdin when the command runs in a non-interactive environment (e.g. invoked via a script).

If the command is invoked in a non-TTY environment and no `--message` flag is provided, exit with an error message explaining that `--message` is required. Do not use the 'suggested' message for single-commit checkpoints.

Update DESIGN.md if necessary
