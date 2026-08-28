---
title: "Requirements: Standardize VCS operations"
created: 2026-08-28T15:39:45Z
updated: 2026-08-28T15:39:45Z
---
# Requirements: Standardize VCS operations

## 1. Purpose

Every VCS operation in the `tt` bootstrap CLI is currently expressed as an inline `jj` invocation
interleaved with application logic, spread across roughly 30 files. This has three consequences:

1. **No storage seam.** A second backend (Git) cannot be introduced without rewriting every command.
2. **Working-copy hijacking.** Because there is no way to write files into a commit without a working
   copy, every mutating command borrows one — `jj edit <bookmark>`, write, `jj commit`,
   `jj bookmark set`, restore. This collides with the user's uncommitted work, can commit unrelated
   files, and can silently leave the user parked on a foreign branch when the restore step fails.
3. **Duplication.** The same five-step working-copy dance exists in one library copy and eight
   hand-rolled variants, each subtly different.

This task replaces all of it with a layered library: a single backend module that owns every `jj`
invocation, a backend-neutral facade, and semantic modules that express task-tree operations in
domain terms. Mutations become **bare** repository operations that never borrow a working copy.

## 2. Scope

### In scope

- Extraction of every `jj` invocation in `scripts/cli/**` into a VCS backend module.
- Conversion of all file-content mutations to bare operations using the Git backing store.
- Decomposition of `lib/common.sh` into per-concern library modules with a deliberate public API.
- Removal of the working-copy-hijacking machinery wherever it becomes dead.
- Relaxation of clean-working-copy preconditions that existed only to serve the hijacking.
- A new `tt worktree sync` command and associated out-of-sync reporting.
- Per-module test suites, including a full suite for the VCS backend.
- `ARCHITECTURE.md`, plus DESIGN.md and DEVELOPER.md updates.

### Out of scope

- Implementing a Git backend. This task establishes the seam; it does not populate it.
- Any change to the task-tree data model, task file format, or command surface beyond the items
  listed in §7.
- Migration of the bootstrap bash CLI toward the eventual Rust CLI.

## 3. Architecture requirements

### 3.1 Layering

Four layers, with strictly one-directional dependencies:

```
scripts/cli/**            commands — argument parsing, control flow, user output
      ↓
lib/{task,workspace,      semantic facades — task-tree operations in domain terms
     worktree,history}.sh
      ↓
lib/vcs.sh                backend-neutral VCS interface (_vcs_*)
      ↓
lib/vcs/jj.sh             backend implementation (_jj_*) — the only place `jj` is invoked
```

Utility modules (`string`, `path`, `frontmatter`, `commit`, `ui`) sit beside the facades and are
callable from any layer. They perform no VCS access.

**Call rules** (violations are defects, not style preferences):

| Layer | May call | May **not** call |
| --- | --- | --- |
| Commands | facades, utilities | `_vcs_*`, `_jj_*`, `jj` directly |
| Facades | `_vcs_*`, utilities | `_jj_*`, `jj` directly |
| `lib/vcs.sh` | `_jj_*` | — |
| `lib/vcs/jj.sh` | `jj`, `git` plumbing | facades, commands |
| Utilities | other utilities | any VCS access |

No mechanical enforcement of these rules is required; they are documented in `ARCHITECTURE.md` and
upheld by review.

### 3.2 Module inventory

| Module | Responsibility |
| --- | --- |
| `lib/common.sh` | Aggregator only. Sources every other module; defines nothing. |
| `lib/ui.sh` | Diagnostic logging, colour handling (honouring `NO_COLOR`), interactive prompts, selection. |
| `lib/string.sh` | Pure text transforms: slugification, hex/timestamp generation, quoting, escaping. |
| `lib/path.sh` | Repository and workspace path resolution, symlink resolution, `.tt/` metadata and task file path construction. |
| `lib/frontmatter.sh` | Task file frontmatter parsing, field extraction, ordered insertion and mutation. |
| `lib/commit.sh` | Construction and parsing of `[tt:<ns>:<id>:<op>]` commit messages. |
| `lib/vcs.sh` | Backend-neutral `_vcs_*` interface; the documented backend contract. |
| `lib/vcs/jj.sh` | jj backend: every `jj` invocation and every Git plumbing invocation. |
| `lib/history.sh` | `.tt/history` transaction log: begin, commit, rollback, integrity checks. |
| `lib/task.sh` | Task-domain semantics: current task resolution, branch/task mapping, parent lookup, task ranges, reading and writing task files on branches. |
| `lib/workspace.sh` | tt workspace concerns: virtual project directory, `.tt/config.toml`, `HEAD` symlink, `.tt/workspace` symlink. |
| `lib/worktree.sh` | Worktree lifecycle: creation, deletion, listing, switching, sync, out-of-sync reporting. |

`lib/common.sh` remains the single entry point sourced by commands.

### 3.3 Naming convention

Every library function is named `_<namespace>_<verb>[_<noun>]`:

- A leading underscore marks it as a library helper.
- `<namespace>` is the module name (`_frontmatter_`, `_path_`, `_task_`, `_vcs_`, `_jj_`, …).
- `<verb>` immediately follows the namespace and describes the action.

Examples: `_frontmatter_parse_field`, `_path_resolve_task_file`, `_vcs_read_file_at_revision`,
`_worktree_create`, `_history_begin_transaction`.

Names must describe **what** the operation does, never how the backend achieves it: `_vcs_create_worktree`,
not `_vcs_add_jj_workspace`; `_vcs_find_fork_point`, not `_vcs_run_fork_point_revset`.

### 3.4 Backend dispatch

`lib/vcs.sh` sources `lib/vcs/jj.sh` and defines one explicit wrapper per operation:

```bash
_vcs_read_file_at_revision() { _jj_read_file_at_revision "$@"; }
```

The wrapper block is a 1:1 name mapping — only the namespace differs — and doubles as the machine-
readable backend contract. Adding a backend means adding a file of `_<backend>_*` functions and
changing the wrapper targets. No dynamic dispatch, no `eval`, no backend-selection environment
variable in this task.

### 3.5 Backend module conventions

Every `_jj_*` function:

1. Takes the target repository root as its **first argument**.
2. Suppresses the underlying command's stdout and stderr by default, redirecting both to stderr when
   `TT_VERBOSE=1` is set. For read helpers, stdout is the return value and is always captured; only
   stderr is gated.
3. When `TT_VERBOSE=1`, echoes the full command line to stderr before executing it.
4. Never logs and never exits on failure. It returns the underlying command's exit status (or 1);
   the caller decides whether the failure is fatal and what to report.
5. Performs a **bare** repository operation unless explicitly documented as working-copy-bound (§4.4).
6. Passes `--ignore-working-copy` to every `jj` invocation that does not deliberately snapshot.

## 4. VCS operation requirements

### 4.1 Abstraction level

No `jj` revset syntax and no `jj` template string may appear outside `lib/vcs/jj.sh`. Every query
becomes a named function taking domain arguments — `_vcs_find_fork_point REPO REV_A REV_B`,
`_vcs_list_commits_in_range REPO FROM TO`, `_vcs_count_commits_in_range REPO FROM TO` — with the
revset and template held inside the backend. There is no raw-revset escape hatch.

Query helpers that return more than one field per record return line-oriented, tab-separated records
in a documented column order, so a different backend can produce the same shape.

The indicative operation inventory below is derived from the command audit. It is a completeness
target for the Architect step, not a frozen API:

- **Backend** — resolve canonical repository root; report backing-store type; verify backend support.
- **Revisions** — commit ID, change ID, description; existence check; empty check; conflict check;
  ancestry check; fork point; commit ranges (list, count, roots); mainline commit records;
  range formatting (§7.4).
- **Bookmarks** — list; list at revision; existence check; set (always with an explicit target
  revision); rename; delete; nearest enclosing bookmark for a revision.
- **Files** — read at revision; read at operation; list at operation; existence check at revision;
  Git-format diff between revisions with path exclusions; changed-file listing.
- **Mutations** — commit a changeset onto a branch; commit a changeset onto an arbitrary revision
  creating a new branch; create a merge commit; set a commit description; move commits; abandon.
- **Operations** — current operation ID; restore to an operation.
- **Worktrees** — create; forget; list; resolve root from a path; current revision; snapshot; test
  whether behind a branch; sync.
- **Working-copy-bound** — see §4.4.

### 4.2 Backing store requirement

Bare writes require the Git backing store. The backend detects the store type once per repository and,
if it is anything other than `git`, fails with exactly:

```
Unsupported repository backend: <type>
```

There is no fallback to a working-copy write path.

The Git directory is resolved by reading `.jj/repo/store/git_target` and resolving it **relative to
`.jj/repo/store/`** (not `.jj/repo/`).

### 4.3 Bare write mechanism

A single operation performs all file-content mutation. Its changeset is expressed as:

- a **staging directory** whose layout mirrors repository-root-relative paths, containing the files to
  create or replace, with symlinks present as real symlinks; and
- an explicit **deletion list** naming individual repository-root-relative file paths to remove.

The backend derives each entry's mode from the filesystem — `100644` regular, `100755` executable,
`120000` symlink — so symlink creation and retargeting are expressible without a special case.

The staging directory is a **sparse overlay**: it expresses only the paths that change, and unlisted
paths are inherited from the parent commit. Deletion entries name exact files; a caller that needs to
remove a directory enumerates its contents first. There is no recursive deletion.

Granularity is **one bare commit per logical tt commit**: the sequence runs once per commit that the
command intends to create, preserving today's commit boundaries. A command that writes to two
branches performs two calls.

The operation must:

1. Build a tree from the target branch tip plus the staged additions and deletions.
2. Create a commit with the given message and import it into the repository, attributed to the
   identity the backend is configured with rather than any ambient Git identity.
3. Advance the branch to the new commit.
4. Reattach the current worktree per §4.5.
5. Leave every worktree's uncommitted content intact.
6. Report the worktrees that are now behind the branch.

### 4.4 Working-copy-bound exceptions

Three areas legitimately require a working copy and are documented as such in `ARCHITECTURE.md`:

- `tt task checkpoint` — snapshots the user's real, uncommitted work.
- `tt task checkout` — creates and populates a worktree.
- `tt workspace init` — commits the initial workspace state.

The backend functions serving these are explicitly named and documented as working-copy-bound. No
other command may use them.

### 4.5 Live worktree handling

Adding a commit on top of a branch would otherwise leave a worktree sitting on that branch as a sibling
of the new commit, silently detaching the user's work from the branch head. tt therefore reattaches the
worktree it is running in, and only that one.

**A worktree's working-copy commit may only be rewritten by an operation running inside that worktree.**
Rewriting it from outside would move a commit that does not yet contain the worktree's uncommitted
changes, and the subsequent working-copy update would delete them. This rule is absolute and admits no
exception.

Accordingly, every mutating command:

1. **Snapshots the current worktree first**, before any bare write, so that its uncommitted changes are
   captured in its working-copy commit. This is the backend's ordinary behavior and requires no clean
   working copy; the snapshot lands in the worktree's own anonymous working-copy commit, never in the
   commit tt is about to create.
2. Performs the bare write.
3. **Reattaches the current worktree** — if its working-copy commit descended from the branch's previous
   tip, it is moved onto the new commit and its on-disk state updated. Otherwise it is left alone.

Worktrees other than the current one are never written to and never rewritten. They remain fully
usable; they are simply **behind** the branch, their working-copy commit still descending from the
previous tip. The command reports them:

```
The following worktrees are now out of sync:
  <path> (<task-id>)
```

and directs the user to `tt worktree sync`. The message contains no backend-specific remedy. The
command still succeeds.

Because a worktree is only ever rewritten from within, `tt worktree sync` is the sole mechanism for
bringing a behind worktree forward, and it is safe by construction: it runs inside the target worktree,
so the snapshot in step 1 protects that worktree's uncommitted work in exactly the same way.

## 5. Behavioral requirements

### 5.1 Removals

The following are removed wherever bare writes make them unnecessary:

- The `jj edit` / write / `jj commit` / `jj bookmark set` / restore dance, in the library helper and
  all eight hand-rolled duplicates.
- Target-worktree resolution used solely to decide whose working copy to borrow.
- `current_bookmark` / `current_worktree` values threaded through commands purely to support restoring
  the working copy afterwards.
- Best-effort restore steps of the form `jj edit "$original_rev" 2>/dev/null || true`.

Worktree lookup is retained where it is genuinely informational — reporting which worktree has a task
checked out, worktree listing, and out-of-sync reporting.

### 5.2 Hardening

- Every branch-setting operation targets an explicit revision. No operation may depend on the working
  copy happening to sit where a previous step left it.
- No VCS mutation may be silently ignored on failure. Failures propagate to the caller, which decides
  how to report them and whether to roll the transaction back.

### 5.3 Preconditions

A dirty working copy is a user's work in progress, not an invalid state, and bare writes are unaffected
by it. Clean-working-copy preconditions that existed only because the command was about to borrow the
working copy are therefore removed, so those commands work mid-implementation.

Cleanliness is still required where it protects real semantics: `tt task checkin`'s validation of the
unmerged range, `tt task checkpoint`'s requirement that there be work to snapshot, and the commands
that carry the working-copy commit through a rewrite of existing history — `tt task rename` and
`tt task move`.

The exact per-command list is settled during planning.

### 5.5 Working-copy position

The tool's model keeps the working-copy commit as a *child* of the branch it is working on. The state
in which the working-copy commit *is* a branch tip is reachable only by driving the backend directly,
and it is incompatible with bare writes: capturing the working copy would rewrite the branch tip and
absorb unrelated uncommitted work into the branch.

Every mutating command therefore refuses to start while the working-copy commit carries a branch,
whatever the state of the working copy, and directs the user to move off it first. The check covers any
branch, not merely the one being written, and admits no exemptions.

### 5.4 Transactions

The `.tt/history` transaction log and its begin/commit/rollback lifecycle move to `lib/history.sh`.
They are built on two backend primitives — read the current operation ID, and restore to an operation.
The transaction log format and semantics are unchanged.

## 6. Diagnostics

`TT_VERBOSE=1` enables VCS tracing: the full command line of each backend invocation is echoed to
stderr before execution, and the invocation's own output is forwarded to stderr rather than discarded.
Unset or any other value keeps VCS output suppressed. The variable affects diagnostics only; it never
changes command output on stdout or exit status. It is documented in DEVELOPER.md.

## 7. User-facing changes

### 7.1 New command: `tt worktree sync`

```
tt worktree sync [<worktree-path>] [--all] [--repo PATH]
```

- Brings a worktree forward onto the head of the branch it is checked out on, updating its working copy
  to match. Uncommitted changes are snapshotted before the move and are preserved.
- With no argument, targets the worktree containing the current working directory; errors if the CWD
  is not within a known worktree.
- With `--all`, synchronizes every out-of-sync worktree in the repository — pairing with the
  out-of-sync warning, which may name several. Each worktree is synchronized by an operation running
  inside it, per §4.5.
- Errors if the given path is not a known worktree of the repository.
- Reports what changed (files added, modified, removed), or that the worktree was already up to date.
- Uncommitted changes in the target worktree are preserved.
- Runs within a transaction and runs the same hooks as other mutating worktree commands, for
  consistency with `tt worktree switch`.
- Documented in DESIGN.md alongside the other `worktree` commands, with its own test suite at
  `scripts/cli/worktree/sync.test.sh`.

### 7.2 Out-of-sync reporting

Mutating commands that leave worktrees other than the current one behind the branch emit the warning
described in §4.5 to stderr. It is advisory: the command still succeeds.

### 7.3 Relaxed preconditions

The commands listed in §5.3 no longer require a clean working copy. DESIGN.md is updated accordingly.

### 7.4 `tt task revset`

The command's external surface is unchanged: `--git` still selects a commit-ID range and its absence
still selects the backend-native range expression. Internally, the flag selects a required
`<native|git>` format argument passed to a backend range-formatting operation, so the syntax of each
form is owned by the backend rather than the command.

### 7.5 New error conditions

Operating on a repository whose backing store is not Git fails with
`Unsupported repository backend: <type>`.

Starting a mutating command while the working-copy commit is itself a branch tip fails with a message
naming that branch and the remedy (§5.5).

## 8. Testing requirements

### 8.1 Suite organization

One test suite per module, co-located with it: `lib/vcs/jj.test.sh`, `lib/frontmatter.test.sh`,
`lib/path.test.sh`, `lib/string.test.sh`, `lib/commit.test.sh`, `lib/task.test.sh`, and so on.

The existing `lib/common.test.sh` cases are relocated into whichever suite now owns the function under
test. `common.test.sh` is removed once empty.

All suites follow existing conventions: source the harness, define `test_<function>__<scenario>`
functions, end with a single `run_tests "<suite title>"` call.

### 8.2 VCS backend coverage

`lib/vcs/jj.test.sh` covers every `_jj_*` function on both its happy path and its failure path, plus
explicit scenarios for the hazards this refactor exists to eliminate:

- Writing to a branch while the current worktree has uncommitted changes preserves those changes and
  does not include them in the created commit.
- A mutating command refuses when the working-copy commit carries a branch — including when the working
  copy is clean, and when the branch is unrelated to the command's target.
- The current worktree is reattached to the new commit when its working-copy commit descended from the
  previous tip, and left alone otherwise.
- Writing to a branch that is checked out in another worktree leaves that worktree untouched and fully
  usable, reports it as out of sync, and preserves its uncommitted changes — including changes that had
  never been snapshotted.
- Synchronizing a behind worktree brings it onto the branch head and preserves its uncommitted changes.
- Symlink creation, retargeting and deletion round-trip correctly through a bare write.
- Executable and regular file modes are preserved.
- Deletions remove paths from the resulting commit.
- Created commits carry the identity the backend is configured with, even when the ambient Git identity
  differs.
- A repository whose backing store is not Git fails with the specified message.
- Branch-setting operations target the intended revision regardless of where the working copy sits.

### 8.3 Regression bar

The full test suite must pass. Existing command suites are expected to pass unmodified; where bare
operations legitimately change observable state — the working copy no longer moves, `@` stays put,
fewer intermediate commits are produced — the affected assertions are updated, and each such change is
called out explicitly as intended rather than absorbed silently.

## 9. Documentation requirements

| Document | Content |
| --- | --- |
| `ARCHITECTURE.md` (new, repository root) | The four layers and what each may call; the `_<namespace>_<verb>_<noun>` naming rule; the module inventory with one-line responsibilities; the full list of operations a backend must implement; the working-copy-bound exceptions and why they exist. |
| `DESIGN.md` | User-facing changes only: `tt worktree sync`, the relaxed preconditions, the out-of-sync warning, the unsupported-backend error. Internal layering is deliberately excluded. |
| `DEVELOPER.md` | The library module layout, how to run the new per-module suites, and `TT_VERBOSE`. |
| Module headers | Each module states its responsibility and its public surface. |

## 10. Delivery

A single task branch with incremental checkpoint commits — one per module extracted or command group
migrated — running the relevant test suites between each. No sub-task tree.

Each module's public API is designed deliberately rather than transplanted: the module's surface is
defined first, then behavior is ported into it.

## 11. Acceptance criteria

1. No file outside `lib/vcs/` invokes `jj`. No file outside `lib/` calls a `_vcs_*` function.
2. No `jj` revset or template string appears outside `lib/vcs/jj.sh`.
3. Every library function follows the `_<namespace>_<verb>[_<noun>]` convention and lives in the module
   matching its namespace.
4. `lib/common.sh` contains only `source` directives.
5. All file-content mutations are bare; the working-copy dance and its supporting machinery are gone
   except for the three documented working-copy-bound commands.
6. Every backend function accepts the repository root as its first argument, honours `TT_VERBOSE`, and
   reports failure by exit status without logging or exiting.
7. `tt worktree sync` exists, is documented and is tested.
8. Every module has a test suite; `lib/vcs/jj.test.sh` meets the coverage bar in §8.2.
9. The full test suite passes, with every changed assertion justified as an intended behavioral change.
10. `ARCHITECTURE.md` exists and documents the layering, naming convention and backend contract;
    DESIGN.md and DEVELOPER.md are updated per §9.
