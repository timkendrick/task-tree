---
title: "Implementation summary: Standardize VCS operations"
created: 2026-08-30T13:51:34Z
updated: 2026-09-09T14:36:05Z
---
# Implementation summary: standardize VCS operations

Requirements: `standardize-vcs-operations.requirements.md` ·
Architecture: `standardize-vcs-operations.architecture.md` ·
Plan: `standardize-vcs-operations.plan.md`

## What changed

Every VCS operation in the bootstrap CLI now runs through a four-layer stack. Commands express
intent; facades own the task/worktree/workspace/history models; `lib/repo.sh` declares a
backend-neutral contract; `lib/vcs/jj.sh` is the only file that invokes `jj` or `git`.

The working-copy "dance" — check out a branch, write files on disk, commit, move back — is gone.
Branch writes are now built directly in the backing Git object store (`hash-object`, `read-tree`,
`update-index`, `write-tree`, `commit-tree`, a temporary ref, then `jj git import`), so a write to
a branch never disturbs any working copy. Two consequences shape the rest of the design:

- **Mutating commands no longer move `@`.** A command that writes to a branch leaves the working
  copy exactly where it was. Worktrees sitting on a branch that has moved are reported as out of
  sync, and `tt worktree sync` (new) brings them forward, preserving uncommitted work — including
  files the repository has never seen.
- **A working copy may only be rewritten from inside its own worktree.** Commands refuse to
  rewrite another worktree's working-copy commit rather than silently destroying uncommitted work.

Every mutating command also refuses to run when `@` itself carries a bookmark, because capturing
the working copy would absorb unrelated changes into that branch. `workspace init` is the sole
exemption: it advances no bookmark.

Backend invocations are traced through `TT_LOG`, which has two levels. `TT_LOG=info` narrates the
mutations a user would recognize as the point of the command; `TT_LOG=verbose` adds reads and
internal plumbing. The level is an editorial choice made per call site rather than derived from the
command, so the temporary-ref hop and the git plumbing behind a bare write stay out of `info` — a
routine task edit traces one line at `info` rather than eight. All tracing goes through a single
executor, `_ui__run_command`, which logs and runs the same argv, so the level cannot cause the log
line and the executed command to drift apart.

## Layer inventory

| Module | Lines | Public fns | Responsibility |
|---|---|---|---|
| `lib/ui.sh` | 216 | 8 | Logging, command execution and tracing, user-facing output |
| `lib/string.sh` | 62 | 4 | Slugs, identifiers, escaping |
| `lib/format.sh` | 17 | 1 | Shared value formatting |
| `lib/path.sh` | 95 | 8 | Repo-relative paths, symlink resolution, metadata exclusions |
| `lib/frontmatter.sh` | 325 | 14 | Task-file frontmatter parsing and rewriting |
| `lib/commit.sh` | 80 | 2 | Structured commit-message construction |
| `lib/hook.sh` | 26 | 1 | Hook dispatch |
| `lib/repo.sh` | 103 | 69 wrappers | Backend-neutral contract |
| `lib/vcs/jj.sh` | 1316 | 69 + 5 internal | The only caller of `jj` and `git` |
| `lib/history.sh` | 308 | 7 | Undo transactions and the history log |
| `lib/task.sh` | 1542 | 60 | Task model: staged writes, branches, ranges |
| `lib/workspace.sh` | 159 | 9 | Repository and workspace resolution |
| `lib/worktree.sh` | 819 | 34 | Worktree model and working-copy invariants |

`lib/common.sh` is now nothing but 12 `source` directives.

The contract is exact: 69 backend operations, 69 wrappers, no operation on either side without its
counterpart. The 5 remaining `__jj__*` helpers are the double-underscore internals that repo.sh's
header explicitly excludes from the contract.

## Verification

**Full suite: 2171 passed, 0 failed, 0 skipped** (`scripts/test --parallel`, 653 tests), green at
every one of the 17 checkpoints. The suite grew from 1259 assertions at the start of the work
to 2171.

The six-part layering audit from plan §5.17, re-run independently after the final commit:

| Check | Result |
|---|---|
| AC1a — nothing outside `lib/vcs/` invokes `jj` or `git` | empty |
| AC1b — nothing outside `lib/` calls `_repo__*` | empty |
| AC2 — no revset or template syntax outside the backend | empty (see deviation 14) |
| AC3 — every library function namespaced to its module | empty |
| AC4 — `common.sh` contains only source directives | 0 function definitions |
| AC5 — the dance and its machinery are gone | empty (see deviation 15) |
| AC6 — backend convention review | every `_jj__*` takes the repo or worktree root first and routes through a `__jj__*` runner |

`bash -n` clean on every changed file. No `FIXME` remains anywhere in `scripts/cli/`.

## Deviations from the plan

18 deviations. Numbers 1–12 are implementation findings; 13–15 concern the plan's own
verification machinery; 16–18 are defects found while checking delegated work.

### 1. `_task_commit_handoff` must not advance the child bookmark

The plan had checkin's handoff commit advance both bookmarks. Doing so makes the child branch
point at a commit that is already merged into the parent, so the next checkin sees an empty range
and refuses. The handoff now advances only the parent; the child bookmark stays where it was.

### 2. `_worktree_reattach_current_on_branch` added

The plan's single `_worktree_reattach_current` moved the current worktree's working copy onto a new
tip whenever a write advanced a branch. That is wrong when the worktree sits on a *different*
branch: it would drag the working copy across branches. The branch-aware variant reattaches only
when the worktree is actually on the branch that moved.

### 3. Branch resolution ranks by fork point, not nearest bookmark

`_worktree_find_for_branch` originally resolved a worktree's branch by nearest reachable bookmark.
A worktree left behind by a branch write then resolved to whichever ancestor bookmark remained
reachable — misattributing it to the wrong branch, which surfaced as four failures at the C1 gate.
Resolution now ranks candidates by fork point, so a behind worktree still resolves to its own
branch. `_worktree_resolve_branch` exposes the same ranking to callers.

### 4. `workspace init` is exempt from the `@`-carries-a-bookmark guard

The plan applied the guard to every mutating command. `workspace init` advances no bookmark and
performs no branch write, and the repository it initializes will normally have `@` on its default
bookmark — so the guard would make the command unusable on a fresh repository for no benefit.

### 5. `checkpoint` has no "work to snapshot" precondition

The plan gated checkpoint on the working copy being non-empty. An empty checkpoint is meaningful
(it records a waypoint), and the precondition made checkpoint fail in exactly the situation where a
user wants to mark a boundary. Removed.

### 6. Import-hop reconciliation in `_jj__commit_changeset`

Latent operation leak, not in the plan. After the temporary Git ref is deleted out of band, jj's
last-seen ref state still contains it, so the *next* auto-importing `jj` invocation mints a
surprise "import git refs" operation outside any tt transaction — which breaks undo integrity. A
second `jj --ignore-working-copy git import` now reconciles the deletion inside the transaction.
This was the root cause of a `assert_history_integrity` failure at the C1 gate.

### 7. `_jj__set_bookmark` gained `--ignore-working-copy`

Setting a bookmark was snapshotting the working copy as a side effect, reintroducing exactly the
coupling the refactor removes.

### 8. `_jj__list_changed_files_in_range` added

The plan left `_task_list_unmerged_changes` building its own revset inline — the last revset leak
outside the backend. The new operation diffs a range as a single unit against its roots, so content
merely inherited from the base is not reported.

### 9. `tt worktree sync` no-op short-circuits before opening a transaction

Not in the plan. Syncing an already-current worktree recorded an undo entry that reverted to the
state the repository was already in, displacing the user's real previous action by one step in the
undo history. `_worktree_check_behind` now short-circuits first — matching what `--all` already
did, which made the inconsistency internal as well as user-visible.

### 10. `task rename` no longer advertises a `--force` flag

Its refusal message told the user to re-run with `--force`. The command has no such flag, and
should not: rewriting a worktree's commits from outside it destroys uncommitted work. The message
now states the constraint instead of offering an escape that does not exist.

### 11. `_task_format_range` added

`task revset` was assembling range syntax itself. Range rendering now belongs to the task facade
over `_repo__format_revision_range`, so the syntax of each form is owned by the backend.

### 12. Two-phase tree rewriting for `task rename`

As planned in substance, but the ordering constraint proved sharper than written: all target trees
must be computed from the *original* objects before any restore runs, then applied oldest-first by
change ID. Computing lazily reads trees that earlier restores have already rewritten.

### 13. AC2's grep needs interpretation, not appeasement

The plan's AC2 pattern matches `commit_id` and `change_id` anywhere, so it flags ordinary shell
variable names (`local commit_id`, `read -r change_id`) and library function names
(`_task_resolve_fork_point`, `_task_list_unmerged_roots`, `_worktree_list_holding_descendants`) that
contain no revset at all. Verified instead that no revset or template *string* exists outside the
backend: no `-r`/`-T` argument appears in any production file outside `lib/vcs/jj.sh`. All residual
matches are identifiers.

One agent had earlier inserted a space (`_task_resolve_fork_point () {`) to dodge this grep. That
was reverted — the audit was corrected, not the code.

### 14. AC5's grep must also exclude `lib/repo.sh`

AC5 excludes `lib/vcs/jj.sh` but not the wrapper layer, and the wrapper layer necessarily declares
every backend operation — so `_repo__set_working_copy_revision`'s one-line wrapper will always match.
The dance itself is genuinely gone: **no production code calls that operation at all.**

It is left in place as declared contract surface (the architecture document lists it in the
working-copy group, and "point the working copy at a revision" is a primitive any backend must
offer), but it is currently unreachable and is the one piece of dead surface in the stack. Flagged
rather than removed, since narrowing an approved contract is a design decision.

### 15. The trace level cannot be verified by comparing suite results

The plan asks for the full suite run twice — quiet and traced — with identical results. That is
unachievable by construction: tracing writes to stderr, and 18 tests fold stderr into captured
output with `2>&1`, so they see trace lines in the text they assert on. Observed exactly that:
**2166 passed quiet, 2148 passed / 18 failed verbose** (measured at the C7 tree), every failure's
actual value being a `+ jj …` trace line, and `assert_success` passing in all of them.

D16 was instead established at the code level, which is stronger. The trace level is read in one
place, `_ui__check_log_level`, and consumed in one place, `_ui__run_command`, which logs and then
executes the same argv: the command invoked is identical at every level, stdout routing is fixed by
the caller's output policy rather than the level, and the exit status is the underlying command's.
The level therefore cannot affect behavior — only diagnostics.

### 16. Commands were probing `.jj` directly on the filesystem

Found while checking the final step. Three commands tested for a repository by looking for a `.jj`
directory themselves — `workspace/init`, `task/delete`, and `task/checkout`. The literal AC1a grep
misses these because `.jj` is not `jj ` followed by a space, but they are exactly the layering
violation the audit exists to catch: a command that knows the backend's on-disk shape.

Two facades now answer the question, and the probes are gone:

- `_workspace_check_repository PATH` — is PATH a repository root
- `_worktree_check_exists PATH` — does a worktree already live at PATH

### 17. User-facing messages no longer name the backend

Consequence of the layering premise: a message naming `jj` becomes wrong under a different backend.
`"Not a jj repository"` → `"Not a repository"`, `"No enclosing jj repository"` →
`"No enclosing repository"`, `"forgotten from jj."` → `"forgotten from the repository model."`, and
the bookmark refusal's `"jj new"` → prose describing the action.

The last of these trades some actionability for backend-neutrality, and is worth a second opinion:
`tt` users do work in `jj`, and the concrete command was useful. Help text still describes the
default repository search as "walk up from CWD to find .jj", which remains backend-specific and was
left alone as a documentation matter.

### 18. Test-fixture and harness corrections

- `scripts/harness/harness.sh`: bash 3.2 evaluates `local a=$1 b=${2:-$1}` left-to-right within one
  statement in a way that broke the default; split into two statements.
- `scripts/cli/task/reorder.test.sh`: four tidy tests created a task immediately after a checkin
  and relied on `@` being left on the parent. Since mutating commands no longer move `@`
  (the central behavior change), those tasks were being parented under the wrong branch. Fixtures
  now check out the project explicitly. **This is a fixture correction, not an assertion change** —
  the tests assert the same things.

## Notes for review

- Deviation 14 leaves one unreachable contract operation. Removing it is a one-line change if you
  would rather the contract carry no dead surface.
- Deviation 17's `"jj new"` → prose change is the only place where backend-neutrality cost the user
  concrete guidance.
- Documentation (plan phase D — `ARCHITECTURE.md`, `DESIGN.md`, `DEVELOPER.md`) was out of scope for
  this work and is not included, though `DESIGN.md` and `.agents/skills/tt/SKILL.md` were kept
  current where commands changed user-visible behavior.
