---
title: "Architecture"
created: 2026-09-21T11:23:32Z
updated: 2026-09-21T11:23:32Z
---
# Architecture: check for a stale canonical workspace before acting

Implements the requirements recorded in the task context document `context/requirements-b48713a3`.

## Empirical basis

Verified against jj 0.43 before choosing the mechanism:

| Probe | Result |
|---|---|
| Unrelated operation in another workspace | target workspace stays healthy |
| Bookmark advances past a workspace (workspace *behind*) | stays healthy — *behind* and *stale* are distinct |
| Bare rewrite of a workspace's working-copy commit tree | workspace becomes stale |
| `op restore` from a stale workspace | refused — the failure this task is about |
| `jj debug working-copy` in a stale workspace | succeeds, records no operation |
| `jj debug working-copy` in a healthy workspace with pending edits | records no operation |
| `jj debug local-working-copy` in a healthy workspace with pending edits | records an operation — snapshots, unusable as a probe |
| `jj workspace update-stale` in a healthy workspace with pending edits | records an operation — snapshots, unusable as a probe |
| `jj workspace update-stale` against a stale workspace holding edits | on-disk edits destroyed |
| Workspace list templates | expose no staleness keyword |

There is no user-facing backend command that reports staleness without loading — and therefore
snapshotting — the working copy, so detection is built from the low-level state query plus two
ordinary bare reads.

## Backend primitive

```
_jj__get_worktree_checkout_revision WORKTREE   # → commit ID, or non-zero
_repo__get_worktree_checkout_revision          # 1:1 wrapper in lib/repo.sh
```

Prints the commit ID that WORKTREE's on-disk files were last updated to — which may differ from the
commit the repository currently records for that workspace. Pure read: records no operation, updates
no files, and works against a stale workspace.

```
_jj__get_worktree_checkout_revision WORKTREE:
  output = jj -R WORKTREE debug working-copy
  op     = the OperationId(...) value on the "Current operation:" line
  fail unless op was parsed
  jj -R WORKTREE --at-operation op --ignore-working-copy log -r @ --no-graph -T commit_id
```

The function lives in the working-copy group of `lib/vcs/jj.sh` (it is worktree-scoped), with a
header comment recording why the low-level query is used: every user-facing alternative snapshots.

## Detection

```
_worktree__check_stale REPO WORKTREE
  # 0 = stale, 1 = not stale, 2 = state could not be determined
```

```
_worktree__check_stale REPO WORKTREE:
  matched = _repo__get_worktree_checkout_revision WORKTREE  || return 2
  current = _repo__resolve_commit WORKTREE '@'              || return 2
  [[ matched != current ]]
```

Status 2 is a distinct outcome, never folded into either boolean: tt does not guess at a state it
could not read. Backend error text reaches the user through `TT_LOG`, as it does for every other
backend failure.

## Guards

Two functions in `lib/worktree.sh`, beside `_worktree__ensure_working_copy`:

```
_worktree__ensure_worktree_current REPO WORKTREE   # guard a named worktree
_worktree__ensure_canonical_current REPO          # guard the canonical workspace
```

```
_worktree__ensure_worktree_current REPO WORKTREE:
  case _worktree__check_stale REPO WORKTREE in
    0) log the stale refusal naming WORKTREE and the refresh command ; return 1
    2) log the indeterminate refusal naming WORKTREE                 ; return 1
    1) return 0
```

```
_worktree__ensure_canonical_current REPO:
  return 0 if TT_TRANSACTION_ID is set          # nested call: the outermost command checked
  canonical = _repo__resolve_repository_root REPO
  return 0 if canonical is the invoking worktree
  _worktree__ensure_worktree_current REPO canonical
```

Both skips are load-bearing, not optimizations:

- **Nested calls.** A parent command's own writes can make the canonical workspace stale. A nested
  guard would then refuse mid-transaction, and the rollback that refusal triggers is precisely the
  one staleness breaks — converting a survivable situation into a locked repository. The check
  belongs once, before anything is written.
- **Canonical is the invoking worktree.** The requirements leave the invoking worktree to fail on
  its own terms: the transaction's begin-time snapshot refuses immediately and rolls back cleanly.
  A single-workspace repository therefore pays nothing for the guard, and the guard runs only where
  it is load-bearing — a canonical workspace nobody is standing in.

The target guard (`_worktree__ensure_worktree_current`) has neither skip: it is called about a
worktree the command is *about to touch*, including when that worktree is the invoking one.

## Call sites

**Canonical guard** — one line after the existing bookmark precondition in each branch-writing
command:

```
  _worktree__ensure_working_copy "$repo" || exit 1
  _worktree__ensure_canonical_current "$repo" || exit 1
```

`task create`, `task edit`, `task checkout`, `task checkin`, `task complete`, `task delete`,
`task move`, `task rename`, `task reorder`, `task propagate`, `task publish`, `task checkpoint`,
`task context add`, `task context delete`.

**Target guard** — in the four commands that load a foreign working copy. In each, the target is
already resolved before the transaction opens, so the refusal costs nothing to unwind:

| Command | Guarded target | Sits before |
|---|---|---|
| `worktree sync` | every screened target (see below) | `_history__begin_transaction` |
| `task checkout --worktree[=path]` | the resolved target worktree | `_history__begin_transaction` |
| `task checkin --delete` | the child branch's worktree | `_history__begin_transaction` |
| `worktree switch` | the outgoing worktree | the switch itself (no transaction) |

## `tt worktree sync`

Screening runs after the target list is built and before the transaction opens:

```
  targets = (named path | current worktree | every worktree behind its branch)
  stale   = [ t for t in targets if not _worktree__ensure_worktree_current REPO t ]
  if stale is non-empty: report each, exit 1          # nothing synced
  _history__begin_transaction REPO
  ... existing per-target sync, whose own failure path now also covers a
      target that went stale between the screening and its turn ...
```

Screening covers the targets only. A workspace that is stale but not behind never enters `--all`'s
target list and is neither reported nor blocking: sync moves worktrees forward, and says nothing
about a workspace it was never going to touch.

The defensive runtime check inside the per-target path emits the same refusal wording as the
screening and is handled by the existing per-target failure accounting.

## `tt worktree refresh`

New command `scripts/cli/worktree/refresh`, plus a `refresh → worktree refresh` entry in the
dispatcher's alias table and usage text.

```
tt worktree refresh [<path>] [--root] [--force] [--repo PATH]
```

Target resolution: no argument → the worktree containing the CWD; `<path>` → that worktree;
`--root` → the canonical workspace; `<path>` with `--root` → usage error, exit 1. No `--all`.

```
main:
  parse arguments
  target = resolve as above
  if --force:
    _repo__refresh_worktree target || fail
    log "Refreshed <target>"
    exit 0
  case _worktree__check_stale REPO target in
    1) exit 0                                    # healthy: silent no-op
    0) log the stale refusal, naming --force and the loss of uncommitted changes ; exit 1
    2) log the indeterminate refusal                                             ; exit 1
```

- No transaction. Refresh is a recovery operation, like `tt workspace init`: a transactional refresh
  of a stale canonical workspace could not roll itself back, and refresh must stay usable while a
  stale lock is present.
- `--force` bypasses detection entirely, so there is a route out of any state tt cannot classify —
  including the operation-divergence state jj reports as an internal error.
- Output is one line. The backend's own account of what changed on disk is available through
  `TT_LOG=info`, which is where every other tt command sends that level of detail.

## Failed rollback keeps the lock

In `_history__rollback_transaction`, the restore's failure branch changes from a warning to an early
return that keeps the entry:

```
  ... existing working-copy preservation ...
  if ! _repo__restore_operation canonical_repo before_op:
    discard the preserved copies without re-applying them
    log the multi-line error: repository left mid-transaction, the full
        before-op ID, that the transaction is still recorded, and both exits
        (tt history undo --force / tt history unlock --force)
    clear the trap and unset _TT_TRANSACTION_OWNER and TT_TRANSACTION_ID
    return                                  # the in-progress entry stays
  ... existing re-application, entry removal, trap clearing ...
```

The preserved copies are discarded unre-applied: a failed restore never disturbed the files, and the
re-apply is gated on a working-copy comparison that is meaningless once the restore did not happen.
The transaction state is still cleared so the process does not roll back twice; only the history
*entry* survives, which is what makes the damage visible to the next command.

The command's own exit status is unaffected, exactly as today.

## Test support

`scripts/harness/harness.sh` gains one helper:

```
make_worktree_stale WORKTREE    # bare-rewrite WORKTREE's working-copy commit tree,
                                # then assert the backend now refuses a working-copy
                                # command there
```

Defining the mechanism once means a backend behaviour change breaks one place rather than seven
suites.

## Message catalogue

Each states the condition and the action, and speculates about nothing.

```
Error: The workspace is stale: <path>
  Recover it first: tt worktree refresh <path> --force
  Uncommitted changes in that workspace will be lost.

Error: Could not determine the state of the workspace: <path>

Error: The workspace is stale: <path>            # tt worktree refresh, no --force
  Use --force to recover it.
  Uncommitted changes in that workspace will be lost.

Error: Could not restore the VCS operation state.
  The repository was left mid-transaction at operation <full-op-id>.
  The transaction is still recorded, so the next tt command will refuse.
  To retry the revert:        tt history undo --force
  Or, once recovered by hand: tt history unlock --force
```

## Delivery order

1. `tt worktree refresh`, its alias, the backend primitive, `_worktree__check_stale`, the harness
   helper, and the documentation for all of it. Every later refusal points at this command.
2. The guards and their call sites — canonical first, then the four foreign-target commands.
3. The rollback lock.
