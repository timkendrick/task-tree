# jj backend for the tt VCS interface.
# Source this file; do not execute directly.
#
# Implements the backend contract declared in lib/repo.sh: every _jj__* function
# here has a corresponding _repo__* wrapper there. Only lib/repo.sh may call the
# _jj__* names; all other code goes through the _repo__* interface.
#
# Naming convention: functions named with a double underscore (__jj__*) are
# internal helpers private to this module. They are NOT part of the backend
# contract and have no _repo__* wrappers.
#
# This module is the only place in lib/ where jj is invoked and where jj
# revset or template syntax may appear. Everything else expresses VCS needs
# through the named operations below.
#
# The --ignore-working-copy convention
# ------------------------------------
# Whenever jj runs a command that loads the working copy, it first records any
# on-disk changes into the working-copy commit, and afterwards rewrites the
# files on disk to match wherever the working copy ended up.
#
# This behavior is typically only desirable for the helpers that explicitly
# operate on the current working copy.
#
# So the rule is:
#
#   Everything passes --ignore-working-copy, EXCEPT the operations in the
#   "Working copy" section below, which exist precisely to read or move a
#   working copy.
#
# Two operations outside that section are also exceptions, each for a reason
# given in full at the function itself: _jj__restore_operation (an undo has to
# rewrite the files on disk, and the snapshot it takes on the way allows
# recovering the discarded work) and _jj__create_worktree (creating a worktree
# means writing its files, so no `--ignore-working-copy` flag exists).
#
# Public surface:
#   Repository discovery:
#     _jj__check_is_repository       — test whether a directory is a jj repository
#     _jj__find_repository_root      — walk up from CWD to the enclosing repository
#     _jj__resolve_repository_root   — canonical repository root for any workspace
#     _jj__resolve_repository_path   — symlink-resolved canonical repository root
#     _jj__get_backend_type          — storage backend type of the repository
#     _jj__check_backend_supported   — whether the storage backend is supported
#   Operation log:
#     _jj__get_operation_id          — current operation ID
#     _jj__restore_operation         — restore the repository to a prior operation
#   Revisions:
#     _jj__get_commit_description    — full description of a revision
#     _jj__resolve_commit            — immutable commit ID of a revision
#     _jj__resolve_single_commit     — immutable commit ID of a revision naming exactly one commit
#     _jj__resolve_change            — stable change ID of a revision
#     _jj__get_commit_timestamp      — committer timestamp of a revision (ISO 8601 UTC)
#     _jj__check_revision_exists     — whether a revision resolves
#     _jj__check_is_canonical_commit_id — whether text has the form of a full commit ID
#     _jj__check_commit_empty        — whether a revision has no file changes
#     _jj__check_has_conflicts       — whether a single revision has conflicts
#     _jj__check_descendants_have_conflicts — whether a revision or any descendant has conflicts
#     _jj__check_range_has_conflicts — whether any commit in a range has conflicts
#     _jj__check_is_ancestor         — whether one revision is an ancestor of another
#     _jj__filter_commits_reachable_from — the given commits that REV can reach
#     _jj__find_fork_point_commit    — commit ID where two revisions' histories fork
#     _jj__list_commits_in_range     — commit IDs in FROM..TO, oldest first
#     _jj__list_commits_in_dag_range — commit IDs descended from BASE up to TIP
#     _jj__count_commits_in_range    — number of commits in FROM..TO
#     _jj__list_range_root_commits   — commit IDs of the roots of FROM..TO
#     _jj__list_range_root_parent_commits — commit IDs of the parents of the roots of FROM..TO
#     _jj__check_range_covered       — whether a range is inside a union of ranges
#     _jj__format_revision_range     — render a FROM/TO range in a named format
#     _jj__list_mainline_commits     — first-parent mainline commit records
#   Task-range queries:
#     _jj__find_file_introduction    — unique commit that introduced a file
#     _jj__find_prefix_introduction  — unique commit that introduced a path prefix
#     _jj__list_descendant_changes   — change IDs of a revision and its descendants
#     _jj__list_file_waypoints       — commits touching a target/marker file pair
#     _jj__sort_commits_by_ancestry  — order commit IDs oldest first within a region
#   Working copy (restricted):
#     _jj__check_working_copy_clean  — whether the working copy has pending changes
#     _jj__list_working_copy_changes — files the working copy changes relative to @-
#     _jj__get_worktree_checkout_revision — commit a worktree's files were updated to
#     _jj__get_working_copy_revision — change ID of @
#     _jj__get_working_copy_parent   — commit ID of @-
#     _jj__set_working_copy_revision — point the working copy at a revision
#     _jj__new_working_copy_child    — start a new working-copy commit
#     _jj__commit_working_copy       — commit the working copy with a message
#     _jj__snapshot_worktree         — capture on-disk changes into the working-copy commit
#     _jj__reattach_worktree         — rebase the working-copy commit onto a destination
#     _jj__refresh_worktree          — update on-disk files after a bare rewrite of @
#   Mutations (bare; no working copy involved):
#     _jj__commit_changeset          — build a commit in the backing Git store from a staged tree
#     _jj__create_merge_commit       — create a merge commit of two or more parents
#     _jj__set_description           — replace a revision's description
#     _jj__move_commits              — rebase revisions and their descendants onto a destination
#     _jj__squash_commit             — fold a revision's changes into another revision
#     _jj__restore_tree              — set a revision's tree wholesale from another revision
#     _jj__restore_path              — set one path in a revision from another revision
#     _jj__abandon_commit            — abandon a revision, rebasing descendants onto its parents
#   Bookmarks:
#     _jj__set_bookmark              — move a bookmark to an explicit revision
#     _jj__list_bookmark_names       — all local bookmark names
#     _jj__list_bookmark_targets     — every local bookmark with its target commit ID
#     _jj__list_bookmarks_at         — local bookmark names at a revision
#     _jj__check_bookmark_exists     — whether a local bookmark exists
#     _jj__rename_bookmark           — rename a bookmark
#     _jj__delete_bookmark           — delete a bookmark
#   Worktrees:
#     _jj__resolve_worktree_root     — workspace root for the current context
#     _jj__list_worktrees            — one "name: path" line per workspace
#     _jj__forget_worktree           — remove a workspace from the repository model
#     _jj__create_worktree           — add a workspace at a path, on a revision
#     _jj__get_worktree_revision     — commit ID of a workspace's working-copy commit
#   Files:
#     _jj__read_file_at_revision     — file content at a revision
#     _jj__read_files_at_revisions   — content of many files at many revisions, in one pass
#     _jj__read_symlink_at_revision  — symlink target at a revision
#     _jj__read_file_at_operation    — file content at an operation + revision
#     _jj__check_file_exists_at_revision — whether a file exists at a revision
#     _jj__list_files_at_revision    — tracked files at a revision
#     _jj__list_files_at_operation   — tracked files at an operation + revision
#     _jj__list_changed_files        — files a revision changes relative to its parents
#     _jj__list_changed_files_in_range — files a range changes relative to its base
#     _jj__get_file_diff             — Git-format diff of one file at a revision
#     _jj__show_diff                 — Git-format diff between two revisions

# ---------------------------------------------------------------------------
# Internal runners (__jj__*; not part of the backend contract)
#
# Every jj and git invocation in this module goes through one of these four
# helpers, each of which is a single call to _ui__run_command (lib/ui.sh)
# naming two things: the log level at which the invocation becomes worth
# narrating, and whether its stdout is the caller's return value.
#
#   runner                 level    stdout
#   __jj__read             verbose  captured
#   __jj__write            info     discarded
#   __jj__write_internal   verbose  discarded
#   __jj__git              verbose  captured
#
# The level is an editorial judgement, not a mechanical property. TT_LOG=info
# is a narration of what tt did to the user's repository, so it carries the
# mutations a user would recognize as the point of the command. Mutations that
# are private mechanism rather than user-visible intent — the temporary-ref hop
# inside _jj__commit_changeset, the deliberate working-copy snapshot — use
# __jj__write_internal and appear only at TT_LOG=verbose. Tracing them at info
# would narrate tt's implementation instead of its effect, and jj's own
# reporting of the temporary ref ("Abandoned 1 commits that are no longer
# reachable") reads alarmingly out of context.
#
# Reads are verbose-level because a read changes nothing a user needs told.
# The git plumbing is verbose-level for the same reason: it is the mechanism of
# a single bare write whose user-visible effect is the bookmark move that
# follows it.
#
# The helpers run the command in the caller's working directory. A few
# operations must instead run from inside the repository, and each wraps its
# own `( cd "$repo" && ... )` with a comment giving one of the following
# reasons:
#
#   1. The command prints paths. `file list` and `diff --name-only` report
#      paths relative to the working directory — from a subdirectory the same
#      file comes back as `../kept.txt` rather than `kept.txt`. Running from
#      the root is what makes tt's output repo-root-relative instead of
#      dependent on wherever the user happened to invoke tt.
#   2. The caller's own working directory may no longer exist. jj resolves its
#      working directory before anything else and fails outright with "Could
#      not determine current directory" when it is gone, whatever -R says.
#      `worktree delete --force` run from inside the worktree it removes is
#      the case that arises in practice: everything after the removal — the
#      transaction's closing operation-id read included — runs from a deleted
#      directory.
#
# Needing to act on a particular workspace is NOT one of them: -R selects the
# workspace on its own, including for workspace-scoped commands such as
# `workspace update-stale`.
#
# The helpers never log anything else and never exit; they return the
# underlying command's exit status.
# ---------------------------------------------------------------------------

# Usage: __jj__read REPO ARG...
# Runs `jj -R REPO ARG...` with stdout passing through (the caller captures it).
__jj__read() {
  local repo="$1"; shift
  _ui__run_command "$_UI__LOG_LEVEL_VERBOSE" "$_UI__OUTPUT_CAPTURE" \
    jj -R "$repo" "$@"
}

# Usage: __jj__write REPO ARG...
# Runs `jj -R REPO ARG...` for a user-visible mutation: stdout is not wanted,
# and the invocation is narrated at TT_LOG=info.
__jj__write() {
  local repo="$1"; shift
  _ui__run_command "$_UI__LOG_LEVEL_INFO" "$_UI__OUTPUT_QUIET" \
    jj -R "$repo" "$@"
}

# Usage: __jj__write_internal REPO ARG...
# Like __jj__write, but for a mutation that is private mechanism rather than
# user-visible intent, so it is narrated only at TT_LOG=verbose.
__jj__write_internal() {
  local repo="$1"; shift
  _ui__run_command "$_UI__LOG_LEVEL_VERBOSE" "$_UI__OUTPUT_QUIET" \
    jj -R "$repo" "$@"
}

# Usage: __jj__git ARG...
# Runs `git ARG...` with stdout passing through (the caller captures it), for
# the git plumbing used by the bare-mutation operations. Callers name the
# target repository with --git-dir.
__jj__git() {
  _ui__run_command "$_UI__LOG_LEVEL_VERBOSE" "$_UI__OUTPUT_CAPTURE" \
    git "$@"
}

# ---------------------------------------------------------------------------
# Repository discovery
# ---------------------------------------------------------------------------

# Usage: _jj__check_is_repository DIR
# Returns 0 if DIR is a jj repository (or workspace) root, 1 otherwise.
_jj__check_is_repository() {
  local dir="$1"
  [[ -d "$dir/.jj" ]]
}

# Find repo root by walking up from current directory to find .jj; return 1 if not found.
# Uses pwd -P to resolve symlinks so that working from inside a symlinked directory
# (e.g. /virtual/HEAD) does not produce a symlink path as the repo root.
_jj__find_repository_root() {
  local dir
  dir="$(pwd -P)"
  while [[ -n "$dir" ]]; do
    if [[ -d "$dir/.jj" ]]; then
      printf '%s' "$dir"
      return 0
    fi
    [[ "$dir" == '/' ]] && break
    dir="$(_path__dirname "$dir")"
  done
  return 1
}

# Usage: _jj__resolve_repository_root REPO
# Returns the canonical repo root for the repository.
# If REPO is a worktree (.jj/repo is a pointer file),
# follows the pointer to find the canonical repo root.
# If REPO is already the canonical repo (.jj/repo is a directory), returns REPO.
_jj__resolve_repository_root() {
  local repo="$1"
  local repo_entry="$repo/.jj/repo"
  if [[ -f "$repo_entry" ]]; then
    # Worktree: .jj/repo is a file containing a relative path to
    # the canonical repo's .jj/repo directory (e.g. "../../../../repo/.jj/repo").
    local pointer target
    pointer="$(<"$repo_entry")"
    target="$(cd "$repo/.jj" && cd "$pointer" && pwd -P)" \
      || { _ui__log "Error: Could not resolve canonical repo from $repo_entry"; return 1; }
    # target = /path/to/canonical/.jj/repo — strip /.jj/repo to get repo root
    _path__dirname "$(_path__dirname "$target")"
  else
    # Canonical repo: .jj/repo is a directory (the actual op store)
    printf '%s' "$repo"
  fi
}

# Usage: _jj__resolve_repository_path REPO
# Prints the symlink-resolved path of the canonical repository root for REPO.
# REPO may be any workspace, including a dedicated worktree whose own .jj points
# at the canonical repo. Use when the result is compared against another
# canonicalized path, so that a symlinked root (e.g. /var -> /private/var on
# macOS) does not defeat the comparison.
# Returns 1 if the canonical root cannot be resolved.
_jj__resolve_repository_path() {
  local repo="$1"
  local canonical_repo
  canonical_repo="$(_jj__resolve_repository_root "$repo")" || return 1
  _path__resolve_symlinks "$canonical_repo" 2>/dev/null
}

# Usage: _jj__get_backend_type REPO
# Prints the storage backend type of the repository (e.g. "git") by reading
# the canonical repo's on-disk store marker. Returns 1 (nothing printed) if
# the marker cannot be read.
_jj__get_backend_type() {
  local repo="$1"
  local canonical_repo
  canonical_repo="$(_jj__resolve_repository_root "$repo")" || return 1
  local type_file="$canonical_repo/.jj/repo/store/type"
  [[ -r "$type_file" ]] || return 1
  printf '%s' "$(<"$type_file")"
}

# Usage: _jj__check_backend_supported REPO
# Returns 0 when the repository's storage backend is supported (type "git").
# When the type is anything else, prints exactly
#   Unsupported repository backend: <type>
# to stderr and returns 1. This is the one backend function permitted to write
# a message: the message text is part of its contract. Returns 1 silently when
# the backend type cannot be read at all.
_jj__check_backend_supported() {
  local repo="$1"
  local backend_type
  backend_type="$(_jj__get_backend_type "$repo")" || return 1
  if [[ "$backend_type" != "git" ]]; then
    printf 'Unsupported repository backend: %s\n' "$backend_type" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Operation log
# ---------------------------------------------------------------------------

# Usage: _jj__get_operation_id REPO
# Prints the current jj operation ID to stdout.
# Returns 1 if the operation ID cannot be read.
#
# The operation store keeps one file per operation head, named by the
# operation ID, so with a single head the ID is read from the filesystem
# without a backend process. Several heads mean concurrent operations that
# only the backend can reconcile, so that case asks it. Either way this is a
# pure read: the backend query passes --ignore-working-copy because without
# it jj would snapshot the working copy first, and the "current" operation
# would be a snapshot created by the read itself.
_jj__get_operation_id() {
  local repo="$1"
  local canonical_repo
  canonical_repo="$(_jj__resolve_repository_root "$repo")" || return 1
  local heads_dir="$canonical_repo/.jj/repo/op_heads/heads"
  local entry head='' count=0
  for entry in "$heads_dir"/*; do
    [[ -e "$entry" ]] || continue
    head="${entry##*/}"
    count=$(( count + 1 ))
  done
  if [[ $count -eq 1 ]]; then
    printf '%s\n' "$head"
    return 0
  fi
  # Read from inside the repository ($PWD): so that the operation succeeds
  # even when invoked from a deleted working directory.
  ( cd "$repo" && __jj__read "$PWD" --ignore-working-copy op log --no-graph -T id -n 1 )
}

# Usage: _jj__restore_operation REPO OP_ID
# Restores the repository to the state recorded at operation OP_ID.
# Quiet mutation.
#
# Snapshots the working copy, both to apply incoming changes to the worktree
# and also to retain outgoing changes in the jj operation log, so that
# uncommitted work discarded by the undo can still be recovered by restoring
# the snapshot operation.
_jj__restore_operation() {
  local repo="$1" op_id="$2"
  # Restore from inside the repository ($PWD) so that the operation succeeds
  # even when invoked from a deleted working directory.
  ( cd "$repo" && __jj__write "$PWD" op restore "$op_id" )
}

# ---------------------------------------------------------------------------
# Revisions
# ---------------------------------------------------------------------------

# Usage: _jj__get_commit_description REPO REV
# Prints the full description of REV (empty if it has none).
_jj__get_commit_description() {
  local repo="$1" rev="$2"
  __jj__read "$repo" --ignore-working-copy log -r "$rev" --no-graph -T 'description'
}

# Usage: _jj__resolve_commit REPO REV
# Prints the immutable commit ID of REV. Returns jj's exit code; nothing is
# printed if REV cannot be resolved.
_jj__resolve_commit() {
  local repo="$1" rev="$2"
  __jj__read "$repo" --ignore-working-copy log -r "$rev" --no-graph -T 'commit_id'
}

# Usage: _jj__resolve_single_commit REPO REV
# Prints the immutable commit ID of REV when it resolves to exactly one commit.
# Returns non-zero (nothing printed) when REV cannot be resolved, or when it
# names no commits or more than one.
_jj__resolve_single_commit() {
  local repo="$1" rev="$2"
  __jj__read "$repo" --ignore-working-copy log -r "exactly(${rev}, 1)" --no-graph -T 'commit_id'
}

# Usage: _jj__resolve_change REPO REV
# Prints the stable change ID of REV (change IDs survive rebases, unlike
# commit IDs). Returns jj's exit code; nothing is printed if REV cannot be
# resolved.
_jj__resolve_change() {
  local repo="$1" rev="$2"
  __jj__read "$repo" --ignore-working-copy log -r "$rev" --no-graph -T 'change_id'
}

# Usage: _jj__get_commit_timestamp REPO REV
# Prints the committer timestamp of REV in ISO 8601 UTC
# (e.g. 2026-01-31T12:34:56Z). Returns jj's exit code.
_jj__get_commit_timestamp() {
  local repo="$1" rev="$2"
  __jj__read "$repo" --ignore-working-copy log --no-graph -r "$rev" \
    -T 'committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ")'
}

# Usage: _jj__check_is_canonical_commit_id TEXT
# Returns 0 when TEXT has the form of a full commit ID in this backend — forty
# lowercase hex digits — and 1 otherwise. A check of form only: it says the
# text needs no resolution, not that the commit exists. Status only.
_jj__check_is_canonical_commit_id() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

# Usage: _jj__check_revision_exists REPO REV
# Returns 0 if REV resolves to a revision, non-zero otherwise. Status only.
_jj__check_revision_exists() {
  local repo="$1" rev="$2"
  __jj__read "$repo" --ignore-working-copy log -r "$rev" --no-graph -T '' >/dev/null
}

# Usage: _jj__check_commit_empty REPO REV
# Returns 0 when REV has no file changes relative to its parents.
# Deliberately snapshots the working copy first, so that '@' reflects pending
# filesystem changes.
_jj__check_commit_empty() {
  local repo="$1" rev="$2"
  local result
  result="$(__jj__read "$repo" --ignore-working-copy log -r "$rev" --no-graph -T 'empty')" || return 1
  [[ "$result" == "true" ]]
}

# Usage: _jj__check_has_conflicts REPO_OR_WORKTREE REV
# Returns 0 (true) if the single revision REV has conflicts. An unresolvable
# revision counts as conflict-free.
_jj__check_has_conflicts() {
  local repo="$1" rev="$2"
  local result
  result="$(__jj__read "$repo" --ignore-working-copy log -r "$rev" \
    --no-graph -T 'if(conflict, "yes")')" || true
  [[ -n "$result" ]]
}

# Usage: _jj__check_descendants_have_conflicts REPO REV
# Returns 0 (true) if REV or any descendant of REV has conflicts. An
# unresolvable revision counts as conflict-free.
_jj__check_descendants_have_conflicts() {
  local repo="$1" rev="$2"
  local result
  result="$(__jj__read "$repo" --ignore-working-copy log -r "descendants(${rev})" \
    --no-graph -T 'if(conflict, "yes\n")')" || true
  [[ -n "$result" ]]
}

# Usage: _jj__check_range_has_conflicts REPO FROM TO
# Returns 0 (true) if any commit reachable from TO but not from FROM (FROM
# exclusive, TO inclusive) has conflicts. An unresolvable range counts as
# conflict-free, since it contributes no commits.
_jj__check_range_has_conflicts() {
  local repo="$1" from="$2" to="$3"
  local result
  result="$(__jj__read "$repo" --ignore-working-copy log -r "${from}..${to}" \
    --no-graph -T 'if(conflict, "yes\n")')" || true
  [[ -n "$result" ]]
}

# Usage: _jj__check_is_ancestor REPO ANCESTOR DESCENDANT
# Returns 0 when ANCESTOR is an ancestor of DESCENDANT (a revision counts as
# its own ancestor). Status only; returns 1 when either revision does not
# resolve.
_jj__check_is_ancestor() {
  local repo="$1" ancestor="$2" descendant="$3"
  local result
  result="$(__jj__read "$repo" --ignore-working-copy log \
    -r "(${ancestor}) & ::(${descendant})" --no-graph -T '"x\n"')" || return 1
  [[ -n "$result" ]]
}

# Usage: _jj__filter_commits_reachable_from REPO REV COMMIT [COMMIT ...]
# Prints, one per line, those of the given COMMITs that REV can reach — i.e.
# the ones that are ancestors of REV (REV itself included). Order follows the
# backend's own listing order, not the argument order. Nothing is printed
# (status 0) when no COMMIT is given or none is reachable.
#
# This answers the whole question in one backend invocation rather than one
# ancestry test per commit, which matters for callers holding a range's worth
# of commits.
_jj__filter_commits_reachable_from() {
  local repo="$1" rev="$2"
  shift 2
  [[ $# -eq 0 ]] && return 0
  local union='' id
  for id in "$@"; do
    if [[ -z "$union" ]]; then
      union="$id"
    else
      union="${union} | ${id}"
    fi
  done
  __jj__read "$repo" --ignore-working-copy log --no-graph \
    -r "(${union}) & ::(${rev})" -T 'commit_id ++ "\n"'
}

# Usage: _jj__find_fork_point_commit REPO REV_A REV_B
# Prints the commit ID of the fork point of REV_A and REV_B (the most recent
# common location where their histories diverged). Returns jj's exit code;
# nothing is printed if the fork point cannot be resolved.
_jj__find_fork_point_commit() {
  local repo="$1" rev_a="$2" rev_b="$3"
  __jj__read "$repo" --ignore-working-copy log -r "fork_point(${rev_a} | ${rev_b})" \
    --no-graph -T 'commit_id'
}

# Usage: _jj__list_commits_in_range REPO FROM TO
# Prints the commit IDs of the commits reachable from TO but not from FROM
# (FROM exclusive, TO inclusive), one per line, oldest first. Returns jj's
# exit code; nothing is printed if the range cannot be resolved.
_jj__list_commits_in_range() {
  local repo="$1" from="$2" to="$3"
  __jj__read "$repo" --ignore-working-copy log -r "${from}..${to}" \
    --no-graph --reversed -T 'commit_id ++ "\n"'
}

# Usage: _jj__list_commits_in_dag_range REPO BASE TIP
# Prints the commit IDs of the commits that descend from BASE and are
# ancestors of TIP — the DAG range between the two — with BASE itself
# excluded, one per line, oldest first. Returns jj's exit code; nothing is
# printed if the range cannot be resolved.
#
# Narrower than the FROM..TO range of _jj__list_commits_in_range: that range
# holds everything reachable from TIP but not from BASE, which includes
# commits that arrived at TIP through a merge from a line that never descended
# from BASE. Here every listed commit lies on a path from BASE to TIP.
_jj__list_commits_in_dag_range() {
  local repo="$1" base="$2" tip="$3"
  __jj__read "$repo" --ignore-working-copy log -r "(${base})::(${tip}) ~ (${base})" \
    --no-graph --reversed -T 'commit_id ++ "\n"'
}

# Usage: _jj__count_commits_in_range REPO FROM TO
# Prints the number of commits reachable from TO but not from FROM (FROM
# exclusive, TO inclusive). Prints 0 (and returns 0) when the range cannot be
# resolved, so callers may treat resolution failure as an empty range.
_jj__count_commits_in_range() {
  local repo="$1" from="$2" to="$3"
  __jj__read "$repo" --ignore-working-copy log -r "${from}..${to}" --no-graph -T '"x\n"' \
    | grep -c . || true
}

# Usage: _jj__list_range_root_commits REPO FROM TO
# Prints the commit IDs of the commits in the FROM..TO range that have no
# parent inside the range, one per line. Returns jj's exit code.
_jj__list_range_root_commits() {
  local repo="$1" from="$2" to="$3"
  __jj__read "$repo" --ignore-working-copy log -r "roots(${from}..${to})" \
    --no-graph -T 'commit_id ++ "\n"'
}

# Usage: _jj__list_range_root_parent_commits REPO FROM TO
# Prints the commit IDs of the parents of the roots of the FROM..TO range, one
# per line. These commits are outside the range: they are where the range
# hangs off the rest of history. Prints nothing when the range is empty.
# Returns jj's exit code.
_jj__list_range_root_parent_commits() {
  local repo="$1" from="$2" to="$3"
  __jj__read "$repo" --ignore-working-copy log -r "parents(roots(${from}..${to}))" \
    --no-graph -T 'commit_id ++ "\n"'
}

# Usage: _jj__check_range_covered REPO BASE TIP COVER_BASE COVER_TIP [COVER_BASE COVER_TIP ...]
# Returns 0 when every commit in the BASE..TIP range is inside the union of
# the given cover ranges (each COVER_BASE..COVER_TIP pair). At least one cover
# pair is required; returns 1 when none is given. An unresolvable range counts
# as covered (it contributes no commits).
_jj__check_range_covered() {
  local repo="$1" base="$2" tip="$3"
  shift 3
  [[ $# -ge 2 ]] || return 1
  local union='' cover_base cover_tip
  while [[ $# -gt 0 ]]; do
    cover_base="$1" cover_tip="$2"
    shift 2
    if [[ -z "$union" ]]; then
      union="(${cover_base}..${cover_tip})"
    else
      union="${union} | (${cover_base}..${cover_tip})"
    fi
  done
  local count
  count="$(__jj__read "$repo" --ignore-working-copy log -r "(${base}..${tip}) ~ (${union})" \
    --no-graph -T '"x\n"' | grep -c . || true)"
  [[ "$count" -eq 0 ]]
}

# Usage: _jj__format_revision_range REPO FORMAT FROM TO
# Renders the FROM/TO revision range in a named output format:
#   native — the backend's own range expression for the two symbols as given
#   git    — an immutable Git commit-ID range (both endpoints resolved)
# Returns 1 if FORMAT is unknown or (for git) an endpoint cannot be resolved.
_jj__format_revision_range() {
  local repo="$1" format="$2" from="$3" to="$4"
  case "$format" in
    native)
      printf '%s..%s\n' "$from" "$to"
      ;;
    git)
      local from_id to_id
      from_id="$(_jj__resolve_commit "$repo" "$from")" || return 1
      to_id="$(_jj__resolve_commit "$repo" "$to")" || return 1
      printf '%s..%s\n' "$from_id" "$to_id"
      ;;
    *)
      return 1
      ;;
  esac
}

# Usage: _jj__list_mainline_commits REPO TIP BASE
#
# Outputs one record per commit on TIP's first-parent mainline that is not an
# ancestor of BASE, oldest first. Records are tab-separated:
#   <commit-id>\t<change-id>\t<timestamp>\t<parent-ids>\t<description-first-line>
#
# <parent-ids> is a space-separated list of full commit IDs; a merge commit lists
# the branch it was created on first and the branch merged into it second.
# <timestamp> is the committer timestamp in ISO 8601 UTC. The description comes
# last so a tab inside a commit message cannot displace the structured fields.
#
# Following first parents only excludes commits that arrived through a merge:
# those belong to the branch that was merged in, not to TIP's own mainline.
#
# Returns jj's exit code; nothing is printed if the revset cannot be resolved.
_jj__list_mainline_commits() {
  local repo="$1" tip="$2" base="$3"
  __jj__read "$repo" --ignore-working-copy log \
    -r "first_ancestors($tip) ~ ::$base" --no-graph --reversed \
    -T 'commit_id ++ "\t" ++ change_id ++ "\t" ++ committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ") ++ "\t" ++ parents.map(|p| p.commit_id()).join(" ") ++ "\t" ++ description.first_line() ++ "\n"'
}

# ---------------------------------------------------------------------------
# Task-range queries
#
# Compound queries used by the task-range machinery in lib/task.sh. Each takes
# domain arguments (boundary/head revisions and file paths) so that the revset
# assembly stays inside this backend.
# ---------------------------------------------------------------------------

# Usage: _jj__find_file_introduction REPO PATH HEAD_A HEAD_B
# Prints the commit ID of the unique commit that introduced the repo-relative
# file PATH within the combined ancestry of HEAD_A and HEAD_B. Returns 1
# (nothing printed, no logging) when there is no unique match — the caller
# owns the error message.
_jj__find_file_introduction() {
  local repo="$1" path="$2" head_a="$3" head_b="$4"
  local matches
  matches="$(__jj__read "$repo" --ignore-working-copy log --no-graph -r \
    "roots(files(root-file:\"${path}\") & ::(${head_a} | ${head_b}))" \
    -T 'commit_id ++ "\n"')" || true
  local count
  count="$(printf '%s' "$matches" | grep -c . || true)"
  [[ "$count" -eq 1 ]] || return 1
  printf '%s' "$matches"
}

# Usage: _jj__find_prefix_introduction REPO PREFIX
# Prints the commit ID of the unique commit that introduced the repo-root-
# relative path PREFIX — a file or a directory, matched together with
# everything beneath it — anywhere in the repository's visible history.
# Unlike _jj__find_file_introduction the search is not narrowed to the ancestry
# of named heads: callers use this to anchor a rewrite that must reach every
# line carrying the prefix, including branches that forked after it appeared.
# Returns 1 (nothing printed, no logging) when there is no unique match — the
# caller owns the error message.
_jj__find_prefix_introduction() {
  local repo="$1" prefix="$2"
  local matches
  matches="$(__jj__read "$repo" --ignore-working-copy log --no-graph \
    -r "roots(files(root:\"${prefix}\"))" -T 'commit_id ++ "\n"')" || true
  local count
  count="$(printf '%s' "$matches" | grep -c . || true)"
  [[ "$count" -eq 1 ]] || return 1
  printf '%s' "$matches"
}

# Usage: _jj__list_descendant_changes REPO REV
# Prints the stable change IDs of REV and of every visible commit descended
# from it, one per line, oldest first. Change IDs rather than commit IDs
# because a caller rewriting the listed commits one by one invalidates the
# commit IDs of everything still ahead of it, while change IDs survive.
# Returns jj's exit code; nothing is printed if REV cannot be resolved.
_jj__list_descendant_changes() {
  local repo="$1" rev="$2"
  __jj__read "$repo" --ignore-working-copy log -r "descendants(${rev})" \
    --no-graph --reversed -T 'change_id ++ "\n"'
}

# Usage: _jj__list_file_waypoints REPO BOUNDARY HEAD_A HEAD_B TARGET_PATH MARKER_PATH
# Considers the commits that descend from BOUNDARY and are ancestors of HEAD_A
# or HEAD_B (all bounds inclusive). Prints one tab-separated line, oldest
# first, for each such commit that changes TARGET_PATH, changes MARKER_PATH,
# or is a merge with a parent that changes MARKER_PATH:
#   <commit-id>\t<parent-ids space-separated>\t<timestamp>\t<target-changed 0|1>
# Returns jj's exit code; nothing is printed if the bounds cannot be resolved.
_jj__list_file_waypoints() {
  local repo="$1" boundary="$2" head_a="$3" head_b="$4"
  local target_path="$5" marker_path="$6"
  local bounded="${boundary}:: & ::(${head_a} | ${head_b})"
  local target_changes="files(root-file:\"${target_path}\")"
  local marker_changes="files(root-file:\"${marker_path}\")"
  local merge_candidates="merges() & children(${marker_changes})"
  __jj__read "$repo" --ignore-working-copy log --no-graph --reversed \
    -r "(${bounded}) & (${target_changes} | ${marker_changes} | ${merge_candidates})" \
    -T 'commit_id ++ "\t" ++ parents.map(|p| p.commit_id()).join(" ") ++ "\t" ++ committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ") ++ "\t" ++ if(self.diff("root-file:\"'"${target_path}"'\"").files().len() > 0, "1", "0") ++ "\n"'
}

# Usage: _jj__sort_commits_by_ancestry REPO BOUNDARY HEAD_A HEAD_B [COMMIT_ID...]
# Prints the given commit IDs one per line, oldest first, restricted to the
# region that descends from BOUNDARY and is ancestral to HEAD_A or HEAD_B
# (commit IDs outside that region are dropped). Prints nothing (status 0)
# when no commit IDs are given.
_jj__sort_commits_by_ancestry() {
  local repo="$1" boundary="$2" head_a="$3" head_b="$4"
  shift 4
  [[ $# -eq 0 ]] && return 0
  local ids='' id
  for id in "$@"; do
    if [[ -z "$ids" ]]; then
      ids="$id"
    else
      ids="${ids} | ${id}"
    fi
  done
  local bounded="${boundary}:: & ::(${head_a} | ${head_b})"
  __jj__read "$repo" --ignore-working-copy log --no-graph --reversed \
    -r "(${bounded}) & (${ids})" -T 'commit_id ++ "\n"'
}

# ---------------------------------------------------------------------------
# Working copy (restricted)
#
# Every function in this section takes a WORKTREE root as its first argument
# and reads or mutates that worktree's working copy. Only worktree-level code
# may call these operations: callers must know which working copy they are
# addressing rather than passing an arbitrary repository path.
# ---------------------------------------------------------------------------

# Usage: _jj__check_working_copy_clean WORKTREE
# Returns 0 if the working copy at WORKTREE has no pending changes.
_jj__check_working_copy_clean() {
  local worktree="$1"
  local result
  result="$(__jj__read "$worktree" log -r '@' --no-graph -T 'empty')" || return 1
  [[ "$result" == "true" ]]
}

# Usage: _jj__list_working_copy_changes WORKTREE
# Prints the worktree-root-relative paths of the files the working copy at
# WORKTREE changes relative to its parent (added, modified or deleted), one per
# line. Pending on-disk edits are snapshotted first, so files the backend has
# not yet seen are included. Returns jj's exit code.
_jj__list_working_copy_changes() {
  local worktree="$1"
  # Diff from inside the worktree ($PWD) to ensure printed file paths are relative to its root
  ( cd "$worktree" && __jj__read "$PWD" diff -r '@' --name-only )
}

# Usage: _jj__get_working_copy_revision WORKTREE
# Prints the change ID of @ in the given worktree. Exits 1 on failure.
# We return the change ID (not the commit ID) because change IDs survive
# rebases: if @ is a descendant of a rebased branch, jj creates a new
# commit with the same change ID, so pointing the working copy at the change
# ID will always resolve to the correct (post-rebase) version of the
# working-copy commit.
_jj__get_working_copy_revision() {
  local worktree="$1"
  __jj__read "$worktree" log -r '@' --no-graph -T 'change_id'
}

# Usage: _jj__get_working_copy_parent WORKTREE
# Prints the commit ID of the working-copy parent (@-) in the given worktree.
# Returns jj's exit code; nothing is printed if the parent cannot be resolved.
_jj__get_working_copy_parent() {
  local worktree="$1"
  __jj__read "$worktree" log -r '@-' --no-graph -T 'commit_id'
}

# Usage: _jj__set_working_copy_revision WORKTREE REV
# Points the working copy at REV (jj edit). Quiet mutation.
_jj__set_working_copy_revision() {
  local worktree="$1" rev="$2"
  __jj__write "$worktree" edit "$rev"
}

# Usage: _jj__new_working_copy_child WORKTREE [REV]
# Starts a new empty working-copy commit (jj new), on top of REV when given,
# otherwise on top of the current working-copy commit. Quiet mutation.
_jj__new_working_copy_child() {
  local worktree="$1" rev="${2:-}"
  if [[ -n "$rev" ]]; then
    __jj__write "$worktree" new -r "$rev"
  else
    __jj__write "$worktree" new
  fi
}

# Usage: _jj__commit_working_copy WORKTREE MESSAGE
# Commits the working copy with MESSAGE. Quiet mutation.
_jj__commit_working_copy() {
  local worktree="$1" message="$2"
  __jj__write "$worktree" commit -m "$message"
}

# Usage: _jj__snapshot_worktree WORKTREE
# Captures WORKTREE's on-disk changes into its working-copy commit. This is
# the deliberate-snapshot exception to the module's --ignore-working-copy
# convention: the whole point of the call is jj's side effect of snapshotting
# the working copy whenever a command loads it without --ignore-working-copy,
# so a cheap no-output log read is issued WITHOUT that flag. A clean working
# copy makes this a no-op. Status only; never logs, never exits.
_jj__snapshot_worktree() {
  local worktree="$1"
  __jj__write_internal "$worktree" log -r '@' --no-graph -T ''
}

# Usage: _jj__reattach_worktree WORKTREE FROM_REV DEST_REV
# Rebases FROM_REV, together with all of its descendants, onto DEST_REV. Runs
# against WORKTREE WITHOUT --ignore-working-copy, deliberately: jj then
# snapshots any pending on-disk changes into the working-copy commit before
# rebasing, and updates WORKTREE's on-disk files in the same step whenever the
# working-copy commit is among the rewritten commits — a bare rewrite would
# instead leave the files behind on the pre-rewrite tree.
#
# FROM_REV is normally the working-copy commit's own stable change ID, which
# survives rebases where a commit ID would go stale; that reattaches the
# worktree onto DEST_REV. It may equally name a commit further down the same
# line, which moves that whole subtree and carries the working copy with it.
# Status only; never logs, never exits.
_jj__reattach_worktree() {
  local worktree="$1" from_rev="$2" dest_rev="$3"
  __jj__write "$worktree" rebase -s "$from_rev" -d "$dest_rev"
}

# Usage: _jj__get_worktree_checkout_revision WORKTREE
# Prints the commit ID that WORKTREE's on-disk files were last updated to.
# That is the commit the files actually hold, which may differ from the commit
# the repository currently records for that workspace: a bare mutation rewrites
# the graph without touching any working copy, so the two diverge until the
# worktree is refreshed. Comparing this against the recorded @ is what tells a
# caller whether the worktree is stale.
#
# A pure read: it records no operation, updates no files, and succeeds against
# a worktree that is already stale. Returns non-zero (printing nothing) when
# the workspace state cannot be read.
#
# The low-level state query is deliberate. Every user-facing way of asking this
# question — `debug local-working-copy`, `workspace update-stale`, or any
# ordinary command that loads the working copy — snapshots the working copy and
# records an operation for it. A check that runs ahead of every branch-writing
# command must not do that: it would fold a user's pending edits into a new
# operation outside any transaction, on every tt invocation.
#
# `debug working-copy` reports the operation the workspace's files belong to;
# resolving @ as of that operation yields the commit they were updated to.
_jj__get_worktree_checkout_revision() {
  local worktree="$1"
  local state
  state="$(__jj__read "$worktree" debug working-copy)" || return 1
  local operation
  operation="$(printf '%s\n' "$state" \
    | sed -n 's/^Current operation: OperationId("\([0-9a-f]*\)").*$/\1/p')"
  [[ -n "$operation" ]] || return 1
  __jj__read "$worktree" --at-operation "$operation" --ignore-working-copy \
    log -r '@' --no-graph -T 'commit_id'
}

# Usage: _jj__refresh_worktree WORKTREE
# Updates WORKTREE's on-disk files to match its working-copy commit after that
# commit was rewritten by a bare graph mutation. A bare mutation leaves the
# recorded working-copy state pointing at the pre-rewrite tree, and jj then
# refuses every command that loads the working copy until it is recovered; this
# performs that recovery. Harmless (status 0, nothing changed) when the working
# copy is already current. Status only; never logs, never exits.
_jj__refresh_worktree() {
  local worktree="$1"
  __jj__write "$worktree" workspace update-stale
}
# ---------------------------------------------------------------------------
# Mutations (bare)
#
# Bare graph operations: each function here rewrites the commit graph directly
# and never touches any working copy — no snapshot is taken and no on-disk
# files are updated. Every jj invocation in this section passes
# --ignore-working-copy, per the module header.
# _jj__commit_changeset additionally drives `git fast-import` against the Git
# object store that backs the jj repository, so no git working tree or index
# is involved either.
# ---------------------------------------------------------------------------

# Usage: _jj__commit_changeset REPO PARENT_REV MESSAGE STAGE_DIR
#          [--copy SRC_REV SRC_PATH DEST_PATH]... [DELETE_PATH...]
#
# Builds a commit directly in the Git object store backing the jj repository
# and prints its full commit ID. The commit's tree is PARENT_REV's tree with
# each DELETE_PATH (a repo-root-relative path) removed first, then each --copy
# applied, then every file under STAGE_DIR overlaid on top. A --copy places
# SRC_PATH as recorded at SRC_REV at DEST_PATH: a file is copied to DEST_PATH,
# and a directory has every entry beneath it copied to the same relative path
# beneath DEST_PATH. Copied entries reuse the recorded blobs and modes, so
# content, executable bits and symlinks come across byte for byte without
# passing through the shell. A SRC_PATH absent at SRC_REV is an error. Staged
# files take paths relative to STAGE_DIR:
#   - a symlink becomes a symlink entry (mode 120000) whose blob is the link
#     target string
#   - an executable file keeps mode 100755
#   - any other file gets mode 100644
# Deletions run before the overlay, so one call may delete a path and stage a
# replacement beneath the same prefix. Author and committer identity comes
# from the jj-configured user.name/user.email, never from the ambient git
# identity.
#
# No working copy is involved at any point: regular files are hashed into
# blobs in one `git hash-object` call, the commit is then described to a
# single `git fast-import` run as the parent's tree plus the deletions and the
# staged entries (symlink targets travel inline), and fast-import writes the
# tree and commit objects and points a uniquely named temporary ref at the
# result. `jj git import` makes the commit known to jj; the ref and the
# imported bookmark are then removed before returning (jj anchors imported
# commits with its own refs/jj/keep refs, so the commit stays resolvable
# afterwards), and the ref's deletion is reconciled with a final import.
# fast-import unpacks a small result into loose objects, so the store does not
# accumulate a packfile per commit. Paths containing newlines are out of
# scope: staged files are iterated line-by-line from `find` output.
#
# Returns non-zero without logging when any step fails (except the backend
# check, whose stderr message is its own contract); the temporary ref is
# cleaned up on all paths.
_jj__commit_changeset() {
  local repo="$1" parent_rev="$2" message="$3" stage_dir="$4"
  shift 4
  local -a copy_specs=()
  while [[ "${1:-}" == --copy ]]; do
    [[ $# -ge 4 ]] || return 1
    copy_specs+=("$2" "$3" "$4")
    shift 4
  done
  _jj__check_backend_supported "$repo" || return $?
  local git_dir
  git_dir="$(__jj__resolve_git_dir "$repo")" || return 1
  # A full commit ID needs no resolution: fast-import verifies it names a
  # commit in the store, which is the same guarantee the backend query gives.
  local parent_commit
  if _jj__check_is_canonical_commit_id "$parent_rev"; then
    parent_commit="$parent_rev"
  else
    parent_commit="$(_jj__resolve_commit "$repo" "$parent_rev")" || return 1
  fi
  [[ -n "$parent_commit" ]] || return 1
  [[ -d "$stage_dir" ]] || return 1
  stage_dir="$(cd "$stage_dir" 2>/dev/null && pwd)" || return 1
  local identity user_name user_email
  identity="$(__jj__read_identity "$repo")" || return 1
  user_name="${identity%%$'\t'*}"
  user_email="${identity#*$'\t'}"
  [[ -n "$user_name" && -n "$user_email" ]] || return 1

  # Resolve each copy into tree entries of its source commit.
  local -a copy_modes=() copy_blobs=() copy_paths=()
  local c src_rev src_path dest_path src_commit record meta path found
  for (( c = 0; c < ${#copy_specs[@]}; c += 3 )); do
    src_rev="${copy_specs[c]}" src_path="${copy_specs[c + 1]}" dest_path="${copy_specs[c + 2]}"
    if _jj__check_is_canonical_commit_id "$src_rev"; then
      src_commit="$src_rev"
    else
      src_commit="$(_jj__resolve_commit "$repo" "$src_rev")" || return 1
    fi
    [[ -n "$src_commit" ]] || return 1
    found=''
    while IFS= read -r -d '' record; do
      meta="${record%%$'\t'*}"
      path="${record#*$'\t'}"
      if [[ "$path" == "$src_path" ]]; then
        copy_paths+=("$dest_path")
      elif [[ "$path" == "$src_path"/* ]]; then
        copy_paths+=("$dest_path/${path#"$src_path"/}")
      else
        continue
      fi
      copy_modes+=("${meta%% *}")
      copy_blobs+=("${meta##* }")
      found=1
    done < <(unset GIT_WORK_TREE GIT_INDEX_FILE
      __jj__git --git-dir="$git_dir" ls-tree -r -z "$src_commit" -- "$src_path")
    [[ -n "$found" ]] || return 1
  done

  # Collect the staged entries: regular files are hashed in one batch, symlink
  # targets are read here and embedded in the fast-import stream.
  local -a file_paths=() file_modes=() link_paths=() link_targets=()
  local entry rel link_target
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    rel="${entry#"$stage_dir"/}"
    if [[ -L "$entry" ]]; then
      link_target="$(readlink "$entry")" || return 1
      link_paths+=("$rel")
      link_targets+=("$link_target")
    else
      file_paths+=("$rel")
      if [[ -x "$entry" ]]; then file_modes+=(100755); else file_modes+=(100644); fi
    fi
  done < <(__jj__list_stage_entries "$stage_dir")

  # The remainder runs in a subshell so that an EXIT trap can clean up the
  # temporary ref on every path without leaking a trap into the caller, and
  # so that the byte-counting locale does not leak either. The variables the
  # trap reads are deliberately not `local`: an explicit exit from inside a
  # function unwinds its locals before the trap runs, and the subshell
  # already confines them.
  (
    ref_created=''
    tmp_ref="refs/heads/tt-tmp-$$-$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
    trap '
      if [[ -n "$ref_created" ]]; then
        __jj__git --git-dir="$git_dir" update-ref -d "$tmp_ref" || :
      fi
    ' EXIT
    # Ambient git environment must not redirect the object store or index.
    unset GIT_WORK_TREE GIT_INDEX_FILE

    local -a file_blobs=()
    if [[ ${#file_paths[@]} -gt 0 ]]; then
      local blob
      while IFS= read -r blob; do
        [[ -n "$blob" ]] && file_blobs+=("$blob")
      done < <(printf '%s\n' "${file_paths[@]/#/$stage_dir/}" \
        | __jj__git --git-dir="$git_dir" hash-object -w --stdin-paths)
      [[ ${#file_blobs[@]} -eq ${#file_paths[@]} ]] || exit 1
    fi

    # fast-import counts data in bytes; the C locale makes ${#…} count bytes.
    LC_ALL=C
    ref_created=1
    {
      printf 'commit %s\n' "$tmp_ref"
      printf 'author %s <%s> now\ncommitter %s <%s> now\n' \
        "$user_name" "$user_email" "$user_name" "$user_email"
      # A trailing newline terminates the message, as `git commit-tree -m` does.
      printf 'data %d\n%s\n' "$(( ${#message} + 1 ))" "$message"
      printf 'from %s\n' "$parent_commit"
      local delete_path
      for delete_path in "$@"; do
        printf 'D %s\n' "$(__jj__quote_import_path "$delete_path")"
      done
      local i
      for (( i = 0; i < ${#copy_paths[@]}; i++ )); do
        printf 'M %s %s %s\n' "${copy_modes[$i]}" "${copy_blobs[$i]}" \
          "$(__jj__quote_import_path "${copy_paths[$i]}")"
      done
      for (( i = 0; i < ${#file_paths[@]}; i++ )); do
        printf 'M %s %s %s\n' "${file_modes[$i]}" "${file_blobs[$i]}" \
          "$(__jj__quote_import_path "${file_paths[$i]}")"
      done
      for (( i = 0; i < ${#link_paths[@]}; i++ )); do
        printf 'M 120000 inline %s\ndata %d\n%s\n' \
          "$(__jj__quote_import_path "${link_paths[$i]}")" \
          "${#link_targets[$i]}" "${link_targets[$i]}"
      done
      printf '\n'
    } | __jj__git --git-dir="$git_dir" fast-import --quiet --date-format=now || exit 1

    local commit
    commit="$(__jj__git --git-dir="$git_dir" rev-parse --verify "${tmp_ref}^{commit}")" || exit 1
    [[ -n "$commit" ]] || exit 1

    # Import hop: the temporary ref makes the commit reachable so `jj git
    # import` picks it up; afterwards delete the git ref first (so a
    # concurrent auto-import cannot re-create the bookmark) and then forget
    # the bookmark the import created, together with its remote-tracking
    # record. Forgetting fails when the import did not create it, which is
    # what reports a failed import.
    __jj__write_internal "$repo" --ignore-working-copy git import || exit 1
    __jj__git --git-dir="$git_dir" update-ref -d "$tmp_ref" || exit 1
    ref_created=''
    __jj__write_internal "$repo" --ignore-working-copy bookmark forget --include-remotes \
      "${tmp_ref#refs/heads/}" || exit 1
    # Reconcile the out-of-band git ref deletion now: without this, jj's
    # last-seen git ref state still contains the temporary ref, and the next
    # auto-importing jj invocation would mint a surprise "import git refs"
    # operation outside any tt transaction. Forgetting the bookmark does not
    # clear that record when the operation runs from a worktree.
    __jj__write_internal "$repo" --ignore-working-copy git import || exit 1
    printf '%s\n' "$commit"
  )
}

# Usage: __jj__resolve_git_dir REPO
# Prints the absolute path of the Git directory that backs REPO's store.
# Returns 1 (nothing printed) when the store records no Git directory.
__jj__resolve_git_dir() {
  local repo="$1"
  local canonical_repo
  canonical_repo="$(_jj__resolve_repository_root "$repo")" || return 1
  # git_target names the backing Git directory relative to the store directory
  # itself (NOT relative to .jj/repo), and may in turn be a relative path, so
  # canonicalize from inside the store directory.
  local store_dir="$canonical_repo/.jj/repo/store"
  local git_target=''
  read -r git_target < "$store_dir/git_target" 2>/dev/null || :
  [[ -n "$git_target" ]] || return 1
  (cd "$store_dir" 2>/dev/null && cd "$git_target" 2>/dev/null && pwd -P)
}

# Usage: __jj__list_stage_entries DIR
# Prints every regular file and symlink beneath DIR, one absolute path per
# line, descending into subdirectories (dot entries included) without a
# process. Internal helper for _jj__commit_changeset.
__jj__list_stage_entries() {
  local dir="$1" entry
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    if [[ -L "$entry" || -f "$entry" ]]; then
      printf '%s\n' "$entry"
    elif [[ -d "$entry" ]]; then
      __jj__list_stage_entries "$entry"
    fi
  done
}

# Usage: __jj__quote_import_path PATH
# Prints PATH quoted for a `git fast-import` stream: always double-quoted,
# with backslashes, double quotes and newlines escaped, so any path the
# stream can carry is rendered unambiguously. Internal helper.
__jj__quote_import_path() {
  local path="$1"
  path="${path//\\/\\\\}"
  path="${path//\"/\\\"}"
  path="${path//$'\n'/\\n}"
  printf '"%s"' "$path"
}

# Usage: __jj__read_identity REPO
# Prints the jj-configured user.name and user.email for REPO on one line,
# tab-separated, reading both in a single backend query. Returns 1 (nothing
# printed) when either is unset. Internal helper for the bare-mutation
# operations.
__jj__read_identity() {
  local repo="$1"
  local records name='' email='' key value
  records="$(__jj__read "$repo" --ignore-working-copy config list user \
    -T 'name ++ "\t" ++ value.as_string() ++ "\n"')" || return 1
  while IFS=$'\t' read -r key value; do
    case "$key" in
      user.name)  name="$value" ;;
      user.email) email="$value" ;;
    esac
  done <<< "$records"
  [[ -n "$name" && -n "$email" ]] || return 1
  printf '%s\t%s' "$name" "$email"
}

# Usage: __jj__escape_revset_string TEXT
# Prints TEXT escaped for embedding inside a double-quoted jj revset string
# literal: backslashes, double quotes and newlines become \\, \" and \n.
# Internal helper for the bare-mutation operations.
__jj__escape_revset_string() {
  local text="$1"
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  text="${text//$'\n'/\\n}"
  printf '%s' "$text"
}

# Usage: _jj__create_merge_commit REPO MESSAGE PARENT_REV PARENT_REV [PARENT_REV...]
#
# Creates a merge commit with the given parents (at least two) and description
# MESSAGE, and prints its full commit ID. Never touches any working copy: the
# commit is created with `jj new --no-edit` under --ignore-working-copy.
#
# The new commit's ID is resolved without parsing human-readable output: each
# parent is resolved to its immutable commit ID up front, and after creation
# the commit is looked up via a revset intersecting children() of every
# parent with the exact stored description (jj appends a trailing newline to
# a non-empty description that lacks one), taking latest(). Within a repo a
# concurrent commit could only be picked up instead if it had the identical
# parent set, the identical description AND a newer committer timestamp.
_jj__create_merge_commit() {
  local repo="$1" message="$2"
  shift 2
  [[ $# -ge 2 ]] || return 1
  local parent_rev parent_commit parent_commits
  parent_commits=()
  for parent_rev in "$@"; do
    parent_commit="$(_jj__resolve_commit "$repo" "$parent_rev")" || return 1
    [[ -n "$parent_commit" ]] || return 1
    parent_commits+=("$parent_commit")
  done
  __jj__write "$repo" --ignore-working-copy new --no-edit -m "$message" \
    "${parent_commits[@]}" || return 1
  # Reproduce the description exactly as stored: jj appends "\n" when a
  # non-empty message lacks one, and stores everything else verbatim.
  local stored="$message"
  if [[ -n "$stored" ]]; then
    case "$stored" in
      *$'\n') ;;
      *) stored="$stored"$'\n' ;;
    esac
  fi
  local escaped
  escaped="$(__jj__escape_revset_string "$stored")"
  local intersection=''
  for parent_commit in "${parent_commits[@]}"; do
    if [[ -z "$intersection" ]]; then
      intersection="children(${parent_commit})"
    else
      intersection="${intersection} & children(${parent_commit})"
    fi
  done
  local new_commit
  new_commit="$(__jj__read "$repo" --ignore-working-copy log \
    -r "latest((${intersection}) & description(exact:\"${escaped}\"))" \
    --no-graph -T 'commit_id')" || return 1
  [[ -n "$new_commit" ]] || return 1
  printf '%s\n' "$new_commit"
}

# Usage: _jj__set_description REPO REV MESSAGE
# Replaces the description of REV with MESSAGE. Bare graph mutation: no
# working copy is touched (descendants are rewritten in the graph as usual).
# Status only; never logs, never exits.
_jj__set_description() {
  local repo="$1" rev="$2" message="$3"
  __jj__write "$repo" --ignore-working-copy describe -r "$rev" -m "$message"
}

# Usage: _jj__move_commits REPO DEST_REV SOURCE_REV [SOURCE_REV...]
# Rebases each SOURCE_REV, together with its tree of descendants
# (jj rebase -s), onto DEST_REV, in the order given. At least one source is
# required. Bare graph mutation: no working copy is touched. Status only;
# stops at the first failing source and returns its status.
_jj__move_commits() {
  local repo="$1" dest_rev="$2"
  shift 2
  [[ $# -ge 1 ]] || return 1
  local source_rev
  for source_rev in "$@"; do
    __jj__write "$repo" --ignore-working-copy rebase \
      -s "$source_rev" -d "$dest_rev" || return $?
  done
}

# Usage: _jj__squash_commit REPO FROM_REV INTO_REV
# Folds FROM_REV's changes into INTO_REV. The destination keeps its own
# identity (change ID) and its own description (--use-destination-message);
# the emptied source is abandoned. Bare graph mutation: no working copy is
# touched. Status only; never logs, never exits.
_jj__squash_commit() {
  local repo="$1" from_rev="$2" into_rev="$3"
  __jj__write "$repo" --ignore-working-copy squash \
    --from "$from_rev" --into "$into_rev" --use-destination-message
}

# Usage: _jj__restore_tree REPO SOURCE_REV TARGET_REV
# Sets TARGET_REV's tree wholesale to SOURCE_REV's tree, preserving TARGET's
# change ID, description and author. Descendants of TARGET are rebased with
# their CONTENT preserved rather than their diffs replayed
# (--restore-descendants). Bare graph mutation: no working copy is touched.
# Status only; never logs, never exits.
_jj__restore_tree() {
  local repo="$1" source_rev="$2" target_rev="$3"
  __jj__write "$repo" --ignore-working-copy restore \
    --from "$source_rev" --into "$target_rev" --restore-descendants
}

# Usage: _jj__restore_path REPO SOURCE_REV TARGET_REV PATH
# Sets the repo-root-relative PATH in TARGET_REV to its state in SOURCE_REV
# (content, mode, or absence), leaving the rest of TARGET's tree, its change
# ID, description and author untouched. A conflict on PATH in TARGET is
# replaced by SOURCE's state. Descendants of TARGET are rebased with their
# diffs replayed, so a descendant that does not change PATH inherits the
# restored state. Nothing is rewritten when PATH already matches. Bare graph
# mutation: no working copy is touched. Status only; never logs, never exits.
_jj__restore_path() {
  local repo="$1" source_rev="$2" target_rev="$3" path="$4"
  __jj__write "$repo" --ignore-working-copy restore \
    --from "$source_rev" --into "$target_rev" -- "root-file:\"${path}\""
}

# Usage: _jj__abandon_commit REPO REV
# Abandons REV, rebasing its descendants onto REV's parent(s); bookmarks
# pointing at REV are deleted by jj as part of the abandon. Bare graph
# mutation: no working copy is touched. Status only; never logs, never exits.
_jj__abandon_commit() {
  local repo="$1" rev="$2"
  __jj__write "$repo" --ignore-working-copy abandon "$rev"
}

# ---------------------------------------------------------------------------
# Bookmarks
# ---------------------------------------------------------------------------

# Usage: _jj__set_bookmark REPO NAME REV [--allow-backwards]
# Creates or moves bookmark NAME to REV. The revision is REQUIRED: there is no
# implicit-target form, so callers must always name the revision explicitly.
# By default jj refuses to move an existing bookmark to a revision that is not
# a descendant of its current position; the optional trailing
# --allow-backwards flag is passed through to `jj bookmark set` to permit such
# a move. Quiet mutation.
_jj__set_bookmark() {
  local repo="$1" name="$2" rev="$3"
  local -a extra_flags=()
  if [[ "${4:-}" == '--allow-backwards' ]]; then
    extra_flags=(--allow-backwards)
  fi
  __jj__write "$repo" --ignore-working-copy bookmark set "$name" -r "$rev" \
    "${extra_flags[@]+"${extra_flags[@]}"}"
}

# Usage: _jj__list_bookmark_names REPO
# Prints one local bookmark name per line (blank lines may appear and should
# be skipped by callers). Returns jj's exit code.
_jj__list_bookmark_names() {
  local repo="$1"
  __jj__read "$repo" --ignore-working-copy log -r 'bookmarks()' \
    -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' --no-graph
}

# Usage: _jj__list_bookmark_targets REPO
# Prints one "NAME<TAB>COMMIT" line per local bookmark, where COMMIT is the
# full ID of the commit the bookmark points at. COMMIT is empty when the
# bookmark is conflicted and so points at no single commit. Returns jj's exit
# code.
_jj__list_bookmark_targets() {
  local repo="$1"
  __jj__read "$repo" --ignore-working-copy bookmark list -T \
    'if(!remote && present, name ++ "\t" ++ if(normal_target, normal_target.commit_id()) ++ "\n")'
}

# Usage: _jj__list_bookmarks_at REPO REV
# Prints the local bookmark names attached to REV, one per line (nothing when
# REV has no bookmarks). Returns 1 when REV does not resolve.
_jj__list_bookmarks_at() {
  local repo="$1" rev="$2"
  local names
  names="$(__jj__read "$repo" --ignore-working-copy log -r "$rev" --no-graph \
    -T 'local_bookmarks.map(|b| b.name()).join("\n")')" || return 1
  [[ -n "$names" ]] && printf '%s\n' "$names"
  return 0
}

# Usage: _jj__check_bookmark_exists REPO NAME
# Returns 0 when a local bookmark named exactly NAME exists. Status only.
_jj__check_bookmark_exists() {
  local repo="$1" name="$2"
  local result
  result="$(__jj__read "$repo" --ignore-working-copy log \
    -r "bookmarks(exact:\"${name}\")" --no-graph -T '"x\n"')" || return 1
  [[ -n "$result" ]]
}

# Usage: _jj__rename_bookmark REPO OLD NEW
# Renames bookmark OLD to NEW. Quiet mutation; passes --ignore-working-copy
# because a bookmark rename is pure graph metadata — it neither reads nor
# writes any working copy — and loading one would make the rename fail in the
# one situation it is most needed: right after a bare rewrite, while the
# working copy still has to be refreshed.
_jj__rename_bookmark() {
  local repo="$1" old="$2" new="$3"
  __jj__write "$repo" --ignore-working-copy bookmark rename "$old" "$new"
}

# Usage: _jj__delete_bookmark REPO NAME
# Deletes bookmark NAME. Returns 1 when no such bookmark exists (jj itself
# treats deleting a missing bookmark as a warning-only no-op, so existence is
# checked explicitly to give callers a reliable status). Quiet mutation.
_jj__delete_bookmark() {
  local repo="$1" name="$2"
  _jj__check_bookmark_exists "$repo" "$name" || return 1
  __jj__write "$repo" --ignore-working-copy bookmark delete "$name"
}

# ---------------------------------------------------------------------------
# Worktrees
# ---------------------------------------------------------------------------

# Usage: _jj__resolve_worktree_root REPO
# Prints the workspace root for REPO, symlink-resolved; falls back to REPO if
# it is not a workspace. jj resolves `-R REPO` by requiring REPO itself to be
# a workspace root (it does not search upwards), and answers `workspace root`
# with that path canonicalized, so the answer is read from the filesystem
# without a backend process.
_jj__resolve_worktree_root() {
  local repo="$1"
  if [[ -d "$repo/.jj" ]]; then
    ( cd "$repo" 2>/dev/null && pwd -P ) && return 0
  fi
  printf '%s' "$repo"
}

# Usage: _jj__list_worktrees REPO
# Prints one line per jj workspace in REPO, formatted as "name: /absolute/path",
# or "name: <Error: ...>" when the workspace has no resolvable path.
# Parse each line with _worktree__parse_list_line (lib/worktree.sh).
_jj__list_worktrees() {
  local repo="$1"
  __jj__read "$repo" --ignore-working-copy workspace list --no-pager \
    -T 'name ++ ": " ++ root ++ "\n"'
}

# Usage: _jj__forget_worktree REPO NAME
# Removes the workspace named NAME from the repository model. Files on disk are
# untouched. Quiet mutation.
_jj__forget_worktree() {
  local repo="$1" name="$2"
  __jj__write "$repo" --ignore-working-copy workspace forget "$name"
}

# Usage: _jj__create_worktree REPO NAME PATH REV
# Adds a workspace named NAME at filesystem PATH, with its working copy
# started on top of REV. Quiet mutation.
#
# Loads the working copy deliberately: creating a workspace means writing that
# workspace's files to disk, so there is nothing to skip. jj enforces this and
# refuses the operation outright if told to ignore the working copy.
_jj__create_worktree() {
  local repo="$1" name="$2" path="$3" rev="$4"
  __jj__write "$repo" workspace add --name "$name" -r "$rev" "$path"
}

# Usage: _jj__get_worktree_revision REPO NAME
# Prints the commit ID of workspace NAME's working-copy commit. Returns 1
# (nothing printed) when no workspace named NAME exists.
_jj__get_worktree_revision() {
  local repo="$1" name="$2"
  __jj__read "$repo" --ignore-working-copy log -r "${name}@" --no-graph \
    -T 'commit_id'
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

# Usage: _jj__read_file_at_revision REPO REV PATH
# Reads a file at a named revision from a jj repo using a repo-root-relative path.
# Always passes --ignore-working-copy since these calls never read from @.
# Outputs file content to stdout. Returns jj's exit code (non-zero = file absent).
_jj__read_file_at_revision() {
  local repo="$1" rev="$2" path="$3"
  __jj__read "$repo" --ignore-working-copy file show -r "$rev" -- "root:$path"
}

__JJ__NULL_OBJECT_ID='0000000000000000000000000000000000000000'

# Usage: _jj__read_files_at_revisions REPO < REQUESTS
# Reads many files in one pass. REQUESTS holds one "COMMIT<TAB>PATH" line per
# file, where COMMIT is a full commit ID and PATH is repo-root-relative. Prints
# one NUL-terminated record per request, in request order:
#   +CONTENT   the file content, when PATH names a file at COMMIT (a symlink
#              yields its target)
#   -          when COMMIT is not a full commit ID, or PATH names no file there
# Files that contain NUL bytes are not supported. Returns 1 when the store
# cannot be read.
#
# The backing Git store answers all requests with a fixed number of processes,
# whatever the number of requests.
_jj__read_files_at_revisions() {
  local repo="$1"
  _jj__check_backend_supported "$repo" || return $?
  local git_dir
  git_dir="$(__jj__resolve_git_dir "$repo")" || return 1
  # Every request gets a reply in order. A request that does not name a file
  # becomes a query for the null object ID, which git reports as missing.
  local commit path
  while IFS=$'\t' read -r commit path; do
    if _jj__check_is_canonical_commit_id "$commit" && [[ -n "$path" ]]; then
      printf '%s:%s\n' "$commit" "$path"
    else
      printf '%s\n' "$__JJ__NULL_OBJECT_ID"
    fi
  done \
    | __jj__git --git-dir="$git_dir" cat-file --batch-check='%(objecttype) %(objectname)' \
    | awk -v null="$__JJ__NULL_OBJECT_ID" '{ print ($1 == "blob" && NF == 2) ? $2 : null }' \
    | __jj__git --git-dir="$git_dir" cat-file --batch \
    | __jj__frame_batch_records
}

# Usage: __jj__frame_batch_records < CAT_FILE_BATCH_OUTPUT
# Converts `git cat-file --batch` output for blobs into the records
# _jj__read_files_at_revisions prints. Each found blob arrives as an
# "OID blob SIZE" header line, SIZE bytes of content and a newline. Any other
# line reports a missing object.
__jj__frame_batch_records() {
  # The C locale makes length() and substr() count bytes, as SIZE does.
  LC_ALL=C awk '
    remaining > 0 {
      content = content $0 "\n"
      remaining -= length($0) + 1
      if (remaining <= 0) printf "+%s%c", substr(content, 1, size), 0
      next
    }
    NF == 3 && $2 == "blob" && $3 ~ /^[0-9]+$/ {
      size = $3 + 0; content = ""
      remaining = size + 1
      next
    }
    { printf "-%c", 0 }
  '
}

# Usage: _jj__read_symlink_at_revision REPO REV PATH
# Prints the target string of the symlink recorded at the repo-root-relative
# PATH in REV, without a trailing newline. Returns 1 (nothing printed) when
# PATH is absent at REV or is recorded as something other than a symlink.
#
# Symlink targets are not readable as file content — the backend rejects a
# request to show a path that is not a file — so the entry is read out of a
# Git-format diff of REV against the empty root tree, which renders the symlink
# as an added `120000`-mode file whose single added line is the target.
_jj__read_symlink_at_revision() {
  local repo="$1" rev="$2" path="$3"
  local diff
  diff="$(__jj__read "$repo" --ignore-working-copy diff --git \
    --from 'root()' --to "$rev" -- "root-file:\"${path}\"")" || return 1
  # One pass over the diff: note the symlink mode, then take the first added
  # line (the "+++ b/<path>" header is excluded by requiring a non-'+' second
  # character). A diff without both parts is not a symlink and exits non-zero.
  local target
  target="$(printf '%s\n' "$diff" | awk '
    /^new file mode 120000$/ { symlink = 1 }
    symlink && !found && /^\+[^+]/ { found = 1; print substr($0, 2) }
    END { exit(found ? 0 : 1) }
  ')" || return 1
  printf '%s' "$target"
}

# Usage: _jj__read_file_at_operation REPO OP REV PATH
# Reads a file at a specific jj operation ID and revision, using a
# repo-root-relative path. Used for historical rescue (e.g. recovering
# pre-rename file content).
# Outputs file content to stdout. Returns jj's exit code (non-zero = file absent).
_jj__read_file_at_operation() {
  local repo="$1" op="$2" rev="$3" path="$4"
  __jj__read "$repo" --ignore-working-copy --at-operation "$op" file show -r "$rev" -- "root:$path"
}

# Usage: _jj__check_file_exists_at_revision REPO REV PATH
# Returns 0 when the repo-root-relative file PATH exists at REV. Status only.
_jj__check_file_exists_at_revision() {
  local repo="$1" rev="$2" path="$3"
  __jj__read "$repo" --ignore-working-copy file show -r "$rev" -- "root:$path" \
    >/dev/null
}

# Usage: _jj__list_files_at_revision REPO REV [PREFIX]
# Prints the repo-relative paths of the files tracked at REV, one per line,
# optionally limited to the path prefix PREFIX (a repo-root-relative file or
# directory). Returns jj's exit code.
_jj__list_files_at_revision() {
  local repo="$1" rev="$2" prefix="${3:-}"
  local -a fileset=()
  [[ -n "$prefix" ]] && fileset=(-- "root:$prefix")
  # List from inside the repository ($PWD) to ensure printed file paths are relative to the repo root
  ( cd "$repo" && __jj__read "$PWD" --ignore-working-copy file list -r "$rev" \
      "${fileset[@]+"${fileset[@]}"}" )
}

# Usage: _jj__list_changed_files REPO REV
# Prints the repo-relative paths of the files that REV changes relative to
# its parents (added, modified or deleted), one per line. Passes
# --ignore-working-copy: when REV is @ and pending on-disk changes should be
# included, callers must snapshot first. Returns jj's exit code.
_jj__list_changed_files() {
  local repo="$1" rev="$2"
  # Diff from inside the repository ($PWD) to ensure printed file paths are relative to the repo root
  ( cd "$repo" && __jj__read "$PWD" --ignore-working-copy diff -r "$rev" --name-only )
}

# Usage: _jj__list_changed_files_in_range REPO BASE TIP
# Prints the repo-root-relative paths (one per line) changed across TIP's
# range relative to BASE — the commits reachable from TIP but not from BASE —
# diffed as a single unit, so content TIP merely inherited from BASE is never
# reported. The range's own root commits are excluded from the diff, so the
# paths they introduce are not reported either.
# Passes --ignore-working-copy. Returns jj's exit code.
_jj__list_changed_files_in_range() {
  local repo="$1" base="$2" tip="$3"
  # Diff from inside the repository ($PWD) to ensure printed file paths are relative to the repo root
  ( cd "$repo" && __jj__read "$PWD" --ignore-working-copy diff \
      -r "roots(::${tip} ~ ::${base})..${tip}" --name-only )
}

# Usage: _jj__list_files_at_operation REPO OP REV [PREFIX]
# Like _jj__list_files_at_revision, but reads at a specific operation ID.
_jj__list_files_at_operation() {
  local repo="$1" op="$2" rev="$3" prefix="${4:-}"
  local -a fileset=()
  [[ -n "$prefix" ]] && fileset=(-- "root:$prefix")
  # List from inside the repository ($PWD) to ensure printed file paths are relative to the repo root
  ( cd "$repo" && __jj__read "$PWD" --ignore-working-copy --at-operation "$op" file list -r "$rev" \
      "${fileset[@]+"${fileset[@]}"}" )
}

# Usage: _jj__get_file_diff REPO REV PATH
# Prints the Git-format diff that REV applies to the single repo-root-relative
# file PATH (empty when REV does not touch it). Returns jj's exit code.
_jj__get_file_diff() {
  local repo="$1" rev="$2" path="$3"
  __jj__read "$repo" --ignore-working-copy log --no-graph -r "$rev" \
    -T 'self.diff("root-file:\"'"${path}"'\"").git()'
}

# Usage: _jj__show_diff REPO FROM TO [EXCLUDE_KIND EXCLUDE_PATH ...]
# Prints the Git-format diff between revisions FROM and TO. Trailing arguments
# are pairs naming paths to exclude from the diff: "dir <path>" excludes a
# repo-root-relative directory, "file <path>" a repo-root-relative file; pairs
# with any other kind are ignored. Returns jj's exit code.
_jj__show_diff() {
  local repo="$1" from="$2" to="$3"
  shift 3
  local exclusion_terms='' kind path term
  while [[ $# -gt 0 ]]; do
    kind="$1" path="$2"
    shift 2
    case "$kind" in
      dir)  term="root:\"$path\"" ;;
      file) term="root-file:\"$path\"" ;;
      *)    continue ;;
    esac
    if [[ -z "$exclusion_terms" ]]; then
      exclusion_terms="$term"
    else
      exclusion_terms="$exclusion_terms | $term"
    fi
  done
  if [[ -n "$exclusion_terms" ]]; then
    __jj__read "$repo" --ignore-working-copy diff --git --from "$from" --to "$to" "~($exclusion_terms)"
  else
    __jj__read "$repo" --ignore-working-copy diff --git --from "$from" --to "$to"
  fi
}
