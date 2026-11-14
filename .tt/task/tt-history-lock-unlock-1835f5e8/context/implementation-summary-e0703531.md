---
title: "Implementation summary"
created: 2026-11-14T12:59:38Z
updated: 2026-11-14T12:59:38Z
---
# Implementation summary

## Overview

A **user-held transaction** spans several tt commands, so that they form one history entry. The user opens it with `tt history lock`, runs commands inside it, and closes it with `tt history unlock --key` (keep) or `tt history undo --key` (revert).

```bash
key="$(tt lock)"
export TT_TRANSACTION_ID="$key"
if tt create --project --slug api --title API </dev/null; then
  tt unlock --key "$key"
else
  tt undo --key "$key"
fi
unset TT_TRANSACTION_ID
```

## Commands

### `tt history lock` (alias `tt lock`)

- Refuses when `TT_TRANSACTION_ID` is already set.
- Refuses when the history file does not exist.
- Refuses when the canonical workspace is stale.
- Begins a transaction as any mutating command does. Begin records the in-progress entry, refuses when another transaction is in progress, and snapshots the invoking worktree.
- Detaches from the transaction: it clears the abort trap and the ownership state, and leaves the in-progress entry open.
- Prints the key (the before-op ID) to stdout. Prints a hint on stderr that names the export and both closing commands.

### `tt history unlock --key KEY` (alias `tt unlock`)

- Commits the in-progress transaction when its before-op ID is KEY: it writes the current operation as the after-op ID.
- Exits 1 when no transaction is in progress (including an empty history), when the keys differ, or when a leftover history lock is present.
- Cannot be combined with `--force`.

### `tt history undo --key KEY`

- Reverts the in-progress transaction when its before-op ID is KEY.
- Skips the dirty-working-copy refusal and the outgoing-operation logging.
- Restores from the invoking worktree, and keeps that worktree's uncommitted files as a failed command's rollback does.
- On success, removes the entry and patches the previous entry's after-op ID, as plain undo does.
- On a failed restore, keeps the entry and exits 1.
- Exits 1 when no transaction is in progress or when the keys differ.
- Cannot be combined with `--force`.

## Joining a transaction

A command that inherits `TT_TRANSACTION_ID` takes the nested path of transaction begin. That path now verifies the inherited ID: under the history lock, it checks that the last history line is `<TT_TRANSACTION_ID>:`. It exits 1 with one of two errors:

- "TT_TRANSACTION_ID is set, but no transaction is in progress" when the last line is complete or the history is empty.
- "TT_TRANSACTION_ID does not match the transaction in progress" when another transaction is in progress.

The check applies to internal sub-commands too. Their parent's entry always matches, so their behavior does not change. The parent does not hold the history lock while a sub-command runs, so the check cannot deadlock.

## Library changes

- `_history__detach_transaction`: gives up ownership without closing the transaction.
- `__history__verify_joined_transaction`: the nested-begin check above.
- `_history__restore_transaction REPO RESTORE_FROM BEFORE_OP`: the restore and working-copy preservation, moved out of rollback. It does not touch the history file or the history lock. Rollback calls it with the canonical repository. `undo --key` calls it with the invoking worktree.

## Design decisions

- **The key is the before-op ID.** It already identifies the in-progress entry, so no new state is stored.
- **Joined commands verify the key.** A stale or mistyped key is rejected rather than silently admitted.
- **Joined commands do not roll back.** They do not own the transaction. `undo --key` reverts the whole transaction instead.
- **`undo --key` keeps uncommitted files.** `tt lock` snapshots the working copy after it records the before-op ID. A plain restore would therefore remove edits that existed before the lock. Reusing the rollback preservation keeps them.
- **`undo --key` restores from the invoking worktree**, as plain undo does. A stale canonical workspace then does not block the revert.
- **`tt lock` runs the canonical-workspace staleness check.** Joined commands skip that check because `TT_TRANSACTION_ID` is set, so it runs once before the transaction opens. A command inside the transaction can still make the canonical workspace stale. Later commands in the transaction do not report it. The design already accepts this gap for single commands.
- **`--key` and `--force` are mutually exclusive** on both `unlock` and `undo`.

## Test harness guard

`run_tt` and `run_tt_in_worktree` now fail the test when neither `REPO` nor `TT_REPO` names a test workspace. `run_tt_in_worktree` also fails when given no worktree path. Without the guard, a test that omits `setup_workspace` runs tt against the repository that encloses the working directory. That is the repository the tests run from. The `workspace init --help` test omitted `setup_workspace` and now calls it.

## Tests

- `history/lock.test.sh`: key output and entry, stderr hint, refusals (nested, in progress, stale canonical workspace), snapshot reverted by `undo --key`, commands without a key or with a wrong key refused, `unlock --key` and `undo --key` flows, aliases, help.
- `history/unlock.test.sh`: `--key` match, mismatch, no transaction, empty history, combined with `--force`, leftover lock, help.
- `history/undo.test.sh`: `--key` revert, uncommitted files kept, mismatch, no transaction, combined with `--force`, help.
- `lib/history.test.sh`: nested begin with a matching entry, a mismatched ID, and no transaction in progress; detach leaves the entry in progress and a later command joins it.

## Documentation

- `DESIGN.md`: aliases table, section 5.2, sections 6.12.2 to 6.12.5, new section 6.12.6 (user-held transactions), section 6.16.
- `ARCHITECTURE.md`: section 8 (nested begin verification, detach), section 8.2 (shared restore helper), new section 8.3.
- `.agents/skills/tt/SKILL.md`: new history commands section.
