# jj backend for the tt VCS interface.
# Source this file; do not execute directly.
#
# Implements the backend contract declared in lib/repo.sh: every _jj__* function
# here has a corresponding _repo__* wrapper there. Only lib/repo.sh may call the
# _jj__* names; all other code goes through the _repo__* interface.
#
# Public surface:
#   Repository discovery:
#     _jj__check_is_repository       — test whether a directory is a jj repository
#     _jj__find_repository_root      — walk up from CWD to the enclosing repository
#     _jj__resolve_repository_root   — canonical repository root for any workspace
#     _jj__resolve_repository_path   — symlink-resolved canonical repository root
#   Operation log:
#     _jj__get_operation_id          — current operation ID
#   Revisions:
#     _jj__count_revisions           — number of commits matching a revset
#     _jj__get_commit_description    — full description of a revision
#     _jj__check_has_conflicts       — whether any commit in a revset has conflicts
#     _jj__list_mainline_commits     — first-parent mainline commit records
#   Working copy (restricted):
#     _jj__check_working_copy_clean  — whether the working copy has pending changes
#     _jj__get_working_copy_revision — change_id of @
#     _jj__get_working_copy_parent   — commit_id of @-
#     _jj__set_working_copy_revision — point the working copy at a revision
#     _jj__new_working_copy_child    — start a new working-copy commit
#     _jj__commit_working_copy       — commit the working copy with a message
#   Bookmarks:
#     _jj__set_bookmark              — move a bookmark to an explicit revision
#   Worktrees:
#     _jj__resolve_worktree_root     — workspace root for the current context
#     _jj__list_worktrees            — one "name: path" line per workspace
#     _jj__forget_worktree           — remove a workspace from the repository model
#   Files:
#     _jj__read_file_at_revision     — file content at a revision
#     _jj__read_file_at_operation    — file content at an operation + revision
#
# Read helpers suppress stderr (2>/dev/null) and report failure via exit
# status. Mutating helpers run jj bare so callers see its stderr output.

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
    dir="$(dirname "$dir")"
  done
  return 1
}

# Usage: _jj__resolve_repository_root REPO
# Returns the canonical repo root for the repository.
# If REPO is a secondary jj workspace (.jj/repo is a pointer file),
# follows the pointer to find the canonical repo root.
# If REPO is already the canonical repo (.jj/repo is a directory), returns REPO.
_jj__resolve_repository_root() {
  local repo="$1"
  local repo_entry="$repo/.jj/repo"
  if [[ -f "$repo_entry" ]]; then
    # Secondary workspace: .jj/repo is a file containing a relative path to
    # the canonical repo's .jj/repo directory (e.g. "../../../../repo/.jj/repo").
    local target
    target="$(cd "$repo/.jj" && realpath "$(cat "$repo_entry")")" \
      || { _ui__log "Error: Could not resolve canonical repo from $repo_entry"; return 1; }
    # target = /path/to/canonical/.jj/repo — strip /.jj/repo to get repo root
    dirname "$(dirname "$target")"
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

# ---------------------------------------------------------------------------
# Operation log
# ---------------------------------------------------------------------------

# Usage: _jj__get_operation_id REPO
# Prints the current jj operation ID to stdout.
# Returns 1 if the operation ID cannot be read.
#
# Runs jj in a subshell that cds into REPO first. This ensures jj can resolve
# its CWD even when the caller's working directory has been deleted (e.g. after
# a worktree is removed by `worktree delete`). The -R flag tells jj which repo
# to operate on, so the cd only affects CWD resolution, not the target repo.
_jj__get_operation_id() {
  local repo="$1"
  (cd "$repo" && jj -R "$repo" op log --no-graph -T id -n 1 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Revisions
# ---------------------------------------------------------------------------

# Usage: _jj__count_revisions REPO REVSET
# Prints the number of commits matching REVSET (0 if REVSET fails to resolve).
# TRANSITIONAL(B1): takes a raw revset; replaced by named range operations.
_jj__count_revisions() {
  local repo="$1" revset="$2"
  jj -R "$repo" log -r "$revset" --no-graph -T 'commit_id ++ "\n"' 2>/dev/null | grep -c . || true
}

# Usage: _jj__get_commit_description REPO REV
# Prints the full description of REV (empty if it has none).
_jj__get_commit_description() {
  local repo="$1" rev="$2"
  jj -R "$repo" log -r "$rev" --no-graph -T 'description'
}

# Usage: _jj__check_has_conflicts REPO_OR_WORKTREE REVSET
# Returns 0 (true) if any commit in REVSET has conflicts.
# TRANSITIONAL(B1): takes a raw revset; replaced by named range operations.
_jj__check_has_conflicts() {
  local repo="$1" revset="$2"
  local result
  result="$(jj -R "$repo" log -r "$revset" \
    --no-graph -T 'if(conflict, "yes\n")' 2>/dev/null)" || true
  [[ -n "$result" ]]
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
  jj -R "$repo" --ignore-working-copy log \
    -r "first_ancestors($tip) ~ ::$base" --no-graph --reversed \
    -T 'commit_id ++ "\t" ++ change_id ++ "\t" ++ committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ") ++ "\t" ++ parents.map(|p| p.commit_id()).join(" ") ++ "\t" ++ description.first_line() ++ "\n"' \
    2>/dev/null
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
  local r="$1"
  local result
  result="$(jj -R "$r" log -r '@' --no-graph -T 'empty' 2>/dev/null)" || return 1
  [[ "$result" == "true" ]]
}

# Usage: _jj__get_working_copy_revision WORKTREE
# Prints the change_id of @ in the given worktree. Exits 1 on failure.
# We return the change_id (not the commit_id) because change IDs survive
# rebases: if @ is a descendant of a rebased branch, jj creates a new
# commit with the same change ID, so `jj edit <change_id>` will always
# resolve to the correct (post-rebase) version of the working-copy commit.
_jj__get_working_copy_revision() {
  local worktree="$1"
  jj -R "$worktree" log -r '@' --no-graph -T 'change_id' 2>/dev/null
}

# Usage: _jj__get_working_copy_parent WORKTREE
# Prints the commit_id of the working-copy parent (@-) in the given worktree.
# Returns jj's exit code; nothing is printed if the parent cannot be resolved.
_jj__get_working_copy_parent() {
  local worktree="$1"
  jj -R "$worktree" log -r '@-' --no-graph -T 'commit_id' 2>/dev/null
}

# Usage: _jj__set_working_copy_revision WORKTREE REV
# Points the working copy at REV (jj edit). jj's stderr passes through to the
# caller.
_jj__set_working_copy_revision() {
  local worktree="$1" rev="$2"
  jj -R "$worktree" edit "$rev"
}

# Usage: _jj__new_working_copy_child WORKTREE [REV]
# Starts a new empty working-copy commit (jj new), on top of REV when given,
# otherwise on top of the current working-copy commit. jj's stderr passes
# through to the caller.
_jj__new_working_copy_child() {
  local worktree="$1" rev="${2:-}"
  if [[ -n "$rev" ]]; then
    jj -R "$worktree" new -r "$rev"
  else
    jj -R "$worktree" new
  fi
}

# Usage: _jj__commit_working_copy WORKTREE MESSAGE
# Commits the working copy with MESSAGE. jj's stderr passes through to the
# caller.
_jj__commit_working_copy() {
  local worktree="$1" message="$2"
  jj -R "$worktree" commit -m "$message"
}

# ---------------------------------------------------------------------------
# Bookmarks
# ---------------------------------------------------------------------------

# Usage: _jj__set_bookmark REPO NAME REV
# Creates or moves bookmark NAME to REV. The revision is REQUIRED: there is no
# implicit-target form, so callers must always name the revision explicitly.
# jj's stderr passes through to the caller.
_jj__set_bookmark() {
  local repo="$1" name="$2" rev="$3"
  jj -R "$repo" bookmark set "$name" -r "$rev"
}

# ---------------------------------------------------------------------------
# Worktrees
# ---------------------------------------------------------------------------

# Usage: _jj__resolve_worktree_root REPO
# Prints the current workspace root; falls back to REPO if not in a workspace.
_jj__resolve_worktree_root() {
  local repo="$1"
  jj -R "$repo" workspace root 2>/dev/null || printf '%s' "$repo"
}

# Usage: _jj__list_worktrees REPO
# Prints one line per jj workspace in REPO, formatted as "name: /absolute/path",
# or "name: <Error: ...>" when the workspace has no resolvable path.
# Parse each line with parse_workspace_list_line (lib/common.sh).
_jj__list_worktrees() {
  local repo="$1"
  jj -R "$repo" --ignore-working-copy workspace list --no-pager \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null
}

# Usage: _jj__forget_worktree REPO NAME
# Removes the workspace named NAME from the repository model. Files on disk are
# untouched. jj's stderr passes through to the caller.
_jj__forget_worktree() {
  local repo="$1" name="$2"
  jj -R "$repo" workspace forget "$name"
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

# Usage: _jj__read_file_at_revision REPO REV PATH
# Reads a file at a named revision from a jj repo using a root:-relative path.
# Always passes --ignore-working-copy since these calls never read from @.
# Outputs file content to stdout. Returns jj's exit code (non-zero = file absent).
_jj__read_file_at_revision() {
  local repo="$1" rev="$2" path="$3"
  jj -R "$repo" --ignore-working-copy file show -r "$rev" -- "root:$path" 2>/dev/null
}

# Usage: _jj__read_file_at_operation REPO OP REV PATH
# Reads a file at a specific jj operation ID and revision, using a root:-relative path.
# Used for historical rescue (e.g. recovering pre-rename file content).
# Outputs file content to stdout. Returns jj's exit code (non-zero = file absent).
_jj__read_file_at_operation() {
  local repo="$1" op="$2" rev="$3" path="$4"
  jj -R "$repo" --at-operation "$op" file show -r "$rev" -- "root:$path" 2>/dev/null
}
