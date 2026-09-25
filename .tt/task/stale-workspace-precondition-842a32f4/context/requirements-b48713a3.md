---
title: "Requirements"
created: 2026-09-21T11:08:14Z
updated: 2026-09-21T11:08:14Z
---
# Requirements: check for a stale canonical workspace before acting

## Background

A jj workspace becomes **stale** when a bare mutation — one run with `--ignore-working-copy` —
rewrites the commit that workspace's working copy sits on, changing its tree. jj then refuses every
command in that workspace that loads its working copy, until `jj workspace update-stale` is run
there. Unrelated operations elsewhere in the repository do not make a workspace stale, and neither
does a bookmark advancing past it: a workspace left behind on an older tip is *behind*, which
`tt worktree sync` already handles, and that is a different condition from *stale*.

`_history__rollback_transaction` restores the recorded before-operation in the **canonical** repo,
because that is the one workspace guaranteed to exist even when the invoking worktree has just been
deleted. In a repository driven from task worktrees the canonical workspace is rarely the one being
worked in, so it can sit stale indefinitely; the restore then fails, the rollback reports it only as
a warning, deletes the in-progress history entry anyway, and leaves the repository mid-transaction
with no lock and no trace.

## Scope

1. Refuse up front, before any write, when a workspace tt is about to act on is stale.
2. Keep the in-progress history entry when a rollback's restore fails, so the damage is visible.
3. Add `tt worktree refresh`, the command those refusals point at.

The rollback's choice of workspace is **not** changed: the restore continues to run in the canonical
repo.

## Detection

Staleness of a named workspace is a new backend-contract operation, exposed as a `_repo__*` wrapper
over a `_jj__*` implementation.

- The check MUST be strictly read-only: it must not record an operation, and it must not touch the
  target workspace's files, even when that workspace is healthy. Running an ordinary
  working-copy-loading command against the workspace is therefore not acceptable, because a healthy
  workspace holding uncommitted edits would have those edits snapshotted into a new operation on
  every tt command, outside any transaction.
- It MUST work against any workspace in the repository, not only the invoking one.
- It reports a boolean condition (stale / not stale) and MUST distinguish "could not determine" from
  both, so callers can decide whether an unreadable workspace blocks them.

## Precondition: canonical workspace

A new precondition function lives in `lib/worktree.sh`, beside `_worktree__ensure_working_copy`, and
is called from the same call sites — every command that writes to a branch:

`task create`, `task edit`, `task checkout`, `task checkin`, `task complete`, `task delete`,
`task move`, `task rename`, `task reorder`, `task propagate`, `task publish`, `task checkpoint`,
`task context add`, `task context delete`.

- It inspects the **canonical workspace only** — exactly the workspace a rollback would restore
  from. The invoking worktree is not checked: if it is stale, the transaction's begin-time snapshot
  fails immediately and rolls back cleanly.
- On a stale canonical workspace the command refuses before any write: non-zero exit, no transaction
  opened, no history entry created, repository untouched.
- The refusal names the stale workspace path and the command that recovers it.

### Residual gap (accepted)

A command that itself rewrites the canonical workspace's working-copy commit makes that workspace
stale *during* its own run; if it then fails, its rollback still cannot restore. This is accepted
rather than closed. It is survivable because the history entry is kept (below) and the reported
recovery route — `tt history undo --force` — restores from whichever worktree it is invoked in,
which in this situation is not the stale one.

## Precondition: foreign worktrees

Four commands load a worktree other than the one they were invoked from, and each must verify that
target is not stale before any write, refusing with the same message shape and naming that path:

| Command | Foreign access |
|---|---|
| `tt worktree sync <path>` / `--all` | snapshots and rebases the target |
| `tt task checkout --worktree[=path]` | checks the target clean, starts or commits its working copy |
| `tt task checkin --delete` | checks the child worktree clean, or snapshots it before deleting |
| `tt worktree switch` | checks the outgoing worktree is clean |

`tt worktree sync` refuses rather than recovering: refreshing can destroy uncommitted work, so it
stays behind the deliberate, separate `tt worktree refresh` command.

### Staleness screening in `tt worktree sync`

Every target is screened for staleness **before the transaction opens**, and any stale target
refuses the whole run:

- A named target, or the default current-worktree target, refuses on its own staleness.
- `--all` screens its entire target list first. If any target is stale, the command reports every
  stale worktree with the refresh command for each, syncs nothing, and exits non-zero.

The run is all-or-nothing rather than skip-and-continue: with `tt worktree refresh` available, the
user can restore a consistent state themselves, which is preferable to partially self-healing and
committing a repository that is still inconsistent.

A defensive runtime check remains in the per-target sync path, covering a worktree that goes stale
between the screening and its turn. It reports the same message as the preemptive refusal — the user
does not need to know which check caught it — and is handled by the existing per-target failure path.

## `tt worktree refresh`

A new command, aliased as `tt refresh`, that recovers a single stale workspace by driving the
backend's stale-workspace recovery.

```
tt worktree refresh [<path>] [--root] [--force] [--repo PATH]
```

- No target given: the worktree containing the current working directory.
- `<path>`: that worktree.
- `--root`: the canonical workspace.
- `<path>` together with `--root` is an error (usage message, exit 1).
- There is no `--all`: the command acts on exactly one workspace.

Behaviour, mirroring `tt history unlock`:

- Target not stale: exit 0, no output.
- Target stale, no `--force`: exit 1 with an error naming the workspace and stating that `--force`
  recovers it and that uncommitted changes in that workspace will be lost.
- Target stale, with `--force`: recover it, report the files the recovery changed on disk, exit 0.

The command does **not** open a transaction. It is a recovery operation, like `tt workspace init`:
a transactional refresh of a stale canonical workspace could not roll itself back, and refresh must
remain usable while a stale lock is present.

Uncommitted work in a stale workspace cannot be preserved — jj cannot snapshot a stale working copy,
so the recovery resets the files to the rewritten tree. The help text and DESIGN.md must say so.

## Failed rollback leaves a lock

When the restore inside `_history__rollback_transaction` fails:

- The in-progress `<before-op>:` entry is **kept**, so the next tt command refuses with the existing
  "Another tt command is in progress" error instead of running against a half-written repository.
- The report is escalated from a warning to an error carrying: that the repository was left
  mid-transaction, the full operation ID to restore, that the transaction is still recorded, and
  both ways out — `tt history undo --force` to retry the revert, or `tt history unlock --force` once
  the user has recovered by hand.
- The command's own exit status is unchanged by the rollback, as today.

When the restore succeeds, the entry is removed exactly as it is now.

## Message style

Error messages state the condition and the action. They do not speculate about how the condition
arose. Consequences are stated plainly — "uncommitted changes in that workspace will be lost", not a
hedge.

## Test coverage

1. **Precondition.** A branch-writing command run from a task worktree while the canonical workspace
   is stale: refuses, exits non-zero, names the stale path and the refresh command, leaves the
   repository unchanged, and creates no history entry at all.
2. **Lock.** A rollback whose restore fails keeps the in-progress entry, and the next tt command
   refuses because of it.
3. **Unit coverage** for the staleness detection helper and the refusal helper.
4. **`tt worktree refresh`**: target selection (default, `<path>`, `--root`, the path+`--root`
   error), the healthy no-op, the stale refusal without `--force`, and the recovery with `--force`.
5. **Foreign-worktree refusals** for `tt worktree sync` (named target, and `--all` refusing the whole
   run with nothing synced), `tt task checkout --worktree`, `tt task checkin --delete`, and
   `tt worktree switch`.

## Documentation

DESIGN.md and `.agents/skills/tt/SKILL.md` must cover: the stale-workspace concept and how it
differs from a worktree being behind, `tt worktree refresh` and its `tt refresh` alias, the new
preconditions and which commands carry them, and the lock left behind by a failed rollback.

## Delivery order

`tt worktree refresh` and its documentation land as a precursor commit, since every refusal
introduced afterwards points at it.
