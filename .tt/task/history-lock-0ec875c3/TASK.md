---
title: "Serialize concurrent writes to the transaction history"
status: DONE
created: 2026-10-29T17:47:43Z
updated: 2026-10-29T17:47:43Z
---
## Problem

`_history__begin_transaction` (`scripts/cli/lib/history.sh`) checks whether a transaction is already in progress by reading the last line of `.tt/history`, then appends `<before-op>:` as a separate step. Nothing makes the check and the append atomic, so two commands that start at the same time can both pass the check and run concurrently. When that happens:

- One command's commit leaves the other command's in-progress entry open in the middle of the file, where the last-line check never sees it again.
- A rollback restores the repository to its own before-op, discarding the other command's concurrent work.

The history-file rewrites also race with readers. These are `_history__replace_last_line`, `_history__delete_lines`, and the `sed -i` edits in `tt history undo` and `tt history unlock`. A rewrite with `>` truncates the file before writing it, so a concurrent reader can see an empty file and pass the check.

## Fix

Guard every read-check-write of `.tt/history` with a short-lived lock built on `mkdir`, which atomically creates a directory or fails if it already exists. The in-progress history line stays the long-lived "transaction in progress" marker. The new lock only makes each read-check-write of the file a single step.

### `scripts/cli/lib/lock.sh` (new)

- `_lock__acquire PATH TIMEOUT`: attempts `mkdir PATH` (never `mkdir -p`) and retries every 0.1s until it succeeds or TIMEOUT seconds have elapsed. Returns 0 when the lock is acquired and non-zero on timeout. Prints nothing, so the caller owns the error message.
- `_lock__release PATH`: removes the lock directory.
- Tests in `scripts/cli/lib/lock.test.sh`:
  - Acquire succeeds when the lock is free.
  - Acquire waits for a concurrent release, then succeeds.
  - Acquire times out while the lock is held.
  - Release frees the lock.

### `scripts/cli/lib/history.sh`

- Add the internal, non-configurable constant `_TT_HISTORY_LOCK_TIMEOUT=5` (seconds). Pass it to `_lock__acquire`.
- Lock path: `<canonical-repo>/.tt/history.lock`. Resolve it next to `_history__resolve_file`, through `_path__metadata`, so every worktree shares one lock.
- `_history__begin_transaction`: hold the lock around capturing the before-op, checking the last line, and appending the in-progress entry. Release it before the working-copy snapshot.
- `_history__commit_transaction` and `_history__rollback_transaction`: hold the lock around the history-file rewrite only. The VCS restore in rollback stays outside the lock.
- On timeout, fail with an error that names the lock directory and suggests `tt history unlock --force`.
- Every exit path inside a locked section must release the lock, error paths included.
- Nested sub-commands (`TT_TRANSACTION_ID` already set) keep their early return and never touch the lock, so they cannot deadlock against their parent.

### `tt history undo` (`scripts/cli/history/undo`)

Hold the lock for the whole read-last-line, restore, rewrite-history sequence. A transaction starting in between would otherwise make `sed '$ d'` delete the wrong line.

Note: this holds the lock across a VCS restore, which takes longer than the other locked sections. A command started during an undo may wait, and on a large repository it may hit the timeout.

### `tt history unlock` (`scripts/cli/history/unlock`)

- Take the lock around its history-file rewrite.
- With `--force`: remove a leftover `history.lock` whenever one exists, even when the history has no in-progress entry, and report that it was removed. `unlock --force` is how a user recovers from a stuck lock, so it must not block on that lock. Remove a leftover lock rather than waiting for it.
- Without `--force`: report a leftover lock and exit 1.

### `tt workspace init` (`scripts/cli/workspace/init`)

Add `/history.lock` to the generated `.tt/.gitignore`. Also add it to this repository's own `.tt/.gitignore`.

## Tests

- Two concurrent `_history__begin_transaction` calls: exactly one succeeds and the other refuses with the "Another tt command is in progress" error.
- A held lock causes `_history__begin_transaction` to fail with the timeout error.
- `tt history unlock --force` removes a leftover lock, with and without an in-progress entry.
- `tt history unlock` without `--force` reports a leftover lock and exits 1.
- `tt workspace init` writes `/history.lock` to `.tt/.gitignore`.

Read the test harness instructions in `DEVELOPER.md` before running tests.

## Documentation

- DESIGN.md §6.12 (transaction history): describe the lock, its path, the timeout, and its relationship to the in-progress entry.
- DESIGN.md `tt history unlock` and `tt workspace init` entries: describe the new lock handling and the new gitignore entry.
- `.agents/skills/tt/SKILL.md`: mention that `tt history unlock --force` also clears a stuck history lock.
