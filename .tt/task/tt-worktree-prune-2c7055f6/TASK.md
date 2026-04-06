---
title: "Implement `tt worktree prune` CLI command"
status: TODO
created: 2026-04-06T13:51:52Z
updated: 2026-04-06T13:51:53Z
---
Tasks can be checked out into their own `jj` workspaces via `tt task checkout --worktree`.

These workspaces can later be deleted either explicitly via `tt worktree delete`, or implicitly by running `tt task checkin` on a completed task (or providing the `--complete` flag) without specifying the `--retain-worktree` flag.

Stale worktrees can accumulate, without an obvious way to tell whether the worktree is still in use.

Let's implement a `tt worktree prune` command that deletes any worktrees (via the `tt worktree delete` script) whose `status` is `DONE`.

Update DESIGN.md accordingly.
