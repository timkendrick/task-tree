# Architecture: the tt bootstrap CLI

This document describes the internal structure of the bootstrap CLI under `scripts/cli/`. It is a
developer-facing companion to `DESIGN.md`, which describes what the tool does from the outside.

## 1. Layering

The CLI is organised into four tiers with one-directional dependencies:

```
scripts/cli/**                 commands — argument parsing, control flow, user-facing output
      ↓
lib/{task,workspace,           semantic facades — the task, workspace, worktree and
     worktree,history}.sh      history models, expressed in domain terms
      ↓
lib/repo.sh                    backend-neutral VCS interface (_repo__*)
      ↓
lib/vcs/jj.sh                  backend implementation (_jj__*) — the only place `jj`
                               or `git` is invoked
```

Utility modules — `ui`, `string`, `format`, `path`, `frontmatter`, `commit`, `hook` — sit beside the
facades. They are callable from any tier and perform no VCS access of their own.

| Tier | May call | May not call |
| --- | --- | --- |
| Commands | facades, utilities | `_repo__*`, `_jj__*`, `jj`, `git` |
| Facades | `_repo__*`, other facades, utilities | `_jj__*`, `jj`, `git` |
| `lib/repo.sh` | `_jj__*` | — |
| `lib/vcs/jj.sh` | `jj`, `git`, utilities | facades, commands |
| Utilities | other utilities | any VCS access |

The facades may call one another — writing a task file to a branch has to reattach the current
worktree, and listing worktrees has to name the task each one holds — so there is no ordering
between them, only the shared rule that VCS backend actions are invoked via the `_repo__*` facade.

## 2. Module inventory

`lib/common.sh` is the single entry point every command sources. It contains nothing but `source`
directives, in dependency order:

| Module | Responsibility |
| --- | --- |
| `ui.sh` | Diagnostic logging, command execution and tracing, editor prompts, interactive selection |
| `string.sh` | Slugs, slug validation, hex identifiers, timestamps |
| `format.sh` | Value formatting shared across commands |
| `path.sh` | Repo-relative path construction, symlink resolution, metadata exclusions |
| `frontmatter.sh` | Task and context file frontmatter parsing and rewriting |
| `commit.sh` | `[tt:<ns>:<id>:<op>]` commit message construction and parsing |
| `hook.sh` | Hook discovery, environment and the blocking/non-blocking exit contract |
| `repo.sh` | The backend-neutral VCS interface and the backend contract |
| `vcs/jj.sh` | The jj backend — the only caller of `jj` and `git` |
| `history.sh` | The `.tt/history` transaction log; begin, commit, rollback |
| `task.sh` | The task model: branch classification, current-task resolution, parent lookup, task ranges, staged writes onto branches |
| `workspace.sh` | Repository resolution, `.tt/config.toml`, the workspace directory and `HEAD` symlinks |
| `worktree.sh` | The worktree model: lifecycle, working-copy invariants, reattachment, sync, out-of-sync reporting |

Every module header states its own responsibility and lists its public surface. Those headers are
authoritative for the individual functions; this document covers only the structure around them.

## 3. Naming convention

Every library function is named:

```
_<namespace>__<verb>[_<noun>]
```

- A leading underscore marks it as a library function rather than a command-local helper.
- `<namespace>` is the module name, followed by a **double** underscore: `_frontmatter__`, `_path__`,
  `_task__`, `_repo__`, `_jj__`.
- `<verb>` follows immediately and names the action.

Examples: `_frontmatter__parse_field`, `_path__resolve_symlinks`, `_repo__read_file_at_revision`,
`_worktree__reattach_current`, `_history__begin_transaction`.

A **leading** double underscore — `__jj__read`, `__worktree__list_behind` — marks a helper private
to its own module. Those are not part of any public surface and have no wrappers in `lib/repo.sh`.

Names describe **what** an operation does, never how a backend achieves it. `_repo__create_worktree`,
not `_repo__add_jj_workspace`; `_repo__find_fork_point_commit`, not `_repo__run_fork_point_revset`.

## 4. The backend contract

`lib/repo.sh` sources the backend and declares one wrapper per operation:

```bash
_repo__read_file_at_revision()  { _jj__read_file_at_revision "$@"; }
_repo__commit_changeset()       { _jj__commit_changeset "$@"; }
_repo__create_worktree()        { _jj__create_worktree "$@"; }
```

The wrapper block is a 1:1 name mapping in which only the namespace differs, and it doubles as the
machine-readable contract: a backend must implement a same-suffix function for every wrapper, and
neither side may carry an operation the other lacks. Dispatch is static — there is no `eval`, no
indirection and no backend-selection environment variable. Adding a backend means adding a file of
`_<backend>__*` functions and repointing the wrapper targets.

### 4.1 Conventions

Every backend function:

1. Takes the repository root — or, for the working-copy group, the worktree root — as its **first
   argument**.
2. Returns its result on stdout. Query helpers returning more than one field per record emit
   line-oriented, tab-separated records in a documented column order, so a different backend can
   produce the same shape.
3. Reports failure by **exit status only**. It never logs and never exits; the caller decides whether
   a failure is fatal and what to say about it. The one exception is the unsupported-backend check,
   whose stderr message is part of its contract.
4. Honours `TT_LOG` (§4.3).
5. Performs a **bare** repository operation (see below).

#### Bare by default

When jj runs a command that loads the working copy, it records any on-disk changes into the
working-copy commit first, and rewrites the files on disk afterwards to match wherever the working
copy ended up. `--ignore-working-copy` turns off both halves.

Almost nothing wants either half: reading a revision or rewriting the commit graph should not quietly
capture the user's unsaved work, nor add an operation-log entry for having done so. So the rule is:

> Every operation passes `--ignore-working-copy`, except those in the **Working copy** group, which
> exist precisely to read or move a working copy.

Two operations outside that group are also exceptions, each documented at the function itself:
`restore_operation` (an undo must rewrite the files on disk, and the snapshot it takes on the way is
what makes the discarded work recoverable from the operation log) and `create_worktree` (creating a
worktree means writing its files, and jj rejects the flag outright).

The consequence for callers is that **a question whose answer depends on uncommitted work must be
asked through the working-copy group**, not of a bare operation. `check_working_copy_clean` counts
pending on-disk edits as dirt because it snapshots; `check_commit_empty` asked about `@` does not,
and will call a dirty working copy empty. The facades expose the former as
`_worktree__check_clean`, so callers ask the question rather than assembling it.

No revset expression and no template string may appear outside `lib/vcs/jj.sh`. Every query is a
named operation taking domain arguments, with the backend syntax held inside the backend. There is no
raw-revset escape hatch.

### 4.2 Operations

Signatures, argument conventions and return values are documented on the backend implementations in
`lib/vcs/jj.sh`; the tables below give the shape of the contract.

#### Repository discovery

| Operation | Purpose |
| --- | --- |
| `check_is_repository` | Whether a directory is a repository |
| `find_repository_root` | Walk up from CWD to the enclosing repository |
| `resolve_repository_root` | Canonical repository root behind any worktree |
| `resolve_repository_path` | The same, with symlinks resolved |
| `get_backend_type` | Storage backend identifier |
| `check_backend_supported` | Whether the storage backend is supported |

#### Operation log

| Operation | Purpose |
| --- | --- |
| `get_operation_id` | Current operation ID |
| `restore_operation` | Restore the repository to a prior operation |

#### Revisions

| Operation | Purpose |
| --- | --- |
| `get_commit_description` | Full description of a revision |
| `resolve_commit` | Immutable commit ID of a revision |
| `resolve_change` | Stable change ID of a revision |
| `get_commit_timestamp` | Committer timestamp, ISO 8601 UTC |
| `check_revision_exists` | Whether a revision resolves |
| `check_commit_empty` | Whether a revision changes no files |
| `check_has_conflicts` | Whether a revision has conflicts |
| `check_descendants_have_conflicts` | Whether a revision or any descendant has conflicts |
| `check_range_has_conflicts` | Whether any commit in a range has conflicts |
| `check_is_ancestor` | Whether one revision is an ancestor of another |
| `filter_commits_reachable_from` | Which of the given commits a revision can reach |
| `find_fork_point_commit` | Where two revisions' histories diverge |
| `resolve_nearest_bookmark` | Commit ID and name of the closest bookmarked ancestor of a revision |
| `check_is_canonical_commit_id` | Whether text has the form of a full commit ID, so it needs no resolution |
| `list_commits_in_range` | Commit IDs in a range, oldest first |
| `list_commits_in_dag_range` | Commits descended from a base, up to a tip |
| `count_commits_in_range` | Size of a range |
| `list_range_root_commits` | The roots of a range |
| `check_range_covered` | Whether a range lies inside a union of ranges |
| `format_revision_range` | Render a range in a named format (`native` or `git`) |
| `list_mainline_commits` | First-parent mainline commit records |

#### Task-range queries

| Operation | Purpose |
| --- | --- |
| `find_file_introduction` | The commit that introduced a file |
| `find_prefix_introduction` | The commit that introduced a path prefix |
| `list_descendant_changes` | Change IDs of a revision and its descendants |
| `list_file_waypoints` | Commits touching a target/marker file pair |
| `sort_commits_by_ancestry` | Order commit IDs oldest first within a region |

#### Bookmarks

| Operation | Purpose |
| --- | --- |
| `set_bookmark` | Move a bookmark to an **explicit** revision |
| `list_bookmark_names` | Every local bookmark name |
| `list_bookmarks_at` | Bookmark names at a revision |
| `check_bookmark_exists` | Whether a bookmark exists |
| `rename_bookmark` | Rename a bookmark |
| `delete_bookmark` | Delete a bookmark |

`set_bookmark` always requires a target revision. There is no implicit-target form, so no operation
can depend on the working copy happening to sit where a previous step left it.

#### Files

| Operation | Purpose |
| --- | --- |
| `read_file_at_revision` | File content at a revision |
| `read_symlink_at_revision` | Symlink target at a revision |
| `read_file_at_operation` | File content at an operation and revision |
| `check_file_exists_at_revision` | Whether a file exists at a revision |
| `list_files_at_revision` | Tracked files at a revision |
| `list_files_at_operation` | Tracked files at an operation and revision |
| `list_changed_files` | Files a revision changes against its parents |
| `list_changed_files_in_range` | Files a range changes against its base |
| `get_file_diff` | Git-format diff of one file at a revision |
| `show_diff` | Git-format diff between two revisions |

#### Mutations (bare)

No working copy is involved in any of these; each rewrites the commit graph directly.

| Operation | Purpose |
| --- | --- |
| `commit_changeset` | Build a commit from a staging directory plus a deletion list |
| `create_merge_commit` | Create a merge commit over two or more parents |
| `set_description` | Replace a revision's description |
| `move_commits` | Rebase revisions and their descendants onto a destination |
| `squash_commit` | Fold one revision's changes into another |
| `restore_tree` | Set a revision's tree wholesale from another, preserving its identity |
| `abandon_commit` | Abandon a revision, rebasing descendants onto its parents |

#### Worktrees

| Operation | Purpose |
| --- | --- |
| `resolve_worktree_root` | Worktree root for the current context |
| `list_worktrees` | One record per worktree |
| `create_worktree` | Add a worktree at a path, started on a revision |
| `forget_worktree` | Remove a worktree from the repository model |
| `get_worktree_revision` | A worktree's working-copy commit |

#### Working copy (restricted)

These take a **worktree root** and execute with the process working directory inside it. Only
`lib/worktree.sh` and the working-copy-bound commands of §7 may reach them.

| Operation | Purpose |
| --- | --- |
| `check_working_copy_clean` | Whether the working copy has pending changes |
| `get_working_copy_revision` | Change ID of the working-copy commit |
| `get_working_copy_parent` | Commit ID of its parent |
| `set_working_copy_revision` | Point the working copy at a revision |
| `new_working_copy_child` | Start a new working-copy commit |
| `commit_working_copy` | Record the working copy as a commit |
| `snapshot_worktree` | Capture on-disk changes into the working-copy commit |
| `reattach_worktree` | Rebase the working-copy commit onto a destination |
| `refresh_worktree` | Update on-disk files after a bare rewrite of the working-copy commit |

### 4.3 Tracing

`TT_LOG` selects how much of the backend's activity is narrated to stderr: `info` reports the
mutations a user would recognise as the point of the command, and `verbose` adds reads and internal
plumbing. See DEVELOPER.md for the user-facing description.

Every `jj` and `git` invocation in the backend goes through one of four internal runners, each of
which names the level at which the invocation becomes worth narrating and whether its stdout is the
caller's return value:

| Runner | Level | Stdout |
| --- | --- | --- |
| `__jj__read` | verbose | captured |
| `__jj__write` | info | not captured |
| `__jj__write_internal` | verbose | not captured |
| `__jj__git` | verbose | captured |

The level is an editorial judgement recorded per call site, not a mechanical property of the
operation — which is why a routine task edit traces one line at `info` rather than the eight steps
that produce it.

"Captured" means the invocation's stdout is the caller's return value and is never redirected, at any
level. "Not captured" means the caller does not want it: it is shown as diagnostics when the level is
active and discarded otherwise.

All four runners delegate to a single executor, `_ui__run_command`, which logs and then runs the same
argument vector. The log line and the executed command therefore cannot drift apart, and the level
cannot change behavior: whether stdout is captured is fixed by the caller's output policy rather than
by the level, and the exit status is always the underlying command's. What the level does change is
where output the caller did not want ends up — stderr when tracing, `/dev/null` when not.

## 5. Bare writes

Writing a file into a commit normally requires a working copy. `commit_changeset` does it without
one, by building the commit directly in the Git object store that backs the repository.

A changeset is expressed as two orthogonal inputs:

- a **staging directory** whose layout mirrors repository-root-relative paths, holding the files to
  create or replace, with symlinks present as real symlinks; and
- an explicit **deletion list** naming individual repository-root-relative file paths.

The staging directory is a *sparse overlay*: it expresses only the paths that change, and everything
else is inherited from the parent commit. A file merely being absent from it is therefore **not** a
deletion — removals are always declared. Deletion entries name exact files; a caller removing a
directory enumerates its contents first.

```
verify the backing store is git, else fail "Unsupported repository backend: <type>"
resolve GIT_DIR from the store pointer

blobs  ← hash every staged regular file into the object store, in one call
stream ← a fast-import commit: the parent revision as its base, the
         repository-configured identity rather than the ambient git identity,
         then for each deletion path:   D path
         then for each staged file:     M 100755|100644 <blob> path
         then for each staged symlink:  M 120000 inline path, with the link target
commit ← run fast-import over the stream; it writes the tree and the commit and
         points a uniquely named temporary ref at the result
import the ref so the backend learns the commit, then drop the ref, forget the
bookmark it became, and reconcile the deletion within the same transaction
```

Deletions are applied before the overlay, so one call may delete a path and stage a replacement
beneath the same prefix. Granularity is one bare commit per logical tt commit; a command writing to
two branches makes two calls.

No working tree or index is involved on either side: the tree is described to a single
`fast-import` run rather than assembled through per-file plumbing, and a result this small is
unpacked into loose objects, so the store does not gain a packfile per commit. Reconciling the
temporary ref's deletion is part of the operation rather than a follow-up: leaving it unreconciled
makes the *next* command mint a surprise import operation outside any tt transaction, which would
break undo integrity.

The facade wrapper is `_task__commit_on_branch`, which resolves the branch tip, materialises any
files the caller wants to read-modify-write, expands delete-prefixes into exact paths, runs the
caller's writer function against the staging directory, commits, reattaches the current worktree,
and only then advances the bookmark.

That order matters, because the bookmark advance is what makes the write visible: everything before
it can still be abandoned. The caller may also ask for the branch-aware reattachment variant, which
is what a command passes when the branch it is writing may be an *ancestor* of the branch the
invoking worktree is on: plain descent cannot tell the line that moved from a line that forked off it
further back, and would drag the worktree onto the wrong branch. That variant asks which branch the
worktree is on (§6.3) before applying the descent test; the plain variant tests ancestry alone.

### 5.1 Merge parent order

Every merge tt creates lists **the receiving branch first and the incoming line second**. Check-in
and publish merge a handoff into the branch that receives it; `tt task propagate --merge` merges a
parent's tip into the child that receives it. `_task__merge_branch` is the single facade that builds
them, and it takes the receiving tip as its first parent argument.

The order is load-bearing, not cosmetic. A branch's own line is its **first-parent mainline**, and
anything reachable only through a second parent arrived from somewhere else. Two mechanisms read the
graph that way:

- **Full-range discovery** (`_task__get_full_range_records`) classifies historical check-ins by the
  shape of a merge's second parent, so a handoff must never appear first.
- **Mainline listing** (`list_mainline_commits`, behind `tt task changelog`) reports a branch's own
  work by following first parents, and would otherwise attribute the merged-in branch's commits to
  the receiving branch.

A merge built with the parents reversed would silently misreport both, so the order is asserted in
the test suites of the three commands that create merges.

### 5.2 Constraints

- **bash 3.2.** The only interpreter available on macOS is bash 3.2, so `mapfile`/`readarray` and
  associative arrays (`declare -A`) are unavailable. Keyed lookups use parallel arrays or files in a
  scratch directory.
- **Paths containing newlines are out of scope.** Staged files are iterated line-by-line from `find`
  output. tt paths are slugs and fixed filenames, so this is not a practical restriction.
- **The backing store must be Git.** Anything else fails with `Unsupported repository backend:
  <type>`. There is no fallback to a working-copy write path.

## 6. Working-copy rules

### 6.1 A working copy is only rewritten from inside its own worktree

Rewriting a worktree's working-copy commit from outside moves a commit that does not yet contain
that worktree's uncommitted changes; the subsequent working-copy update then deletes them.

For a **branch write** the rule holds by construction, because no working copy is involved at all:

- The command snapshots **its own** worktree at the start of its transaction, so pending changes are
  captured before anything is rewritten.
- The bare write proceeds with no working copy involved.
- Afterwards, the command reattaches its own worktree if the working-copy commit descended from the
  branch's previous tip, and leaves it alone otherwise.
- Worktrees other than the invoking one are neither written to nor rewritten. They are left behind
  and reported (§6.3).

The commands that rewrite **existing history** rather than appending to a branch cannot get the rule
for free, and each handles it explicitly:

- `tt task move` and `tt task propagate` rebase a task's unmerged range. Roots whose subtree does not
  contain the invoking worktree's working-copy commit are moved as a bare graph rewrite; a root the
  working copy sits above is moved *through* that worktree instead, so its on-disk files travel with
  the commits rather than being left behind. Bare roots are moved first, so the carried subtree is
  rewritten last against a graph that is otherwise final.
- `tt task rename` rewrites every commit carrying the task directory, a set that necessarily spans
  commits the invoking worktree does not own. It therefore **refuses** when any other worktree's
  working-copy commit lies inside that set, naming each blocking worktree. There is no override:
  rewriting them would destroy uncommitted work there.

### 6.2 The working-copy commit must not carry a bookmark

tt's model keeps the working-copy commit as a *child* of the branch it is working on. The state in
which it *is* a branch tip breaks both halves of the mechanism above:

- **Snapshotting contaminates the branch.** A bookmark pointing at a rewritten commit follows it, so
  capturing the working copy would absorb unrelated uncommitted work into the branch tip.
- **Reattachment silently does nothing.** The working-copy commit counts as a descendant of the tip,
  so a naive descends-from test reports success, but there is no commit above the tip left to move.

Every branch-writing command therefore refuses to start while the working-copy commit carries a
bookmark, whatever the state of the working copy. The scope is **any** bookmark, not merely the
branch being written, because the contamination hazard is the same for all of them.
`_worktree__ensure_working_copy` implements the check, and each command calls it from its
precondition block — before the transaction opens, and therefore before the snapshot that would do
the damage. `tt workspace init` is exempt: it advances no bookmark and performs no branch write.

The check is deliberately **not** folded into `_history__begin_transaction`. Recognising a branch tip
requires knowing tt's branch model, and the history module's responsibility is the `.tt/history`
log; embedding the invariant there would make the undo log unreadable without also understanding
tt's branching conventions. The snapshot itself does belong to the transaction: capturing a working
copy needs no knowledge of branches, and it must happen after the before-operation ID is recorded
for `tt history undo` to restore uncommitted work faithfully.

### 6.3 Out-of-sync worktrees

Because only the invoking worktree is reattached, a write to a branch leaves any other worktree on
that branch sitting on the previous tip. Such a worktree is **behind**, not broken: fully usable, and
still descending from where it was. The command output reports a hint to re-sync the affected branches.

Reporting a behind worktree, and later syncing it, both need the branch it is **on**, which the
bookmarks no longer say: the write moved the bookmark to a sibling of the worktree's working-copy
commit, so the nearest bookmarked ancestor degrades to some outer branch.

The answer is **read, not inferred**. A worktree's working copy carries the task symlink
`tt task checkout` plants in it — `TASK.md -> .tt/task/<suffix>/TASK.md` — and branch names *are*
task IDs, so the symlink recorded in the working-copy commit names the branch outright.
`_worktree__resolve_branch_at` reads it and maps the suffix to whichever of the task or project
bookmarks exists. A working copy recording no such symlink, or naming a task with no bookmark, is on
**no** branch: it is reported as such, and `tt worktree sync` refuses rather than guessing.

The commit graph cannot answer this question, which is why tt does not ask it. A working copy is
parked as an empty child of a branch tip, so the branch is whichever one owned that tip — and a
branch advancing past a commit has the same shape as a branch forked from it: a bookmark ending a
chain whose first-parent line runs through that commit. What separates the two is which bookmark
pointed there at the time, which is history, not shape. Any ranking of the bookmarks around a working
copy is therefore guesswork, and guesses wrongly as soon as a commit acquires several bookmarked
descendants — which propagation, check-in and task creation all produce.

## 7. Working-copy-bound commands

Three commands legitimately require a working copy, and only they may reach the restricted
operations of §4.2:

| Command | Why |
| --- | --- |
| `tt task checkpoint` | Snapshots the user's real, uncommitted work |
| `tt task checkout` | Moves the working copy and populates a new worktree |
| `tt workspace init` | Commits the initial workspace state before any branch exists |

`tt worktree sync` also runs inside a worktree, but as the sanctioned mechanism of §6.3 rather than
as an exception to it.

Every other command that writes to a branch does so bare and leaves the working copy where it found
it. `tt history undo` is neither: it rewinds the whole repository to a recorded operation, which
moves the working copy and rewrites its files as a matter of course — which is why it requires a
clean working copy unless forced.

## 8. Transactions

Every mutating command wraps its work in a **transaction**, so that `tt history undo` can rewind it
and so that a failure part-way through leaves nothing half-applied. A transaction is one line in
`.tt/history`, holding the backend operation ID before the command ran and the one after it
finished:

```
_history__begin_transaction   record "<before-op>:" — an entry with no after-op
                              install the abort trap
                              snapshot the invoking worktree
   ... the command's writes ...
_history__commit_transaction  rewrite the entry as "<before-op>:<after-op>"
                              disarm the abort trap
```

An entry with no after-op means a command is in progress, and the next command to begin refuses
rather than interleave with it. That makes the closing of every transaction an invariant rather than
a tidiness: an entry left open is a lock nobody holds, and every later branch write fails against it
until `tt history undo --force` or `tt history unlock --force` clears it.

Sub-commands inherit `TT_TRANSACTION_ID` through the environment, so their own `begin` is a no-op and
the whole run — `tt task checkin --complete` invoking `complete`, say — records a single entry. Only
the process that opened the transaction owns it: `_TT_TRANSACTION_OWNER` is deliberately not
exported, so a sub-command can neither commit nor roll back its parent's work.

Closing a transaction releases the ID as well as the ownership flag. A command does not necessarily
stop when its own transaction commits — a check-in propagates to the sibling branches once the merge
has landed, and `--delete` removes the task afterwards — and that later work is still work that must
be recorded and unwound on failure. Leaving the ID set would make each of those sub-commands believe
it was nested: no entry of its own, no abort trap, and a failure that unwinds nothing.

### 8.1 Leaving a transaction open is not an option

`_history__begin_transaction` installs `__history__abort_transaction` on **ERR and EXIT**, and that
handler rolls back whenever the shell leaves with a transaction still open — whatever the exit
status. An open transaction means the command never reached its commit point, so its writes are
half-applied by definition; a zero exit with one open is a bug, and rolling back is what keeps it
from silently leaving the lock behind.

Both signals are needed, and the handler disarms both before doing anything:

- an ERR trap does not fire for `exit`, which is how every command reports a failed precondition, so
  ERR alone leaves the repository half-written;
- a command killed by `set -e` fires ERR *and then* EXIT, so without disarming both the rollback
  would run twice, and the handler's own `exit` would re-enter it.

The status that triggered the trap is captured first and re-raised last, so the command's exit code
survives the rollback.

A command that needs a cleanup of its own must not install a competing EXIT trap, since bash keeps
one handler per signal and the last one installed wins. Such cleanups run in a subshell that owns
its own trap instead — `tt task rename`'s staging directory and the staging area inside
`_task__commit_on_branch` are both handled that way.

### 8.2 What a rollback restores

Rolling back restores the backend operation recorded at `begin` and deletes the in-progress entry.
The restore also resets the working copy on disk, which would discard whatever the begin-time
snapshot captured, so the files the working-copy commit changed are copied aside first and put back
afterwards — but only when the restore lands on the same working-copy commit, since a transaction
that deliberately moved the working copy has no business putting the old files back. Preservation is
best-effort throughout: each step degrades to a plain restore, which is still recoverable from the
operation log.

Restoring an operation *creates* an operation, so after a rollback the repository's current operation
is not the one recorded as the previous transaction's after-op. Tests therefore assert that no
in-progress entry survives a failure, not that the log's tail matches the current operation.

## 9. Testing

Each module and command has a co-located `*.test.sh` suite; `scripts/test` discovers them
automatically. The backend suite, `lib/vcs/jj.test.sh`, is the load-bearing one: besides covering
each operation's happy and failure paths, it holds explicit scenarios for the hazards the layering
exists to prevent — writes that must not disturb a dirty working copy, reattachment that must fire
only when the working-copy commit descended from the old tip, foreign worktrees that must be left
untouched and reported, symlink and file-mode round-tripping, commit identity, and the
unsupported-backend refusal.

See DEVELOPER.md for how to run them.
