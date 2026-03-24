---
title: "Implement `tt task publish` CLI command"
status: DONE
created: 2026-03-24T07:39:09Z
updated: 2026-03-24T07:39:10Z
---
Currently, `tt task checkin` behaves slightly different when checking a task into its parent vs publishing a project to an external branch.

Let's split this command into the existing `tt task checkin` for dealing with tasks with parents, vs `tt task publish` for dealing with parentless tasks.

Analyze the two code paths and determine behavior for the different commands. The `publish` command should not switch branches once complete.

Update @DESIGN.md and extract the two separate commands. Each should check that it's on the right kind of branch before proceeding.
