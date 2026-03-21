---
title: "Extract task context commands into `tt task context` subcommands"
status: DONE
created: 2026-03-15T12:58:42Z
updated: 2026-03-21T09:15:18Z
---
The following commands exist to handle context files attached to tasks:

- `tt task add-context`
- `tt task get-context`
- `tt task delete-context`
- `tt task list-context`

These should be moved to sub-commands of `tt task context`:

- `tt task context add`
- `tt task context get`
- `tt task context delete`
- `tt task context list`

Use the existing subcommand dispatch mechanism for reference
