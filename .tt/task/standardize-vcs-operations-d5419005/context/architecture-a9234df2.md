---
title: "Architecture: Standardize VCS operations"
created: 2026-08-28T22:27:18Z
updated: 2026-08-28T22:27:18Z
---
# Architecture: Standardize VCS operations

Companion to `standardize-vcs-operations.requirements.md`. Records the structural decisions, the
verified mechanisms, and the API shapes the implementation will hinge on.

## 1. Layering

```
scripts/cli/**                 commands — argument parsing, control flow, user-facing output
      ↓
lib/{task,workspace,           semantic facades — task-tree operations in domain terms
     worktree,history}.sh
      ↓
lib/vcs.sh                     backend-neutral interface (_vcs_*)
      ↓
lib/vcs/jj.sh                  backend (_jj_*) — the only place `jj` or `git` is invoked
```

Utility modules (`ui`, `string`, `format`, `path`, `frontmatter`, `commit`, `hook`) sit beside the
facades and perform no VCS access.

| Layer | May call | May not call |
| --- | --- | --- |
| Commands | facades, utilities | `_vcs_*`, `_jj_*`, `jj`, `git` |
| Facades | `_vcs_*`, utilities | `_jj_*`, `jj`, `git` |
| `lib/vcs.sh` | `_jj_*` | — |
| `lib/vcs/jj.sh` | `jj`, `git` | facades, commands |
| Utilities | other utilities | any VCS access |

## 2. Module inventory

`lib/common.sh` contains nothing but `source` directives, in dependency order:

```
ui → string → format → path → frontmatter → commit → hook
   → vcs (→ vcs/jj) → history → task → workspace → worktree
```

| Module | Responsibility |
| --- | --- |
| `ui.sh` | `log`, prompts, colour handling (`NO_COLOR`), interactive selection |
| `string.sh` | Slugification, slug validation, hex and timestamp generation |
| `format.sh` | Output rendering shared across commands: status checkboxes, tree indentation, task lines |
| `path.sh` | Repo/workspace path resolution, symlink resolution, `.tt/` metadata and task file paths, metadata exclusion sets |
| `frontmatter.sh` | Frontmatter parsing, field extraction, ordered insertion and mutation |
| `commit.sh` | `[tt:<ns>:<id>:<op>]` message construction and parsing |
| `hook.sh` | Hook discovery, environment construction, invocation and exit-code contract |
| `vcs.sh` | `_vcs_*` interface; static 1:1 wrappers over the backend; the backend contract |
| `vcs/jj.sh` | jj backend implementation |
| `history.sh` | `.tt/history` transaction log; begin/commit/rollback |
| `task.sh` | Task-domain semantics: current task resolution, branch↔task mapping, parent lookup, task ranges, task-file reads and writes |
| `workspace.sh` | Virtual project directory, `.tt/config.toml`, `HEAD` and `.tt/workspace` symlinks |
| `worktree.sh` | Worktree lifecycle, reattachment, sync, out-of-sync reporting, working-copy position invariant |

## 3. Naming

`_<namespace>_<verb>[_<noun>]` — leading underscore, module name, then a verb.
`_frontmatter_parse_field`, `_path_resolve_task_file`, `_vcs_read_file_at_revision`,
`_worktree_reattach_current`, `_history_begin_transaction`.

Names describe intent, never mechanism: `_vcs_create_worktree`, not `_vcs_add_jj_workspace`.

## 4. Backend contract

`lib/vcs.sh` declares one wrapper per operation, which doubles as the contract a second backend must
satisfy:

```bash
. "$_TT_LIB_DIR/vcs/jj.sh"

_vcs_read_file_at_revision()  { _jj_read_file_at_revision "$@"; }
_vcs_commit_changeset()       { _jj_commit_changeset "$@"; }
_vcs_create_worktree()        { _jj_create_worktree "$@"; }
# ...
```

Every operation takes the repository (or worktree) root as its first argument, returns data on stdout,
signals failure by exit status without logging, and honours `TT_VERBOSE`.

### Repository

| Operation | Returns |
| --- | --- |
| `_vcs_resolve_repository_root PATH` | canonical repo root for any workspace root |
| `_vcs_get_backend_type REPO` | backing-store identifier |
| `_vcs_check_backend_supported REPO` | status only |

### Operation log

| Operation | Returns |
| --- | --- |
| `_vcs_get_operation_id REPO` | current operation ID |
| `_vcs_restore_operation REPO OP_ID` | status only |

### Revisions

| Operation | Returns |
| --- | --- |
| `_vcs_get_commit_id REPO REV` | commit ID |
| `_vcs_get_change_id REPO REV` | change ID |
| `_vcs_get_commit_description REPO REV` | full description |
| `_vcs_check_revision_exists REPO REV` | status only |
| `_vcs_check_commit_empty REPO REV` | status only |
| `_vcs_check_has_conflicts REPO REV` | status only |
| `_vcs_check_descendants_have_conflicts REPO REV` | status only |
| `_vcs_check_is_ancestor REPO ANCESTOR DESCENDANT` | status only |
| `_vcs_find_fork_point REPO REV_A REV_B` | commit ID |
| `_vcs_find_nearest_bookmark REPO REV` | bookmark name |
| `_vcs_list_commits_in_range REPO FROM TO` | commit IDs, oldest first, `FROM` exclusive |
| `_vcs_count_commits_in_range REPO FROM TO` | integer |
| `_vcs_list_range_roots REPO FROM TO` | commit IDs of the range's roots |
| `_vcs_list_mainline_commits REPO BASE TIP` | TSV: commit, change, timestamp, parents, subject |
| `_vcs_format_revision_range REPO FORMAT FROM TO` | range expression; `FORMAT` is `native` or `git` |

### Bookmarks

`_vcs_list_bookmarks REPO` · `_vcs_list_bookmarks_at REPO REV` · `_vcs_check_bookmark_exists REPO NAME` ·
`_vcs_set_bookmark REPO NAME REV [--allow-backwards]` · `_vcs_rename_bookmark REPO OLD NEW` ·
`_vcs_delete_bookmark REPO NAME`

`_vcs_set_bookmark` always requires an explicit revision; there is no implicit-target form.

### Files

`_vcs_read_file_at_revision REPO REV PATH` · `_vcs_read_file_at_operation REPO OP REV PATH` ·
`_vcs_check_file_exists_at_revision REPO REV PATH` · `_vcs_list_files_at_revision REPO REV [PREFIX]` ·
`_vcs_list_files_at_operation REPO OP REV [PREFIX]` ·
`_vcs_show_diff REPO FROM TO [EXCLUDE_PREFIX...]`

### Mutations

| Operation | Returns |
| --- | --- |
| `_vcs_commit_changeset REPO PARENT_REV MESSAGE STAGE_DIR [DELETE_PATH...]` | new commit ID |
| `_vcs_create_merge_commit REPO MESSAGE PARENT_REV...` | new commit ID |
| `_vcs_set_description REPO REV MESSAGE` | status only |
| `_vcs_move_commits REPO SOURCE_REV DEST_REV` | status only |
| `_vcs_squash_commit REPO FROM_REV INTO_REV` | status only, destination identity preserved |
| `_vcs_restore_tree REPO SOURCE_REV TARGET_REV` | status only; sets the target's tree wholesale, preserving its identity, and preserves descendant content when rebasing them |
| `_vcs_abandon_commit REPO REV` | status only |

### Worktrees

`_vcs_create_worktree REPO NAME PATH REV` · `_vcs_forget_worktree REPO NAME` ·
`_vcs_list_worktrees REPO` (TSV: name, root) · `_vcs_resolve_worktree_root PATH` ·
`_vcs_get_worktree_revision REPO NAME`

### Working copy — restricted

These take a **worktree root** and execute with the process working directory inside it. Only
`worktree.sh` and the three working-copy-bound commands may call them.

`_vcs_snapshot_worktree WORKTREE` · `_vcs_get_working_copy_revision WORKTREE` ·
`_vcs_get_working_copy_parent WORKTREE` · `_vcs_check_working_copy_clean WORKTREE` ·
`_vcs_set_working_copy_revision WORKTREE REV` · `_vcs_commit_working_copy WORKTREE MESSAGE` ·
`_vcs_squash_working_copy WORKTREE FROM_REV` · `_vcs_reattach_worktree WORKTREE FROM_REV DEST_REV`

## 5. Bare write mechanism

`_jj_commit_changeset` builds a commit without any working copy, using the Git backing store.

```
resolve GIT_DIR  ← .jj/repo/store/git_target, resolved relative to .jj/repo/store/
verify backing store is git, else fail "Unsupported repository backend: <type>"

index ← read-tree PARENT_REV
for each DELETE_PATH:            index ← remove path
for each file in STAGE_DIR:      mode ← 120000 symlink | 100755 executable | 100644 regular
                                 blob ← hash-object (symlink: its target string)
                                 index ← add (mode, blob, path)
tree ← write-tree index
commit ← commit-tree tree -p PARENT_REV -m MESSAGE     with author/committer identity
                                                        taken from the backend's configuration
write temporary ref → import → drop temporary ref and bookmark
```

Deletions are applied before the staging overlay, so removing a prefix and writing a path beneath it
is well defined.

Author and committer identity must be set explicitly from the backend's configured user, because the
ambient Git identity can differ from it.

**Verified:** file creation and replacement; symlink creation and retargeting; executable mode;
deletion; two-parent commits; identity; temporary-ref cleanup leaving no stray bookmarks; and complete
non-interference with dirty working copies in every worktree.

### 5.1 Implementation constraints

- **bash 3.2.** The only interpreter available on macOS is bash 3.2, so `mapfile`/`readarray` and
  associative arrays (`declare -A`) are unavailable. The existing code uses neither; the new modules
  must not either. Keyed lookups use either parallel arrays or files in a scratch directory.
- **`git_target` resolution.** The pointer at `.jj/repo/store/git_target` is relative to
  `.jj/repo/store/`, not to `.jj/repo/`.
- **Index files.** A scratch index must not be pre-created as an empty file; an empty file is rejected
  as a malformed index. Let the tooling create it.

## 6. Worktree rules

**A worktree's working-copy commit may only be rewritten by an operation running inside that worktree.**

Rewriting it from outside moves a commit that does not yet contain the worktree's uncommitted changes;
the subsequent working-copy update then deletes them. This was reproduced during design: a worktree
with an un-snapshotted file lost that file and acquired a divergent change ID.

Consequently:

1. The command's precondition block calls `_worktree_ensure_working_copy` (§6.1). It then opens a
   transaction: `_history_begin_transaction` records the operation ID and snapshots the current
   worktree. Because the operation ID is recorded first, `tt history undo` reverts the snapshot along
   with everything else.
2. Bare writes proceed with no working copy involved.
3. `_worktree_reattach_current REPO OLD_TIP NEW_REV` moves the current worktree onto the new commit if
   its working-copy commit descended from `OLD_TIP`, and does nothing otherwise. The rebase runs inside
   the worktree and therefore updates the working copy in the same step — no separate repair is needed.
4. Other worktrees are never written to and never rewritten. They are **behind**, not broken: fully
   usable, still descending from the previous tip.

### 6.1 The working copy must not be a bookmark tip

tt's model keeps `@` as a child of the bookmark it is working on. The off-model state where `@` *is* a
bookmarked commit is reachable only by the user running the backend's edit command directly, and it
breaks both halves of the mechanism above:

- **The snapshot contaminates the branch.** Snapshotting rewrites `@`, and a bookmark pointing at a
  rewritten commit follows it. Unrelated uncommitted work is therefore absorbed into the branch tip and
  published on the branch. Verified: a scratch file created beside a bookmarked `@` was folded into that
  bookmark's commit by the next backend command.
- **Reattachment silently does nothing.** `@` counts as a descendant of the tip, so a naive
  descends-from predicate reports success, but the rebase source range is empty and the rebase is a
  no-op. `@` is left as an *ancestor* of the new commit, and the next checkpoint would fork the branch.

The rule is therefore a single invariant:

**A mutating command refuses to start whenever `@` carries a bookmark**, regardless of working-copy
state, naming the bookmark and the remedy. The scope is any bookmark, not merely the branch being
written, because the snapshot contaminates whichever bookmark `@` carries. There are no exemptions:
`tt task checkpoint` refuses too, since amending a branch tip is not what a checkpoint means.

Refusing outright rather than repairing the state removes the normalization step, the defensive
re-check and the clean/dirty distinction entirely: the invariant holds on entry to every transaction,
so the reattachment logic in §6 never encounters the degenerate case. The state cannot be reached
accidentally, so an outright refusal costs nothing.

`_worktree_ensure_working_copy REPO` implements the check. Every mutating command calls it from its
existing precondition block, which runs before the transaction is opened and therefore before the
snapshot that would do the damage.

The check is deliberately **not** folded into `_history_begin_transaction`. Recognizing a branch tip
requires knowing tt's branch model, and the transaction module's responsibility is the `.tt/history`
log; embedding the invariant there would make the undo log unreadable without also understanding tt's
branching conventions. The snapshot itself does stay in `_history_begin_transaction`: capturing the
working copy needs no knowledge of branches, and it must happen after the operation ID is recorded for
`tt history undo` to restore uncommitted work faithfully — that is transaction semantics, not branch
semantics.

The trade-off accepted here is that a command added later could omit the call. Each mutating command's
own suite covers the refusal, so the gap would be a missing test rather than a passing one.

### 6.2 Working-copy cleanliness

A dirty working copy is a user's work in progress, not an invalid state, and bare writes are provably
unaffected by it. There is therefore **no global clean-working-copy requirement**. Refusing on dirt
would also protect nothing: the backend snapshots the working copy on every command it runs, so a
refusal by tt merely defers a snapshot the user's next backend command performs anyway.

Cleanliness is required only where it protects real semantics:

| Command | Requires clean | Why |
| --- | --- | --- |
| `task rename` | yes | Carries `@` through a repeated rewrite of the whole task range (§9) |
| `task move` | yes | Carries `@` through a rebase of the task's unmerged range |
| `task checkin` | yes | Validates the unmerged range for stray task-file modifications |
| `task propagate` | no | Unrestricted today; bare writes make it no riskier |
| everything else | no | Relaxed — the requirement existed only to serve the working-copy dance |

### 6.3 Reporting

`_worktree_list_unsynced_worktrees REPO BRANCH` reports them; `_worktree_report_unsynced REPO BRANCH`
prints the advisory warning, and each mutating command calls it once after its writes:

```
The following worktrees are now out of sync:
  <path> (<task-id>)
```

`tt worktree sync` brings a behind worktree forward by running inside it, so the snapshot in step 1
protects its uncommitted work identically. `--all` iterates the reported set, entering each worktree in
turn, reporting conflicts and continuing, exiting non-zero if any failed.

## 7. Facade write API

```
_task_commit_on_branch REPO BRANCH MESSAGE
    [--modify PATH]... [--delete PATH]... [--delete-prefix PREFIX]...
    -- WRITER_FN [ARGS...]
```

Prints the new commit ID. Steps:

1. Resolve the branch tip.
2. Materialize each `--modify` path from the tip into a staging directory; a path absent at the tip is
   an error.
3. Expand each `--delete-prefix` into exact file paths via `_vcs_list_files_at_revision`, and combine
   with the `--delete` paths.
4. Run `WRITER_FN` with the staging root as its first argument.
5. `_vcs_commit_changeset` on the tip with the staging directory and the deletion list.
6. `_vcs_set_bookmark` to the new commit.
7. `_worktree_reattach_current`.

The three inputs are orthogonal: `--modify` materializes existing files for read-modify-write, the
staging directory carries new and replaced content, and the delete flags carry removals. A file
disappearing from the staging directory is **not** a deletion — removals are always declared.

```bash
_task_commit_on_branch "$repo" "$parent_bookmark" "$msg" \
  --modify "$parent_task_file" \
  --delete-prefix ".tt/task/$slug" \
  -- _write_parent_without_subtask "$task_id"

_write_parent_without_subtask() {
  local stage="$1" task_id="$2"
  _frontmatter_remove_subtask "$stage/$parent_task_file" "$task_id"
}
```

## 8. Merge commits

Merge commits never carry file writes. `checkin` and `publish` both build a linear **handoff** commit
containing the file changes, then create an empty merge commit whose description is the checkin or
publish message. So Git plumbing only ever constructs linear commits, and merges are delegated to the
backend, which computes the merged tree and represents conflicts natively:

```
handoff ← _task_commit_on_branch REPO CHILD_BRANCH handoff_message ...
merge   ← _vcs_create_merge_commit REPO checkin_message PARENT_BRANCH "$handoff"
          _vcs_check_has_conflicts REPO "$merge"   → abort unless --force
          _vcs_set_bookmark REPO PARENT_BRANCH "$merge"
```

## 9. Renaming a task

`tt task rename` moves `.tt/task/<old-slug>/` to `.tt/task/<new-slug>/` in every commit that carries it,
retargets the root task symlink, and updates the parent's `subtask:` reference. The mechanism below was
prototyped end-to-end against three topologies before being adopted.

### 9.1 Primitive

The rewrite primitive is `_vcs_restore_tree REPO SOURCE_REV TARGET_REV`, which sets `TARGET_REV`'s tree
wholesale from `SOURCE_REV` while preserving the target's change ID, description and author, and which
preserves descendant **content** rather than replaying their diffs when it rebases them.

A diff-moving primitive is the wrong tool here: it forces every rewrite to be expressed as a delta
against a commit whose state earlier rewrites have already disturbed. Setting the tree outright makes
each commit's result depend only on values computed before any mutation.

### 9.2 Rewrite set

The set is every visible descendant of the commit that **introduced** the task directory:

```
descendants(roots(files("<old-prefix>")))
```

Two narrower definitions were tried and rejected:

- *Descendants of the parent bookmark tip* misses the task branch entirely whenever the parent has
  advanced past the fork point — for instance after a sibling task was created or checked in.
- *The task's unmerged range* leaves every commit beyond the task bookmark untouched: trailing commits
  and the working-copy commit then hold a diff that **undoes the rename**, so the next checkpoint would
  push the old paths back onto the branch. A previously empty, clean `@` acquires this diff.

The adopted set naturally includes the parent tip, the task's own range, trailing commits, sibling
branches that inherited the stub, and the working-copy commit.

### 9.3 Algorithm

```
refuse if any FOREIGN worktree's working-copy commit lies in the rewrite set   (§9.4)

Phase 0 — reads only, no mutation:
  for each commit C in the set:
      read C's tree from the original stored objects
      rewrite paths under the old prefix to the new prefix
      retarget any symlink whose target points into the old prefix
      rewrite the parent task file's subtask reference
      write the result as a detached staging commit; record it against C's CHANGE ID
  import every staging commit in one step

Phase 1 — rewrite in place, oldest first, addressed by CHANGE ID:
  for each commit C in the set:
      _vcs_restore_tree REPO <staging commit for C> C

rename the bookmark
abandon the staging commits and drop their temporary refs
refresh the current worktree from inside itself
```

Commits are addressed by change ID throughout, because each rewrite rebases the remainder of the set
and invalidates their commit IDs.

Computing every target tree up front, from the original objects, is what makes the algorithm robust:
nothing in Phase 1 reads state that Phase 1 itself has disturbed. There is consequently no need to
rescue pre-rename content by reading at an earlier operation, and **no conflict is produced at any
point** — verified across all three topologies.

### 9.4 Foreign worktrees

Rename is the one operation that must rewrite commits it does not own, so it cannot honour §6's rule by
construction. It therefore **refuses** when any worktree other than the current one has its
working-copy commit inside the rewrite set, naming each blocking worktree. The user syncs or removes
those worktrees first. Refusing is the only safe option: rewriting a foreign working-copy commit
destroys uncommitted work there, and leaving it out of the set gives it a rename-reverting diff.

Verified: the refusal leaves the repository completely unmodified and the foreign worktree's
un-snapshotted files intact.

### 9.5 Verified outcomes

Across a freshly forked task, a task with trailing commits beyond its bookmark and a context file, and
a task whose parent had advanced past the fork point with a sibling branch present:

- every change ID in the graph is unchanged;
- no commit contains a path under the old prefix, and no task file references the old task ID —
  including the child's inherited copy of the parent task file;
- the root task symlink is retargeted, remaining a symlink;
- non-task content and its incremental history are untouched;
- the working-copy commit's diff is empty, and the working copy on disk is updated;
- there are zero conflicts, and no staging bookmarks or refs survive.

Abandoning the staging commits is required: dropping their bookmarks alone leaves them visible in the
log.

## 10. Working-copy-bound commands

Only three commands legitimately require a working copy, and only they may call the restricted
operations in §4:

| Command | Why |
| --- | --- |
| `tt task checkpoint` | Snapshots the user's real, uncommitted work |
| `tt task checkout` | Moves the working copy and populates a new worktree |
| `tt workspace init` | Commits the initial workspace state before any branch exists |

`tt worktree sync` also runs inside a worktree, but as the sanctioned mechanism of §6 rather than as an
exception.

## 11. Command mapping

| Command | Writes | Mechanism |
| --- | --- | --- |
| `task create` | parent + child branches | two `_task_commit_on_branch` calls |
| `task edit` | task branch | `_task_commit_on_branch` |
| `task context add` / `delete` | task branch | `_task_commit_on_branch` |
| `task complete` | task branch | `_task_commit_on_branch` |
| `task reorder` | parent or task branch | `_task_commit_on_branch` |
| `task delete` | parent branch | `_task_commit_on_branch` + `--delete-prefix`, then bookmark and worktree removal |
| `task move` | old parent, new parent, task | two `_task_commit_on_branch` calls + `_vcs_move_commits` |
| `task rename` | parent + every commit in range | §9 |
| `task checkin` | child (handoff) + parent (merge) | §8 |
| `task publish` | project (handoff) + target (merge) | §8, handoff uses `--delete-prefix` |
| `task propagate` | many branches | `_vcs_move_commits` or `_vcs_create_merge_commit` |
| `task checkpoint` | current branch | working-copy-bound |
| `task checkout` | task branch | working-copy-bound |
| `workspace init` | initial commit | working-copy-bound |
| `worktree delete` | none | `_vcs_forget_worktree` |
| `worktree sync` | worktree working copies | `_vcs_reattach_worktree`, inside each |
| `history undo` | operation log | `_vcs_restore_operation` |

## 12. Removals

The `jj edit` / write / commit / `bookmark set` / restore dance disappears from its library copy and all
eight hand-rolled duplicates, together with target-worktree selection used only to choose whose working
copy to borrow, the `current_bookmark`/`current_worktree` values threaded through commands to support
restoring it, and every best-effort `|| true` restore. Worktree lookup survives only where it is
informational.

## 13. Open items for the Plan step

- Enumerate all 17 mutating commands and record, per command, where `@` ends up before and after,
  flagging each divergence for an explicit decision. `checkin` and `publish` currently move `@` onto the
  new merge commit; under the universal rule they no longer move it at all, which is the intended
  correction — these commands should affect the target branch, not the invoking worktree.
- Confirm, per command, which clean-working-copy preconditions were serving the dance and are therefore
  removed.
- Fix the migration order and the checkpoint boundaries.
- Add `_worktree_ensure_working_copy` to every mutating command's precondition block, and cover the
  refusal in each command's suite — including that it fires for a clean working copy and for a bookmark
  unrelated to the command's target.
- Decide how `tt task rename`'s foreign-worktree refusal (§9.4) is surfaced: whether it names the
  remedy (`tt worktree sync`, or removing the worktree) and whether `--force` may override it. Note
  that overriding is genuinely unsafe, not merely risky.
- Cover §9.5's verified outcomes as assertions in the `task rename` suite, including the three
  topologies exercised during design: a freshly forked task, a task with trailing commits beyond its
  bookmark, and a task whose parent has advanced past the fork point with a sibling branch present.
