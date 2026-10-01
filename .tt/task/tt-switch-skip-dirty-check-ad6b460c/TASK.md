---
title: "Skip outgoing branch dirty check in `tt switch`"
status: DONE
created: 2026-10-01T08:22:08Z
updated: 2026-10-01T08:22:08Z
---
Currently, `tt worktree switch` aborts the operation if the outgoing worktree contains changes.

Given that the switch is doesn't mutate the repository state at all, this just causes inconvenience for no additional safety.

Let's remove the check (and the related `--force` flag) entirely and update DESIGN.md / SKILL.md accordingly.
