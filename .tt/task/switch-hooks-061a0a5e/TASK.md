---
title: "Extract `pre-switch` / `post-switch` hooks"
status: TODO
created: 2026-08-11T13:56:23Z
updated: 2026-08-11T13:56:24Z
---
Currently, the `pre-checkout` and `post-checkout` hooks are triggered by the `worktree switch` command.

It can sometimes be useful to delineate between checking out a branch versus switching to an existing already-checked-out branch.

Let's update the `tt worktree switch` command to instead trigger new `pre-switch` and `post-switch` hooks so that they more actively model the operation taking place.

The hook should receive the relevant environment variables for the switch operation.

Update DESIGN.md and unit tests appropriately.

scripts/cli/worktree/switch
scripts/cli/task/checkout
