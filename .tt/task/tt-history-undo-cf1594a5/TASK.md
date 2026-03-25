---
title: "Implement `tt history undo` CLI command"
status: DONE
created: 2026-03-24T21:51:47Z
updated: 2026-03-24T21:51:47Z
---
Add a `tt history undo [--force]` command (aliased to `tt undo`) that reverts the underlying `jj` repository to the operation before the latest mutating `tt` command.

Before making any `jj` changes, each `tt` command should capture the current `jj` revision via `jj op log --no-graph -T id -n 1` and record it (mechanism TBD) so that the operation can be reverted.

Multiple `tt history undo` commands should go back increasingly in history. There is no corresponding `tt history redo` planned, however `tt history undo` should log the outgoing `jj` operation ID before undoing, giving the user a way to manually redo the change.

It's unclear how best to record the latest `jj` operation for the undo - one one hand, committing the operation ID into the repository would provide the most robust history, ensuring the `tt` history stays in sync with the repository; the downside of this approach is that e.g. checking out tasks becomes a mutating operation.

Another option is to record the last N `jj` operation IDs by appending to a file every time a mutating `tt` operation takes place. This file must be ignored by `jj` and should probably store the 'before' and 'after' operation IDs as a `<before-id>:<after-id>` line, each of which represents a 'transaction'. An in-progress transaction would have an empty `<after-id>` (i.e. `<before-id>:`) - this indicates that `tt` is 'locked' and attempting to start a new transaction will fail. If the `jj` repository is currently at the latest `<after-id>` operation, it can safely `tt history undo`, however it is at a different operation a message should explain the situation, allowing the undo to be forcibly applied via `--force` flag.

We need to make sure to add `TRAP`s to all mutating `tt` commands (at the point the new transaction is created) to revert the `jj` state to the 'before' entry (and delete the log entry line) if a command fails mid-transaction (special attention should be paid to commands with follow-on actions where failures are tolerated).

An in-progress transaction can be forcibly reverted via `tt history undo --force` (e.g. if a process crashed mid-transaction without fixing the transaction log).

We need to review all commands to ensure they are using transactions.

Update DESIGN.md with command reference and a full section explaining the history log and transaction mechanism.
