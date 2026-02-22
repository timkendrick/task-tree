---
title: "Implement `tt task describe` CLI command"
status: TODO
description: "Currently, the only time that a task's description can be edited is at the point the task is created. \n\nI would like to add a `tt task describe` command that allows the user to edit the command at any point within the task's lifetime. \n\nThis will add an additional \"describe task\" commit, similar to the initial one that's created in the `tt task create` command (in fact, the create command should be modified to invoke the new describe command rather than re-implementing the behaviour). \n\nWe'll need to document the new task in the design document and provide an initial bootstrap implementation."
---
