---
title: "Resume commit for partially checked-in tasks does not re-point TASK.md"
status: IN-PROGRESS
created: 2026-10-01T17:48:00Z
updated: 2026-10-01T17:48:00Z
---
Currently, if a task is partially checked-in and changes are propagated from the parent branch, a resume commit is created for the task such that the task's new bookmark commit is a direct child of the parent commit.

The problem is that the resume commit itself is empty; this means any continued development on the rebased bookmark inherits the parent task's TASK.md symlink, which now mistakenly attributes the task branch to the parent task.

This is potentially valid for TODO tasks that have not yet had their TASK.md assigned by the initial checkout, however tasks that have been checked out at some point are now left in an invalid state.

As part of the 'rebase' propagate, the rebased 'resume' commit should more correctly be a 'checkout' commit that reinstates the TASK.md symlink to point to the task file, rather than leaving it pointing to parent task file.

Under a 'merge' propagation strategy, the resume commit could be a merge commit of the two branches, potentially with internal resolving logic to ensure the conflicted TASK.md symlink is left pointing to the task's task file and not the parent's task file (I feel like this probably exists somewhere already; investigation needed).

Regardless of the propagation strategy, the resume commit should be named: in the rebase case it should be named as a standard `checkout` commit (that whole code path should be reused if possible); in the merge case maybe the resume commit should have a new action prefix to indicate upstream changes being merged in e.g. `[tt:task/child-task-name-abcd1234:propagate]`.

The 'merge' propagation flow hasn't been well tested, so we need to verify our assumptions around merge commits, which elsewhere in the tool are assumed to indicate (downstream -> upstream) checkin commits rather than (upstream -> downstream) propagate commits. I imagine we would want the first parent of the merge to be the prior task bookmark commit and the second parent to be the parent task bookmark commit, but we should investigate which makes more sense.
