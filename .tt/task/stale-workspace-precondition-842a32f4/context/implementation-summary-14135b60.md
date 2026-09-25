---
title: "Implementation Summary"
created: 2026-09-25T09:48:50Z
updated: 2026-09-25T09:48:50Z
---
# Implementation summary: check for a stale canonical workspace before acting

All six planned steps are implemented, each as its own checkpoint. The full suite passes:
**2661 passed, 0 failed** (`scripts/test --parallel`, RAM disk, 822s).

## What was delivered

| Step | Checkpoint | Outcome |
|---|---|---|
| 1 | `b102b9b3` | Read-only staleness detection: backend primitive, `_repo__` wrapper, `_worktree__check_stale`, harness helper |
| 2 | `aa8a7808` | `tt worktree refresh` (alias `tt refresh`), its documentation |
| 3 | `df775703` | `_worktree__ensure_worktree_current` and `_worktree__ensure_canonical_current` |
| 4 | `70576cb0` | Canonical guard at all 14 branch-writing commands |
| 5 | `4f58b664` | Foreign-target guards: `worktree sync` screening, `task checkout --worktree`, `task checkin --delete`, `worktree switch` |
| 6 | `4ca2dbf3` | A failed rollback keeps the transaction lock |

Documentation landed alongside the behaviour it describes: DESIGN.md gains §6.16 plus the command
reference entry, alias row and per-command sentences; ARCHITECTURE.md gains §6.4 and an addition to
§8.2; SKILL.md gains the refusal and recovery recipes.

## Deviations from the plan

1. **`tt worktree refresh` reaches the backend through a facade, not `_repo__` directly.** The
   plan's pseudocode had the command call `_repo__refresh_worktree`, which ARCHITECTURE.md's tier
   table forbids — commands may call facades and utilities only, and no other command in the tree
   calls `_repo__*`. Added `_worktree__refresh WORKTREE` in `lib/worktree.sh` as the named
   counterpart of the existing `_worktree__refresh_current`.

2. **Refusal messages are emitted through two shared helpers** rather than written out at each call
   site: `_worktree__report_stale WORKTREE REMEDY` and `_worktree__report_indeterminate WORKTREE`.
   The plan specified the message text but left it duplicated between the guards and `refresh`,
   whose only difference is the remedy line. One wording for one condition now holds by
   construction.

3. **`_worktree__check_stale` binds only `$2`.** The plan's signature `REPO WORKTREE` is kept for
   consistency with the rest of the module, but the comparison needs only the worktree, so no dead
   `repo` local is introduced.

4. **The per-command refusal tests assert the operation ID is unchanged instead of checking each
   command's own effect.** The plan asked each test to assert "the command's own effect did NOT
   happen". Once the canonical workspace is stale, the harness read helpers that would inspect those
   effects cannot read it. The operation-ID check is both uniform and strictly stronger: tt cannot
   change a task file, move a bookmark or write a commit without recording an operation. Implemented
   once in `assert_refuses_stale_canonical`.

5. **`ARCHITECTURE.md`'s new section is §6.4, appended after "Out-of-sync worktrees", not inserted
   before it.** Inserting it as §6.3 would have renumbered the existing section that three
   cross-references point at. This mirrors the approach the plan itself chose for DESIGN.md §6.16.

6. **Four refusal tests needed bespoke setup** because an earlier, legitimate check fires first:
   `rename` refuses while another worktree sits in its rewrite range (the canonical workspace is
   parked on `main` first); `move` rejects a move to the parent the task already has (a second
   project is created); `publish` opens an editor (`-m` is passed); `context delete` rejects an
   unknown context (one is created first). `setup_guard_fixture` was split out of
   `setup_stale_canonical` so these can slot their extra setup in.

7. **`make_worktree_stale` rewrites a single marker path, not the whole tree.** The plan's sketch
   restored from `root()`, which empties the tree — including the `TASK.md` symlink a worktree's
   branch is read from. That left the worktree on *no branch*, a different condition, which silently
   removed it from `tt worktree sync`'s target list and made the sync tests assert nothing. The
   helper now adds and bare-removes one marker file, and publishes `STALE_PRE_REWRITE_COMMIT`
   because staling advances `@` and callers cannot capture it themselves.

8. **`tt worktree sync` prints a summary line when screening refuses** (`Error: N of M worktrees are
   stale; nothing was synchronized.`) in addition to the per-target refusals. The plan had the run
   exit 1 silently after the individual reports; under `--all` that left no statement that the whole
   run was abandoned.

## Findings raised, not fixed

**The parallel test runner hangs when a test crashes.** Raised as
`task/parallel-runner-hangs-on-crashed-test-c77d2074`. `scripts/test --parallel` never terminates if
any test function dies mid-body — verified with a throwaway probe: a test containing nothing but
`false` hangs the pool, while the same test serially exits 1. It is independent of `run_tt`, the
command cache, worktrees and this task's changes; `scripts/test` is untouched here. This is
pre-existing, and it cost several hours of wall-clock when one of my own tests passed a bad flag and
died under `set -e`.

## Notes

- The residual gap the requirements accept is unchanged: a command that itself makes the canonical
  workspace stale mid-run still cannot roll back. Step 6 is what makes that survivable.
- `tt worktree sync`'s `test_worktree_sync__all_continues_past_a_failure` takes 11s in isolation but
  up to 258s under a loaded parallel pool. This is contention, not a regression from the added
  screening — verified by timing it alone.
