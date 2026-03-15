---
title: "Implement `tt task edit` CLI command"
status: DONE
created: 2026-03-15T09:29:31Z
updated: 2026-03-15T09:29:31Z
---
Currently, the only time that a task's description can be edited is at the point the task is created.

I would like to add a `tt task describe` command that allows the user to edit the command at any point within the task's lifetime.

This will add an additional "describe task" commit, similar to the initial one that's created in the `tt task create` command (in fact, the create command should be modified to invoke the new describe command rather than re-implementing the behaviour).

We'll need to document the new task in the design document and provide an initial bootstrap implementation.
