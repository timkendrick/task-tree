---
title: "Allow parent task propagation to checked-in children"
status: DONE
created: 2026-03-15T09:29:31Z
updated: 2026-03-15T09:29:31Z
---
Currently the propagate command does not propagate updates to any child tasks that have already been checked into the parent task branch.

This is the expected behavior for tasks which have been completed. However, if the task is still in progress, this results in the parent changes not being integrated into the child task, and the child task branch remaining behind the parent branch.

To fix this, let's ensure that any checked in task branches which are still currently active (i.e. not DONE) are rebased or merged (as determined by the propagate command arguments), generating a new commit whose message is of the form "Resume task: <task-title> (<task-id>)" and updating the task bookmark to point to this commit.
