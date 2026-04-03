---
title: "Add `--squash` argument to `tt task checkpoint` CLI command"
status: TODO
created: 2026-04-03T08:42:21Z
updated: 2026-04-03T08:42:21Z
---
`tt task checkpoint` can be used to register an atomic checkpoint in the VCS history, and is the primary mechanism of 'locking in' changes that have been made to a task branch's working copy by updating the task bookmark.

Checkpoint commits often comprise a number of preceding `jj` commits between the prior bookmark state and the checkpoint commit

When invoking `tt task checkpoint --squash`, the command should squash the `jj commit` range between the most recent bookmark state for the given task and the current working copy, combining everything into a single commit (collapsing any intermediate commits) such that the new checkpoint commit is stacked directly after the prior bookmark commit.

Update DESIGN.md to reflect this new behavior.
