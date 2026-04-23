---
title: "Prevent changing branches on `tt task publish`"
status: DONE
created: 2026-04-23T07:53:42Z
updated: 2026-04-23T07:53:43Z
---
`tt task publish` merges a project branch into an external branch.

The current behavior also switches the current worktree to the external branch - this is not desired; the worktree branch should be unchanged.

Use red/green TDD: Analyze the existing behavior, reproduce the desired behavior in a failing test, then apply the fix and confirm the test passes.

Once the fix is working correctly, make sure DESIGN.md is up to date.
