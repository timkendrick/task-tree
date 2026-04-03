---
title: "Add `tt history unlock` CLI command"
status: TODO
created: 2026-04-03T21:28:40Z
updated: 2026-04-03T21:28:40Z
---
Currently, if a process crashes mid-transaction, the `.tt/history` file is left in a broken state.

Add a `tt history unlock [--force]` command that ensures the history is in a consistent state.

If there is no active (pending) transaction, this is effectively a no-op that exits with code `0`.

If the history is mid-transaction, the command exits with code `1` unless the `--force` argument is specified, in which case it copies the current transaction's 'before' id after the colon (so the final transaction log entry ends up `<before-id>:<before-id>` ).

this command should be mentioned in the transaction start failure shared helper message.
