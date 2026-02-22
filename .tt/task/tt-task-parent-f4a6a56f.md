---
title: "Implement `tt task parent` CLI command"
status: TODO
description: "A `tt task parent` command would be useful to establish task context e.g. when chaining commands together.\n\nUsage: `tt task parent [<task-id]`, defaults to current task.\n\nOutputs just the parent task ID to stdout.\n\nIf there is no parent (or multiple parents), exit with a non-zero exit code.\n\nUse existing helper functions to get parent.\n\nThis will need to be added to the design document."
---
