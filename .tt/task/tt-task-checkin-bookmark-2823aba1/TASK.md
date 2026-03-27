---
title: "Ensure bookmark is up to date before `tt task checkin`"
status: TODO
created: 2026-03-27T14:49:17Z
updated: 2026-03-27T14:49:17Z
---
Currently, `tt task checkin` merges changes from the given task upstream, however it only merges the commit from the most recent `tt` operation - notably, if there have been `jj` commits since then, those commits will not be merged.

Let's change this so that when run with no `<task-id>` (i.e. on the implicit current task branch), and there are non-empty commits since the bookmarked commit, the command should fail with a message prompting to run `tt task checkpoint` before checking in, or skipping the check by specifying the `<task-id>` explicitly.

I can envisage this being useful across other commands, so make sure it's extracted to a common helper.

Update @DESIGN.md to reflect this change.
