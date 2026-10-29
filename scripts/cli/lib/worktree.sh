# Worktree management for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _worktree__parse_list_line  — parse one backend worktree-listing line into name/path
#   _worktree__list_entries     — one "name<TAB>path" record per workspace, canonical included
#   _worktree__list             — one "name<TAB>path<TAB>task_id" record per worktree
#   _worktree__resolve_name     — workspace name for a worktree path
#   _worktree__resolve_path     — recorded filesystem path for a workspace name
#   _worktree__resolve_current  — root of the worktree the command runs in
#   _worktree__find_current     — root of the worktree containing the CWD, or none
#   _worktree__resolve_repository_root — canonical repository root
#   _worktree__resolve_repository_path — canonical repository root, symlink-resolved
#   _worktree__check_clean      — whether a worktree has no uncommitted changes
#   _worktree__ensure_clean     — refuse to proceed while a worktree has uncommitted changes
#   _worktree__ensure_metadata_unmodified — refuse while uncommitted changes touch task metadata
#   _worktree__check_uncheckpointed_commits — whether a worktree has commits past its branch tip
#   _worktree__ensure_no_uncheckpointed_commits — refuse while a worktree has commits past its branch tip
#   _worktree__ensure_checkpointed — refuse unless a branch holds everything in a worktree
#   _worktree__check_stale      — whether a worktree's files match the commit it records
#   _worktree__check_exists     — whether a worktree already lives at a path
#   _worktree__create           — add a workspace at a path, started on a revision
#   _worktree__start_working_copy — move a worktree onto a new commit on a revision
#   _worktree__commit_working_copy — record a worktree's working copy as a commit
#   _worktree__resolve_working_copy_parent — commit a worktree's working copy sits on
#   _worktree__squash_into_working_copy — fold commits into a worktree's working copy
#   _worktree__record_working_copy — capture uncommitted work and name the operation holding it
#   _worktree__find_for_branch  — worktree roots whose current branch is a bookmark
#   _worktree__delete           — forget a workspace and remove its files from disk
#   _worktree__ensure_not_in_use — refuse to remove a worktree that other processes are using
#   _worktree__switch           — hooks + HEAD symlink update for a workspace switch
#   _worktree__ensure_working_copy — refuse branch writes while @ carries a bookmark
#   _worktree__ensure_worktree_current — refuse to act on a stale worktree
#   _worktree__ensure_canonical_current — refuse branch writes while canonical is stale
#   _worktree__reattach_current — follow a branch advance with a current worktree on it
#   _worktree__move_subtree     — rewrite a subtree the current working copy may sit in
#   _worktree__refresh_current  — update the current worktree after a bare rewrite of @
#   _worktree__refresh          — update a named worktree after a bare rewrite of its @
#   _worktree__report_stale     — stderr refusal naming a stale worktree and its remedy
#   _worktree__report_indeterminate — stderr refusal naming an unreadable worktree
#   _worktree__list_holding_descendants — other worktrees positioned inside a rewrite range
#   _worktree__resolve_branch   — the branch a worktree is sitting on
#   _worktree__resolve_branch_at — the branch recorded by a revision's task symlink
#   _worktree__check_behind     — whether a worktree is behind its branch head
#   _worktree__list_unsynced    — worktrees left behind by a write to their branch
#   _worktree__list_all_unsynced — every worktree behind its own branch head
#   _worktree__report_unsynced  — stderr warning naming out-of-sync worktrees
#   _worktree__sync             — bring a worktree forward onto its branch head
#   _worktree__list_sync_changes — files a sync updates on disk, with their status
#
# Functions named with a double underscore (__worktree__*) are internal helpers
# private to this module and not part of the public surface.

# Usage: _worktree__parse_list_line LINE
# Parses one line of the backend's worktree listing, formatted "<name>: <root>".
# Outputs two lines to stdout:
#   line 1: workspace name
#   line 2: absolute filesystem path, or empty string if the path is an error
#            (i.e. the workspace has no recorded or resolvable path)
# Lines with error paths look like: "name: <Error: Workspace has no recorded path: name>"
_worktree__parse_list_line() {
  local line="$1"
  local ws_name ws_path
  ws_name="${line%%: *}"
  ws_path="${line#*: }"
  if [[ "$ws_path" == '<Error:'* ]]; then
    ws_path=''
  fi
  printf '%s\n%s\n' "$ws_name" "$ws_path"
}

# Usage: _worktree__list_entries REPO
# Prints one tab-separated "name<TAB>path" record per workspace in REPO: every
# worktree, and the canonical repository too. path is the empty string when the
# workspace has no resolvable path. Returns 1 if the workspace list cannot be
# read.
#
# This is the inventory of everything the backend knows about, which is what a
# caller needs to validate a workspace the user named explicitly (the canonical
# repository included). A caller that picks workspaces to act on by itself
# wants __worktree__list_worktree_entries or __worktree__list_in_scope_entries
# instead.
_worktree__list_entries() {
  local repo="$1"
  local ws_raw
  ws_raw="$(_repo__list_worktrees "$repo")" || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local parsed ws_name ws_path
    parsed="$(_worktree__parse_list_line "$line")"
    ws_name="${parsed%%$'\n'*}"
    ws_path="${parsed#*$'\n'}"
    [[ "$ws_path" == "$parsed" ]] && ws_path=''
    printf '%s\t%s\n' "$ws_name" "$ws_path"
  done <<< "$ws_raw"
}

# Usage: __worktree__list_worktree_entries REPO
# Prints one tab-separated "name<TAB>path" record per worktree in REPO, in the
# order of the workspace listing. The canonical repository is not a worktree and
# is left out; it is recognized by comparing symlink-resolved paths, so a
# symlinked root cannot slip through. path is the empty string when the worktree
# has no resolvable path. Returns 1 if the workspace list or the canonical
# repository root cannot be read.
__worktree__list_worktree_entries() {
  local repo="$1"
  local entries canonical
  entries="$(_worktree__list_entries "$repo")" || return 1
  canonical="$(_worktree__resolve_repository_path "$repo")" || return 1
  local ws_name ws_path resolved
  while IFS=$'\t' read -r ws_name ws_path; do
    [[ -z "$ws_name" ]] && continue
    if [[ -n "$ws_path" ]]; then
      resolved="$(_path__resolve_symlinks "$ws_path" 2>/dev/null)" || resolved="$ws_path"
      [[ "$resolved" == "$canonical" ]] && continue
    fi
    printf '%s\t%s\n' "$ws_name" "$ws_path"
  done <<< "$entries"
}

# Usage: __worktree__list_in_scope_entries REPO
#
# Prints one tab-separated "name<TAB>path" record per workspace in scope for
# the current command, in the order of the workspace listing. A workspace is in
# scope when it is a worktree, or when it is the current workspace (the one the
# command runs in, per _repo__resolve_worktree_root). path is the empty string
# when the workspace has no resolvable path. Returns 1 if the workspace list or
# the canonical repository root cannot be read.
#
# The distinction only matters for the canonical repository, which is in scope
# exactly when the command runs from it. The canonical repository is where the
# user works when they do not use worktrees, so a command run from there may act
# on it; when the user works in worktrees, it stays wherever they left it.
__worktree__list_in_scope_entries() {
  local repo="$1"
  local canonical current
  canonical="$(_worktree__resolve_repository_path "$repo")" || return 1
  current="$(_repo__resolve_worktree_root "$repo")" || return 1
  if [[ "$current" == "$canonical" ]]; then
    _worktree__list_entries "$repo"
  else
    __worktree__list_worktree_entries "$repo"
  fi
}

# Usage: _worktree__list REPO
# Prints tab-separated worktree data, one line per worktree (the canonical
# repository is not listed):
#   name\tpath\ttask_id
# path is empty string if unavailable; task_id is empty string if the worktree
# holds no task — each worktree's task is the one its own working copy records
# (_worktree__resolve_branch), so a worktree a branch write has left behind is
# still named by the task it has checked out.
_worktree__list() {
  local repo="$1"
  local entries
  entries="$(__worktree__list_worktree_entries "$repo")" || return 0
  local ws_name ws_path task_id
  while IFS=$'\t' read -r ws_name ws_path; do
    [[ -z "$ws_name" ]] && continue

    task_id=''
    if [[ -n "$ws_path" && -d "$ws_path" ]]; then
      task_id="$(_worktree__resolve_branch "$repo" "$ws_path" 2>/dev/null)" || true
    fi

    printf '%s\t%s\t%s\n' "$ws_name" "$ws_path" "$task_id"
  done <<< "$entries"
}

# Usage: _worktree__resolve_name REPO WORKTREE_PATH
# Prints the backend's worktree name for the worktree at WORKTREE_PATH.
# Returns 0 and prints name if found, returns 1 if not found.
_worktree__resolve_name() {
  local repo="$1" worktree_path="$2"
  local entries
  entries="$(_worktree__list_entries "$repo")" || return 1
  local name path
  while IFS=$'\t' read -r name path; do
    [[ "$path" == "$worktree_path" ]] || continue
    printf '%s' "$name"
    return 0
  done <<< "$entries"
  return 1
}

# Usage: _worktree__resolve_path REPO WS_NAME
# Prints the recorded filesystem path of the worktree named WS_NAME.
# Prints an empty string if the workspace has no recorded path.
# Returns 0 if found, 1 if no workspace bears that name.
_worktree__resolve_path() {
  local repo="$1" ws_name="$2"
  local entries
  entries="$(_worktree__list_entries "$repo")" || return 1
  local name path
  while IFS=$'\t' read -r name path; do
    [[ "$name" == "$ws_name" ]] || continue
    printf '%s' "$path"
    return 0
  done <<< "$entries"
  return 1
}

# Usage: _worktree__resolve_current REPO
# Prints the root of the worktree the command is running in (resolved from
# CWD, falling back to REPO). Documented pass-through to
# _repo__resolve_worktree_root so commands can name the current worktree (e.g.
# as a hook's working directory) without reaching into the VCS layer.
_worktree__resolve_current() {
  local repo="$1"
  _repo__resolve_worktree_root "$repo"
}

# Usage: _worktree__find_current
#
# Prints the root of the worktree that contains the current working directory,
# resolved from the CWD alone and taking no repository argument. Every worktree
# is a workspace in its own right — it owns a VCS metadata directory of its own
# — so walking up from the CWD to the nearest workspace lands on the worktree
# the user is standing in.
#
# Unlike _worktree__resolve_current, there is deliberately no fallback: the
# function returns 1 (printing nothing) when the CWD lies outside every
# worktree, which is exactly the condition a command must report when it is
# asked to act on "the current worktree" and there is none. It is also usable
# before the repository has been resolved, which matters for commands whose
# repository argument would otherwise mask the CWD.
#
# Documented pass-through to _repo__find_repository_root.
_worktree__find_current() {
  _repo__find_repository_root
}

# Usage: _worktree__resolve_repository_root REPO
# Prints the canonical repository root for REPO, which may itself be a
# worktree. Documented pass-through to _repo__resolve_repository_root so
# commands can name the canonical repository (e.g. as a fallback when a branch
# is not checked out in any worktree) without reaching into the VCS layer.
# Canonicalize the result with _path__resolve_symlinks before comparing it
# against other resolved paths.
_worktree__resolve_repository_root() {
  local repo="$1"
  _repo__resolve_repository_root "$repo"
}

# Usage: _worktree__resolve_repository_path REPO
# Prints the canonical repository root for REPO with every symlink in the path
# resolved — the comparison-ready form of _worktree__resolve_repository_root.
# Use it wherever the result is tested against another canonicalized path (a
# worktree path from the workspace listing, say), so that a symlinked root does
# not defeat the comparison; use the plain variant when the path is only being
# reported or passed on. Returns non-zero when the canonical root cannot be
# resolved. Documented pass-through to _repo__resolve_repository_path.
_worktree__resolve_repository_path() {
  local repo="$1"
  _repo__resolve_repository_path "$repo"
}

# Usage: _worktree__check_clean WORKTREE
# Returns 0 when WORKTREE's working copy has no uncommitted changes (pending
# on-disk edits are snapshotted first, so files the backend has not yet seen
# count as dirt). Documented pass-through to _repo__check_working_copy_clean so
# commands with a clean-working-copy precondition can test it without
# reaching into the VCS layer.
_worktree__check_clean() {
  local worktree="$1"
  _repo__check_working_copy_clean "$worktree"
}

# Usage: _worktree__ensure_clean WORKTREE [ALTERNATIVES]
#
# Guards a precondition that everything in WORKTREE is committed: returns 0
# when its working copy has no uncommitted changes, and reports a refusal
# naming WORKTREE on stderr and returns 1 otherwise. ALTERNATIVES is the clause
# that follows the remedy, such as "or use --force" in "Commit or discard
# changes first, or use --force."; when empty, the remedy stands alone.
_worktree__ensure_clean() {
  local worktree="$1" alternatives="${2:-}"
  _worktree__check_clean "$worktree" && return 0
  _ui__log "Error: Worktree '$worktree' has uncommitted changes."
  _ui__log "  Commit or discard changes first$(__worktree__format_alternatives "$alternatives")"
  return 1
}

# Usage: _worktree__ensure_metadata_unmodified WORKTREE [ALTERNATIVES]
#
# Guards the files tt rewrites on task branches (_path__check_is_task_metadata)
# against hand edits pending in WORKTREE's working copy. A branch write that
# reattaches the working copy, or a sync that moves it, replays those edits on
# top of tt's own rewrite of the same files, and overlapping changes leave the
# working copy conflicted without the command failing. Returns 0 when no
# uncommitted change touches task metadata; otherwise reports a refusal naming
# WORKTREE and every offending path on stderr and returns 1. ALTERNATIVES is as
# for _worktree__ensure_clean.
#
# A working copy whose changes cannot be listed refuses rather than passing:
# the caller is about to replay whatever those changes are.
_worktree__ensure_metadata_unmodified() {
  local worktree="$1" alternatives="${2:-}"
  local changes
  if ! changes="$(_repo__list_working_copy_changes "$worktree")"; then
    _ui__log "Error: Cannot list the uncommitted changes in worktree '$worktree'."
    return 1
  fi
  local path
  local -a modified=()
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    _path__check_is_task_metadata "$path" && modified+=("$path")
  done <<< "$changes"
  [[ ${#modified[@]} -eq 0 ]] && return 0
  _ui__log "Error: Worktree '$worktree' has uncommitted changes to task metadata:"
  for path in "${modified[@]}"; do
    _ui__log "  $path"
  done
  _ui__log "  Discard these changes first$(__worktree__format_alternatives "$alternatives")"
  return 1
}

# Usage: _worktree__check_uncheckpointed_commits WORKTREE BRANCH
#
# Returns 0 when WORKTREE's working copy sits above commits that BRANCH does
# not reach — commits made since the last tt write to BRANCH (typically with
# a plain VCS commit) that no checkpoint has yet recorded on the branch:
#
#   @        working copy
#   o  C2    uncheckpointed
#   o  C1    uncheckpointed
#   o  BRANCH
#
# A branch write builds on the branch tip, so these commits drop out of the
# working copy's ancestry when the working copy is reattached to the new tip.
# Returns 1 when there are none, including when the range cannot be resolved.
_worktree__check_uncheckpointed_commits() {
  local worktree="$1" branch="$2"
  local count
  count="$(_repo__count_commits_in_range "$worktree" "$branch" '@-')"
  [[ "$count" -gt 0 ]]
}

# Usage: _worktree__ensure_no_uncheckpointed_commits WORKTREE BRANCH [ALTERNATIVES]
#
# Guards against uncheckpointed commits (_worktree__check_uncheckpointed_commits):
# returns 0 when there are none, and reports a refusal naming WORKTREE and
# BRANCH on stderr and returns 1 otherwise. ALTERNATIVES is as for
# _worktree__ensure_clean.
_worktree__ensure_no_uncheckpointed_commits() {
  local worktree="$1" branch="$2" alternatives="${3:-}"
  _worktree__check_uncheckpointed_commits "$worktree" "$branch" || return 0
  _ui__log "Error: Worktree '$worktree' has commits after the task bookmark '$branch'."
  _ui__log "  Checkpoint or discard these commits first$(__worktree__format_alternatives "$alternatives")"
  return 1
}

# Usage: _worktree__ensure_checkpointed WORKTREE BRANCH [ALTERNATIVES]
#
# Guards a precondition that BRANCH holds everything in WORKTREE: no
# uncheckpointed commits above the branch tip and no uncommitted changes.
# Reports the first violation found (see the two guards it combines) and
# returns 1, or returns 0 when both hold.
_worktree__ensure_checkpointed() {
  local worktree="$1" branch="$2" alternatives="${3:-}"
  _worktree__ensure_no_uncheckpointed_commits "$worktree" "$branch" "$alternatives" \
    && _worktree__ensure_clean "$worktree" "$alternatives"
}

# Usage: __worktree__format_alternatives ALTERNATIVES
# Prints the sentence ending that follows a refusal's remedy: ", ALTERNATIVES."
# when ALTERNATIVES is given, or "." alone otherwise.
__worktree__format_alternatives() {
  local alternatives="$1"
  if [[ -n "$alternatives" ]]; then
    printf ', %s.' "$alternatives"
  else
    printf '.'
  fi
}

# Usage: _worktree__check_stale REPO WORKTREE
#
# Reports whether WORKTREE is stale — its on-disk files belong to a commit the
# repository has since rewritten, which the backend refuses to work with until
# the worktree is refreshed (tt worktree refresh).
#
#   0 — WORKTREE is stale
#   1 — WORKTREE is not stale
#   2 — WORKTREE's state could not be determined
#
# Status 2 is a distinct outcome and is never folded into either boolean: a
# workspace whose state cannot be read is not evidence that it is healthy, and
# callers must be free to refuse rather than act on a guess. The backend's own
# account of why the read failed reaches the user through TT_LOG.
#
# Reads only: nothing is snapshotted and no operation is recorded, so this is
# safe to run ahead of every branch write and against a worktree holding
# uncommitted work. It answers for any worktree in the repository, not only the
# invoking one.
#
# Staleness is not the same condition as a worktree being *behind* its branch:
# a bookmark advancing past a worktree leaves its files valid but old, which
# _worktree__check_behind reports and tt worktree sync resolves.
#
# REPO takes the module's usual leading position so callers read alike; the
# comparison itself is answered entirely from WORKTREE.
_worktree__check_stale() {
  local worktree="$2"
  local matched current
  matched="$(_repo__get_worktree_checkout_revision "$worktree")" || return 2
  [[ -n "$matched" ]] || return 2
  current="$(_repo__resolve_commit "$worktree" '@')" || return 2
  [[ -n "$current" ]] || return 2
  [[ "$matched" != "$current" ]]
}

# Usage: _worktree__check_exists PATH
# Returns 0 when a worktree already lives at PATH on disk — the directory
# exists and the backend recognizes it as a worktree root. Commands use this
# to decide whether to adopt the worktree already there or create a new one,
# so the on-disk shape of a worktree stays known only to the VCS layer.
_worktree__check_exists() {
  local path="$1"
  [[ -d "$path" ]] && _repo__check_is_repository "$path"
}

# ---------------------------------------------------------------------------
# Working-copy-bound operations
#
# The facades below read or move a named worktree's working copy, and each
# takes the WORKTREE root (not an arbitrary repository path) as its first
# argument so the caller must know which working copy it is addressing. They
# exist for the three commands whose whole purpose is the working copy — tt
# task checkpoint, tt task checkout and tt workspace init — plus the sync
# machinery further down this module. Every other command writes its branch
# bare (lib/task.sh) and must NOT reach for these: a bare write leaves every
# working copy where the user parked it, which is what makes it safe to run
# from a worktree carrying unrelated uncommitted work.
# ---------------------------------------------------------------------------

# Usage: _worktree__create REPO NAME PATH REV
# Adds a workspace named NAME at filesystem PATH to REPO, with a fresh
# working-copy commit started on top of REV, and populates PATH with REV's
# files. Counterpart of _worktree__delete. Working-copy-bound: creating a
# worktree is a working-copy operation by definition, so only a command whose
# purpose is to populate a worktree calls this. Documented pass-through to
# _repo__create_worktree.
_worktree__create() {
  local repo="$1" name="$2" path="$3" rev="$4"
  _repo__create_worktree "$repo" "$name" "$path" "$rev"
}

# Usage: _worktree__start_working_copy WORKTREE REV
# Moves WORKTREE onto a new, empty working-copy commit whose parent is REV,
# updating its files on disk to REV's content. This is how a command that
# switches a worktree to a branch parks it above the branch tip rather than on
# it. Working-copy-bound. Documented pass-through to
# _repo__new_working_copy_child.
_worktree__start_working_copy() {
  local worktree="$1" rev="$2"
  _repo__new_working_copy_child "$worktree" "$rev"
}

# Usage: _worktree__commit_working_copy WORKTREE MESSAGE
# Records WORKTREE's working copy as a commit described by MESSAGE and leaves
# the worktree on a new, empty working-copy commit on top of it. Pending
# on-disk edits are snapshotted as part of the operation, so this captures
# exactly what the user has in front of them — which is why only a command
# asked to record the working copy may call it. The resulting commit is
# WORKTREE's working-copy parent afterwards
# (_worktree__resolve_working_copy_parent). Working-copy-bound. Documented
# pass-through to _repo__commit_working_copy.
_worktree__commit_working_copy() {
  local worktree="$1" message="$2"
  _repo__commit_working_copy "$worktree" "$message"
}

# Usage: _worktree__resolve_working_copy_parent WORKTREE
# Prints the commit ID of the commit WORKTREE's working copy sits on. Callers
# use it both to name a commit they have just recorded and to bound a range at
# the working copy's position. Working-copy-bound. Returns non-zero (nothing
# printed) when the parent cannot be resolved. Documented pass-through to
# _repo__get_working_copy_parent.
_worktree__resolve_working_copy_parent() {
  local worktree="$1"
  _repo__get_working_copy_parent "$worktree"
}

# Usage: _worktree__squash_into_working_copy WORKTREE REV [REV...]
#
# Folds each given revision — every one an ancestor of WORKTREE's working-copy
# commit — into that working-copy commit, so the work they carry ends up in a
# single commit the caller can then record with a message of its own
# (_worktree__commit_working_copy). The emptied sources are abandoned and the
# working-copy commit keeps its own identity, so the whole run collapses onto
# the nearest bookmarked ancestor.
#
# Three steps, in this order:
#   1. Snapshot, so pending on-disk edits are part of the working-copy commit
#      before anything is rewritten rather than being folded in blind.
#   2. Resolve every source to its stable change ID up front, then squash them
#      in turn: each squash rebases the commits above it, which invalidates
#      the commit IDs of the sources still to come.
#   3. Refresh the worktree, because the squashes are bare graph mutations:
#      they rewrite the working-copy commit without updating the files on disk,
#      and the backend refuses further working-copy commands until that
#      mismatch is resolved. The files themselves do not change — the
#      working-copy commit already contained the sources' content as an
#      inherited ancestor.
#
# Working-copy-bound. Returns non-zero as soon as any step fails.
_worktree__squash_into_working_copy() {
  local worktree="$1"; shift
  [[ $# -ge 1 ]] || return 1
  _repo__snapshot_worktree "$worktree" || return 1
  local wc_change
  wc_change="$(_repo__get_working_copy_revision "$worktree")" || return 1
  [[ -n "$wc_change" ]] || return 1
  local rev change
  local -a sources=()
  for rev in "$@"; do
    change="$(_repo__resolve_change "$worktree" "$rev")" || return 1
    [[ -n "$change" ]] || return 1
    sources+=("$change")
  done
  for change in "${sources[@]}"; do
    _repo__squash_commit "$worktree" "$change" "$wc_change" || return 1
  done
  _repo__refresh_worktree "$worktree"
}

# Usage: _worktree__record_working_copy WORKTREE
#
# Captures whatever is uncommitted in WORKTREE into its working-copy commit,
# and prints the identifier of the operation that did so. Prints nothing when
# there was nothing to capture.
#
# For commands that are about to discard or overwrite a working copy. The
# recorded operation is the only route back to the work, so a caller that
# destroys uncommitted changes should show the user what this prints.
#
# Snapshotting a worktree from outside it is safe in a way that rewriting one
# is not: it only records what is already on disk, and never updates a working
# copy to match a commit it does not contain.
#
# Returns non-zero if the worktree cannot be captured, so that empty output
# means "there was nothing to record" and nothing else. A caller about to
# destroy the worktree must treat failure as fatal: proceeding would discard
# work it has just been unable to make recoverable. Callers resolve the path
# from the worktree listing moments before calling, so a worktree that is not
# there was removed mid-command.
_worktree__record_working_copy() {
  local worktree="$1"
  _worktree__check_exists "$worktree" || return 1
  local before after
  before="$(_repo__get_operation_id "$worktree")" || return 1
  _repo__snapshot_worktree "$worktree" || return 1
  after="$(_repo__get_operation_id "$worktree")" || return 1
  [[ "$after" != "$before" ]] && printf '%s' "$after"
  return 0
}

# Usage: _worktree__find_for_branch REPO BOOKMARK
# Outputs one worktree root path per line for each worktree whose working-copy
# commit records BOOKMARK as its checked-out task
# (_worktree__resolve_branch_at), so a worktree a branch write has left behind
# is still attributed to the branch it is on. Worktrees are listed in the order
# of the workspace listing.
#
# The canonical repository is never part of the result, even when its working
# copy records BOOKMARK: it is not a worktree, and the user may have left it on
# any branch. Callers that need somewhere to act when no worktree holds the
# branch fall back to it explicitly (_worktree__resolve_repository_root).
#
# The result is written in one go, so a caller reading only part of it cannot
# kill the search mid-write.
_worktree__find_for_branch() {
  local repo="$1" bookmark="$2"
  local entries
  entries="$(__worktree__list_worktree_entries "$repo")" || return 0
  local ws_root wc_commit ws_bookmark
  local found=''
  while IFS=$'\t' read -r _ ws_root; do
    [[ -z "$ws_root" || ! -d "$ws_root" ]] && continue
    wc_commit="$(_repo__resolve_commit "$ws_root" '@' 2>/dev/null)" || continue
    ws_bookmark="$(_worktree__resolve_branch_at "$repo" "$wc_commit" 2>/dev/null)" || continue
    [[ "$ws_bookmark" == "$bookmark" ]] || continue
    found="${found}${ws_root}"$'\n'
  done <<< "$entries"
  printf '%s' "$found"
  return 0
}

# Usage: _worktree__delete REPO WORKSPACE_NAME [WORKTREE_PATH]
# Forgets the worktree from the repository model.
# If WORKTREE_PATH is provided, also removes all files from disk.
_worktree__delete() {
  local repo="$1" ws_name="$2" worktree_path="${3:-}"
  _repo__forget_worktree "$repo" "$ws_name"
  if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
    rm -rf "$worktree_path"
  fi
}

# Usage: _worktree__ensure_not_in_use WORKTREE ALTERNATIVES
#
# Guards a worktree the caller is about to remove from disk: returns 0 when no
# process has its current directory or an open file inside WORKTREE, and
# reports a refusal on stderr and returns 1 otherwise. A process using the
# files can make their removal fail partway (a server writing into the tree
# recreates what was just removed), leaving a deregistered workspace whose
# files are still partly on disk. The refusal lists each process by PID and
# command name, and ends with ALTERNATIVES: the clause that follows the
# remedy, such as "or use --force" in "Stop these processes first, or use
# --force."
#
# The command's own process, its ancestors (such as the shell it was launched
# from) and its descendants are not counted, so a command run from inside
# WORKTREE does not block itself.
#
# The check relies on lsof. When lsof is not installed or fails, the guard
# refuses: the worktree cannot be shown to be unused.
_worktree__ensure_not_in_use() {
  local worktree="$1" alternatives="$2"
  local canonical_worktree
  canonical_worktree="$(_path__resolve_symlinks "$worktree" 2>/dev/null)" || canonical_worktree="$worktree"
  local processes status=0
  processes="$(__worktree__list_processes_using "$canonical_worktree")" || status=$?
  case "$status" in
    0)
      ;;
    2)
      _ui__log "Error: Cannot check whether worktree '$worktree' is in use: lsof is not installed."
      _ui__log "  Install lsof, $alternatives."
      return 1
      ;;
    *)
      _ui__log "Error: Cannot check whether worktree '$worktree' is in use: lsof failed."
      _ui__log "  Resolve the lsof failure, $alternatives."
      return 1
      ;;
  esac
  if [[ -z "$processes" ]]; then
    return 0
  fi
  _ui__log "Error: Worktree '$worktree' is in use by the following processes:"
  local process
  while IFS= read -r process; do
    _ui__log "  $process"
  done <<< "$processes"
  _ui__log "  Stop these processes first, $alternatives."
  return 1
}

# Usage: __worktree__list_processes_using DIR
#
# Prints "PID COMMAND" for each process whose current directory or any open
# file lies at or under DIR, one line per process, ordered by PID. DIR must be
# absolute and symlink-resolved, since lsof reports resolved paths. Excludes
# this command's own process ($$), its ancestors and its descendants. Returns
# 2 when lsof is not installed and 3 when it fails.
#
# One lsof listing supplies both the open files and each process's parent
# (the R field), so the process tree is read from the same snapshot as the
# files. The listing is captured before it is filtered: the filtering
# processes are then absent from it, and lsof itself, which is present, is a
# descendant of this command.
__worktree__list_processes_using() {
  local dir="$1"
  command -v lsof >/dev/null 2>&1 || return 2
  local listing
  listing="$(lsof +c 0 -n -P -F pRcn 2>/dev/null)" || return 3
  printf '%s\n' "$listing" | awk -v dir="$dir" -v self="$$" '
    /^p/ { pid = substr($0, 2); next }
    /^R/ { parent[pid] = substr($0, 2); next }
    /^c/ { command[pid] = substr($0, 2); next }
    /^n/ {
      name = substr($0, 2)
      if (name == dir || index(name, dir "/") == 1) using[pid] = 1
      next
    }
    function parent_of(p) { return (p in parent) ? parent[p] : "" }
    function is_related(p,    steps) {
      if (p in lineage) return 1
      for (steps = 0; p != "" && steps < 1000; steps++) {
        if (p == self) return 1
        p = parent_of(p)
      }
      return 0
    }
    END {
      for (p = self; p != "" && !(p in lineage); p = parent_of(p)) lineage[p] = 1
      for (pid in using) {
        if (!is_related(pid)) printf "%s %s\n", pid, command[pid]
      }
    }
  ' | sort -n
}

# Usage: _worktree__switch REPO WORKSPACE_DIR TASK_ID TARGET_WORKTREE OUTGOING_WORKTREE PREVIOUS_TASK_ID
# Fires pre-checkout hook, updates HEAD symlink, fires post-checkout hook.
_worktree__switch() {
  local repo="$1" workspace_dir="$2" task_id="$3"
  local target_worktree="$4" outgoing_worktree="$5" previous_task_id="$6"

  _ui__log "Switching to $task_id"

  _hook__run "$repo" "pre-checkout" true "$outgoing_worktree" "${workspace_dir:-}" \
    "TT_TASK_ID=$task_id" \
    "TT_TASK_BRANCH=$task_id" \
    "TT_PREVIOUS_TASK_ID=${previous_task_id}" \
    "TT_PREVIOUS_TASK_BRANCH=${previous_task_id}"

  _workspace__update_head "$workspace_dir" "$target_worktree"

  _hook__run "$repo" "post-checkout" false "$target_worktree" "${workspace_dir:-}" \
    "TT_TASK_ID=$task_id" \
    "TT_TASK_BRANCH=$task_id" \
    "TT_PREVIOUS_TASK_ID=${previous_task_id}" \
    "TT_PREVIOUS_TASK_BRANCH=${previous_task_id}"
}

# Usage: _worktree__ensure_working_copy REPO
#
# Guards the working-copy-position invariant that every branch write relies
# on: the current worktree's working-copy commit must not carry a bookmark.
# A tt transaction snapshots the working copy, which rewrites @; a bookmark
# sitting on @ follows that rewrite, so capturing the working copy would
# silently absorb unrelated uncommitted changes into the branch the bookmark
# names. Reattachment logic also degenerates when @ is itself a branch tip:
# there is no working-copy commit above the tip left to move. The refusal
# covers ANY bookmark, not just the branch being written — the absorption
# hazard is the same for all of them, and the working copy is expected to sit
# strictly above whatever bookmark it is based on.
#
# Resolves the current worktree via _repo__resolve_worktree_root (from CWD,
# falling back to REPO), then inspects the bookmarks at its @. Returns 0 when
# @ carries no bookmark; prints an error via _ui__log (naming the first
# bookmark when several are present) and returns 1 otherwise.
_worktree__ensure_working_copy() {
  local repo="$1"
  local worktree
  worktree="$(_repo__resolve_worktree_root "$repo")" || return 1
  local bookmarks
  bookmarks="$(_repo__list_bookmarks_at "$worktree" '@')" || return 1
  local name="${bookmarks%%$'\n'*}"
  [[ -z "$name" ]] && return 0
  _ui__log "Error: The working-copy commit is the tip of bookmark '$name'."
  _ui__log "  tt cannot write to a branch while the working copy carries a bookmark, because"
  _ui__log "  capturing the working copy would absorb unrelated changes into that branch."
  _ui__log "  Move off it first, by starting a new working-copy commit on top of it."
  return 1
}

# Usage: _worktree__ensure_worktree_current REPO WORKTREE
#
# Guards a worktree the caller is about to touch: returns 0 when WORKTREE is
# usable, and reports a refusal on stderr and returns 1 when it is stale or
# its state cannot be read. Both failures name WORKTREE, and the stale one
# names the command that recovers it along with what recovering costs.
#
# An unreadable worktree refuses rather than passing. A workspace whose state
# tt could not determine is not evidence of a healthy workspace, and the
# caller is about to load it.
#
# This guard has no exemptions: it is asked about a worktree the command will
# act on, which includes the case where that worktree is the invoking one.
_worktree__ensure_worktree_current() {
  local repo="$1" worktree="$2"
  local status=0
  _worktree__check_stale "$repo" "$worktree" || status=$?
  case "$status" in
    1)
      return 0
      ;;
    0)
      _worktree__report_stale "$worktree" \
        "Recover it first: tt worktree refresh $worktree --force"
      return 1
      ;;
    *)
      _worktree__report_indeterminate "$worktree"
      return 1
      ;;
  esac
}

# Usage: _worktree__ensure_canonical_current REPO
#
# Guards the precondition every branch write depends on: the CANONICAL
# workspace must not be stale. That workspace is where a failed command's
# rollback restores the repository from, and it is the one workspace
# guaranteed to exist even when the invoking worktree has just been deleted.
# A repository driven from task worktrees rarely has anyone standing in it, so
# it can sit stale unnoticed until a rollback needs it and cannot restore.
# Returns 0 when the write may proceed, 1 (having reported why) otherwise.
#
# Two cases are skipped, and both skips are load-bearing rather than
# optimizations:
#
#   Inside a transaction. A parent command's own writes can make the canonical
#   workspace stale partway through its run. A nested guard would then refuse
#   mid-transaction, and the rollback that refusal triggers is precisely the
#   one staleness breaks — turning a survivable situation into a locked
#   repository. The check belongs once, before anything has been written.
#
#   Canonical is the invoking worktree. A stale invoking worktree is left to
#   fail on its own terms: the transaction's begin-time snapshot refuses
#   immediately and rolls back cleanly, which is a better failure than this
#   one. The guard therefore runs only where it is load-bearing — a canonical
#   workspace nobody is standing in.
#
# The two paths are compared with -ef, as filesystem entries rather than as
# strings: the canonical resolver may return its argument unchanged while the
# worktree resolver canonicalizes symlinks, so a string comparison would treat
# two names for one directory as different workspaces.
_worktree__ensure_canonical_current() {
  local repo="$1"
  [[ -z "${TT_TRANSACTION_ID:-}" ]] || return 0
  local canonical worktree
  canonical="$(_worktree__resolve_repository_root "$repo")" || return 1
  worktree="$(_repo__resolve_worktree_root "$repo")" || return 1
  [[ "$canonical" -ef "$worktree" ]] && return 0
  _worktree__ensure_worktree_current "$repo" "$canonical"
}

# Usage: _worktree__reattach_current REPO BRANCH OLD_TIP NEW_REV
#
# After a write advances BRANCH from OLD_TIP to NEW_REV, moves the current
# worktree's working-copy commit onto NEW_REV — but only when the worktree is
# checked out ON BRANCH and its working-copy commit descends from OLD_TIP. Any
# other position is left alone (status 0): the write does not concern it.
#
# Descent from OLD_TIP alone cannot identify the worktree's branch. Every task
# branch forks from its parent's tip, and every commit on a merged-in branch
# descends from the receiving branch's old tip, so ancestry would also match
# a worktree on a child task or on the branch being merged in, and drag it
# onto BRANCH. The worktree's own branch is therefore read from its task
# symlink first (_worktree__resolve_branch_at). A worktree on BRANCH that does
# not descend from OLD_TIP was already behind before the write, and is left
# for `tt worktree sync` to bring forward.
#
# The working-copy commit is addressed by its change ID, which survives
# rebases, so the reattach targets the right commit even after the graph has
# been rewritten. The rebase runs inside the worktree, so the on-disk working
# copy is updated to the reattached commit in the same step.
_worktree__reattach_current() {
  local repo="$1" branch="$2" old_tip="$3" new_rev="$4"
  local worktree
  worktree="$(_repo__resolve_worktree_root "$repo")" || return 1
  local wc_change wc_commit
  wc_change="$(_repo__resolve_change "$worktree" '@')" || return 1
  wc_commit="$(_repo__resolve_commit "$worktree" '@')" || return 1
  local wc_branch
  wc_branch="$(_worktree__resolve_branch_at "$repo" "$wc_commit")" || return 0
  [[ "$wc_branch" == "$branch" ]] || return 0
  _repo__check_is_ancestor "$repo" "$old_tip" "$wc_change" || return 0
  _repo__reattach_worktree "$worktree" "$wc_change" "$new_rev"
}

# Usage: _worktree__move_subtree REPO SOURCE_REV DEST_REV
#
# Rebases SOURCE_REV together with every commit descended from it onto
# DEST_REV, running the rewrite from INSIDE the current worktree rather than
# as a bare graph mutation.
#
# The distinction matters only when the current working-copy commit is itself
# part of the moved subtree. A bare rewrite would move that commit in the
# graph while leaving the worktree's files on the pre-rewrite tree, which the
# backend then refuses to work with until the working copy is refreshed.
# Routing the rewrite through the worktree instead snapshots any pending
# on-disk edits first and updates the files onto the rewritten commit in the
# same step, so the working copy rides along with the subtree it belongs to.
# A working copy outside the moved subtree is left where it is (the snapshot
# still happens, but a snapshot only records pending edits in the
# working-copy commit — it never moves a branch onto them).
#
# Callers that know the working copy is outside the subtree should prefer the
# bare move (_repo__move_commits), which skips the snapshot entirely.
_worktree__move_subtree() {
  local repo="$1" source_rev="$2" dest_rev="$3"
  local worktree
  worktree="$(_repo__resolve_worktree_root "$repo")" || return 1
  _repo__reattach_worktree "$worktree" "$source_rev" "$dest_rev"
}

# Usage: _worktree__refresh_current REPO
#
# Brings the current worktree's on-disk files back into agreement with its
# working-copy commit after that commit was rewritten by a bare graph
# mutation. A bare rewrite deliberately leaves every working copy alone, which
# means the files on disk still match the pre-rewrite tree and the backend
# refuses any further command that loads the working copy until the mismatch
# is resolved. Call this once a bare rewrite that may have touched the current
# working-copy commit is complete, and before anything else needs the working
# copy again.
#
# Does not snapshot: pending on-disk edits are NOT captured, so callers that
# could be sitting on uncommitted work must record it (or refuse) beforehand.
# Harmless when the working copy was never disturbed. Returns non-zero when
# the current worktree cannot be resolved or the refresh fails.
_worktree__refresh_current() {
  local repo="$1"
  local worktree
  worktree="$(_repo__resolve_worktree_root "$repo")" || return 1
  _repo__refresh_worktree "$worktree"
}

# Usage: _worktree__refresh WORKTREE
#
# Brings WORKTREE's on-disk files back into agreement with its working-copy
# commit, recovering a worktree the backend is refusing to load. The named
# counterpart of _worktree__refresh_current, for the command that recovers a
# worktree other than the one it runs in — most often the canonical workspace,
# which is rarely the one the user is standing in.
#
# Does not snapshot, and cannot: the backend will not capture a stale working
# copy, so uncommitted work in WORKTREE is overwritten by the recovery. Callers
# must have said so before getting here. Harmless when WORKTREE is already
# current. Documented pass-through to _repo__refresh_worktree.
_worktree__refresh() {
  local worktree="$1"
  _repo__refresh_worktree "$worktree"
}

# Usage: _worktree__report_stale WORKTREE REMEDY
#
# Reports WORKTREE as stale on stderr, with REMEDY as the indented line naming
# the way out. Every refusal on staleness — the guards below and tt worktree
# refresh itself — reports through this, so the user meets one wording for one
# condition regardless of which check caught it, and the consequence of
# recovering is always stated. Always returns 0.
_worktree__report_stale() {
  local worktree="$1" remedy="$2"
  _ui__log "Error: The workspace is stale: $worktree"
  _ui__log "  $remedy"
  _ui__log "  Uncommitted changes in that workspace will be lost."
  return 0
}

# Usage: _worktree__report_indeterminate WORKTREE
#
# Reports on stderr that WORKTREE's state could not be read. The backend's own
# account of why reaches the user through TT_LOG. Always returns 0.
_worktree__report_indeterminate() {
  local worktree="$1"
  _ui__log "Error: Could not determine the state of the workspace: $worktree"
  return 0
}

# Usage: _worktree__list_holding_descendants REPO BASE_REV
#
# Prints one tab-separated "<worktree-path>\t<task-id>" record for every
# worktree OTHER than the current one whose working-copy commit is BASE_REV or
# a descendant of it — that is, every worktree parked inside the region a
# rewrite anchored at BASE_REV would rewrite.
#
# A command that rewrites history in place can carry its OWN worktree across
# the rewrite, but it cannot do the same for anybody else's: another worktree's
# uncommitted, un-snapshotted work only exists on that worktree's disk, and
# rewriting the commit underneath it would strand or destroy that work. Such a
# command therefore asks for this list first and refuses when it is non-empty,
# naming each blocking worktree so the user can resolve it deliberately.
#
# Reading each worktree's position never snapshots it, so a refusal leaves
# other worktrees exactly as they were. The task-id column is the branch the
# worktree sits on (branch names are task IDs in the tt model) and is empty
# when the worktree sits on no branch. Always returns 0.
_worktree__list_holding_descendants() {
  local repo="$1" base_rev="$2"
  local current_worktree
  current_worktree="$(_repo__resolve_worktree_root "$repo")" || current_worktree="$repo"
  local entries
  entries="$(_worktree__list_entries "$repo")" || return 0
  local ws_name ws_path wc_commit wt_branch
  while IFS=$'\t' read -r ws_name ws_path; do
    [[ -z "$ws_path" || ! -d "$ws_path" ]] && continue
    [[ "$ws_path" == "$current_worktree" ]] && continue
    wc_commit="$(_repo__resolve_commit "$ws_path" '@')" || continue
    [[ -n "$wc_commit" ]] || continue
    _repo__check_is_ancestor "$repo" "$base_rev" "$wc_commit" || continue
    wt_branch="$(_worktree__resolve_branch_at "$repo" "$wc_commit")" || wt_branch=''
    printf '%s\t%s\n' "$ws_path" "$wt_branch"
  done <<< "$entries"
  return 0
}


# Usage: _worktree__resolve_branch_at REPO REV
#
# Prints the name of the branch that REV — a worktree's working-copy commit —
# belongs to, by reading the task symlink REV records at the repository root.
# Returns 1 (nothing printed) when REV records no such symlink, or when the task
# it names has no branch.
#
# The branch is read rather than inferred. A worktree's working copy carries the
# symlink the branch's fork commit planted in it, naming the task directory of
# the task checked out there, and branch names *are* task IDs: the symlink is the
# repository's own record of the answer, written for exactly this purpose.
#
# The commit graph cannot answer the question. tt parks a working copy as an
# empty child of a branch tip, so the branch is whichever one owned that tip —
# and a branch advancing past a commit is shaped exactly like a branch forked
# from it: a bookmark ending a chain whose first-parent line runs through it.
# What separates the two is which bookmark pointed there at the time, which is
# history rather than shape. Any ranking of the bookmarks around a working copy
# is therefore guessing, and guesses wrongly as soon as a branch acquires
# several descendants — which propagation, check-in and task creation all do.
#
# Reading the symlink out of the commit rather than off disk keeps the answer
# the same whether or not the worktree has pending changes, and costs one
# backend read.
_worktree__resolve_branch_at() {
  local repo="$1" rev="$2"
  local target
  target="$(_repo__read_symlink_at_revision "$repo" "$rev" "$TT_TASK_SYMLINK_FILENAME")" || return 1
  [[ -n "$target" ]] || return 1

  # The target is the task file's canonical path: <task-root>/<suffix>/TASK.md.
  local suffix="${target%/*}"
  suffix="${suffix##*/}"
  [[ -n "$suffix" && "$target" == "$(_path__task_file "$suffix")" ]] || return 1

  local prefix
  for prefix in "$(_workspace__get_task_prefix "$repo")" \
                "$(_workspace__get_project_prefix "$repo")"; do
    [[ -n "$prefix" ]] || continue
    if _repo__check_bookmark_exists "$repo" "${prefix}${suffix}"; then
      printf '%s' "${prefix}${suffix}"
      return 0
    fi
  done
  return 1
}

# Usage: _worktree__resolve_branch REPO WORKTREE
#
# Prints the name of the branch WORKTREE is sitting on (see
# _worktree__resolve_branch_at). Returns 1 (nothing printed) when the worktree's
# position cannot be read or its working copy records no task.
_worktree__resolve_branch() {
  local repo="$1" worktree="$2"
  local wc_commit
  wc_commit="$(_repo__resolve_commit "$worktree" '@')" || return 1
  [[ -n "$wc_commit" ]] || return 1
  _worktree__resolve_branch_at "$repo" "$wc_commit"
}

# Usage: _worktree__check_behind REPO WORKTREE
#
# Returns 0 when WORKTREE is behind the head of the branch it sits on — that
# is, when the branch tip is not an ancestor of its working-copy commit, so
# there is something for a sync to move it onto. Returns non-zero when it is
# already current, and when its position or branch cannot be resolved (nothing
# is known to move it onto).
_worktree__check_behind() {
  local repo="$1" worktree="$2"
  local wc_commit branch
  wc_commit="$(_repo__resolve_commit "$worktree" '@')" || return 1
  [[ -n "$wc_commit" ]] || return 1
  branch="$(_worktree__resolve_branch_at "$repo" "$wc_commit")" || return 1
  [[ -n "$branch" ]] || return 1
  ! _repo__check_is_ancestor "$repo" "$branch" "$wc_commit"
}

# Usage: __worktree__list_behind REPO BRANCH SKIP_CURRENT
#
# Shared engine behind _worktree__list_unsynced and _worktree__list_all_unsynced,
# which differ only in how much of the repository they look at. Prints one
# tab-separated "<worktree-path>\t<task-id>" record per workspace in scope
# (__worktree__list_in_scope_entries) whose working-copy commit no longer has,
# as an ancestor, the tip of the branch the workspace sits on. The canonical
# repository is therefore considered only when the command runs from it.
#
# BRANCH restricts the result to workspaces sitting on that branch; passing an
# empty string considers every branch, each workspace judged against its own.
# SKIP_CURRENT is "true" to leave out the workspace the command is running in.
#
# Workspaces with no resolvable path, no directory on disk, no readable
# working-copy commit, or no branch at all are skipped: none of them is
# something a caller could report on or act on. Reading a worktree's position
# never snapshots it, so the walk leaves every worktree exactly as it was.
# Always returns 0.
__worktree__list_behind() {
  local repo="$1" branch="$2" skip_current="$3"
  local current_worktree=''
  if [[ "$skip_current" == true ]]; then
    current_worktree="$(_repo__resolve_worktree_root "$repo")" || current_worktree="$repo"
  fi
  local entries
  entries="$(__worktree__list_in_scope_entries "$repo")" || return 0
  local ws_name ws_path wc_commit wt_branch
  while IFS=$'\t' read -r ws_name ws_path; do
    [[ -z "$ws_path" || ! -d "$ws_path" ]] && continue
    [[ -n "$current_worktree" && "$ws_path" == "$current_worktree" ]] && continue
    wc_commit="$(_repo__resolve_commit "$ws_path" '@')" || continue
    [[ -n "$wc_commit" ]] || continue
    wt_branch="$(_worktree__resolve_branch_at "$repo" "$wc_commit")" || continue
    [[ -n "$branch" && "$wt_branch" != "$branch" ]] && continue
    _repo__check_is_ancestor "$repo" "$wt_branch" "$wc_commit" && continue
    printf '%s\t%s\n' "$ws_path" "$wt_branch"
  done <<< "$entries"
  return 0
}

# Usage: _worktree__list_unsynced REPO BRANCH
#
# Prints one tab-separated "<worktree-path>\t<task-id>" record for every
# worktree OTHER than the current one that is checked out on BRANCH but whose
# working-copy commit no longer has the branch tip as an ancestor — i.e. a
# write advanced BRANCH and left that worktree behind. The current worktree
# is excluded because callers reattach it directly
# (_worktree__reattach_current); the other worktrees stay untouched and are
# only reported, since rewriting a working copy nobody asked to touch would
# be surprising. The canonical repository is never reported: it is in scope
# only when it is the current workspace, which is excluded here. The task-id
# column is the branch the worktree sits on (branch names are task IDs in the
# tt model). Always returns 0.
#
# For a repository-wide answer covering every branch and the current worktree
# too, use _worktree__list_all_unsynced.
_worktree__list_unsynced() {
  local repo="$1" branch="$2"
  __worktree__list_behind "$repo" "$branch" true
}

# Usage: _worktree__list_all_unsynced REPO
#
# Prints one tab-separated "<worktree-path>\t<task-id>" record for every
# worktree in REPO that has fallen behind the head of its OWN branch — its
# working-copy commit no longer has that branch's tip as an ancestor.
#
# Drops both of _worktree__list_unsynced's restrictions, because it answers a
# different question. That function answers "which worktrees did this write to
# BRANCH leave behind?", so it looks at one branch and skips the current
# workspace (whose caller reattaches it directly). This answers "what in this
# repository is behind?": every workspace in scope is considered, the current
# one included, and each is judged against the branch it is itself checked out
# on. It is what a repository-wide sync iterates over, so the canonical
# repository is brought forward only by a sync run from it, and otherwise stays
# wherever the user left it. See __worktree__list_behind
# for which worktrees are skipped as unactionable. The task-id column is the
# branch the worktree sits on (branch names are task IDs in the tt model).
# Always returns 0.
_worktree__list_all_unsynced() {
  local repo="$1"
  __worktree__list_behind "$repo" '' false
}

# Usage: _worktree__report_unsynced REPO BRANCH
#
# When a write to BRANCH has left other worktrees behind
# (_worktree__list_unsynced), prints a warning block to stderr naming each of
# them and directing the user to `tt worktree sync`. The remedy is
# deliberately the tt command rather than a backend recipe: sync snapshots
# pending changes and reattaches in one step, which a hand-rolled backend
# invocation could easily get wrong. Prints nothing when every worktree is in
# sync. Always returns 0.
_worktree__report_unsynced() {
  local repo="$1" branch="$2"
  local records
  records="$(_worktree__list_unsynced "$repo" "$branch")"
  [[ -n "$records" ]] || return 0
  _ui__log "The following worktrees are now out of sync:"
  local ws_path task_id
  while IFS=$'\t' read -r ws_path task_id; do
    [[ -z "$ws_path" ]] && continue
    _ui__log "  $ws_path ($task_id)"
  done <<< "$records"
  _ui__log "Run 'tt worktree sync' in each of them to bring them up to date."
  return 0
}

# Usage: _worktree__sync REPO WORKTREE
#
# Brings WORKTREE forward onto the head of the branch it is checked out on,
# running inside WORKTREE itself. The worktree is snapshotted first so
# changes the VCS has not yet captured — including files it has never seen — ride
# along with the reattach instead of being lost. The branch is then resolved
# from the worktree's working-copy commit (_worktree__resolve_branch_at) and,
# unless the branch tip is already an ancestor of that commit, the commit is
# rebased onto the tip; because the rebase runs inside the worktree, its
# on-disk files are updated in the same step.
#
# Prints one machine-readable record on stdout for the caller to format:
#   synced\t<branch>\t<old-parent-commit>\t<new-tip-commit>
#   up-to-date\t<branch>
# Returns non-zero when the worktree is not on any branch (after logging an
# error) or when the snapshot or reattach fails.
_worktree__sync() {
  local repo="$1" worktree="$2"
  _repo__snapshot_worktree "$worktree" || return 1
  local wc_change wc_commit
  wc_change="$(_repo__resolve_change "$worktree" '@')" || return 1
  wc_commit="$(_repo__resolve_commit "$worktree" '@')" || return 1
  local branch
  branch="$(_worktree__resolve_branch_at "$repo" "$wc_commit")" || {
    _ui__log "Error: Worktree is not checked out on any branch: $worktree"
    return 1
  }
  if _repo__check_is_ancestor "$repo" "$branch" "$wc_commit"; then
    printf 'up-to-date\t%s\n' "$branch"
    return 0
  fi
  local old_parent new_tip
  old_parent="$(_repo__get_working_copy_parent "$worktree")" || return 1
  new_tip="$(_repo__resolve_commit "$repo" "$branch")" || return 1
  _repo__reattach_worktree "$worktree" "$wc_change" "$new_tip" || return 1
  printf 'synced\t%s\t%s\t%s\n' "$branch" "$old_parent" "$new_tip"
}

# Usage: _worktree__list_sync_changes REPO OLD_REV NEW_REV
#
# Prints one tab-separated "<status>\t<path>" record per file that a sync
# updates on disk when it moves a worktree from OLD_REV onto NEW_REV, sorted by
# path. <status> is one of "added", "modified" or "removed", named from the
# worktree's point of view: a file tracked at NEW_REV but not at OLD_REV was
# added, one tracked at OLD_REV but no longer at NEW_REV was removed, and one
# tracked at both ends was modified.
#
# The path set is the union of the paths each commit brought in between the two
# revisions (_repo__list_commits_in_range feeding _repo__list_changed_files), and
# the status of each is decided by looking that path up in the file listing at
# either end (_repo__list_files_at_revision). Both are line-oriented listings of
# repository-relative paths, matched whole-line, so a path containing spaces or
# shell metacharacters is handled exactly like any other — which a rendered
# diff, where the two sides of a header run together, could not promise. Each
# listing covers the whole repository, so both are loaded once and every path is
# classified in a single pass.
#
# The result is a summary of what the move touched rather than a minimal diff:
# a path a commit in the range changed and a later one changed back is still
# listed (as "modified"). Returns non-zero (nothing printed) when the range or
# either file listing cannot be read, so a caller that only wants to decorate
# its output can fall back to printing no summary. Prints nothing and returns 0
# when the range is empty.
_worktree__list_sync_changes() {
  local repo="$1" old_rev="$2" new_rev="$3"

  local commits
  commits="$(_repo__list_commits_in_range "$repo" "$old_rev" "$new_rev")" || return 1
  [[ -n "$commits" ]] || return 0

  local commit paths all_paths=''
  while IFS= read -r commit; do
    [[ -z "$commit" ]] && continue
    paths="$(_repo__list_changed_files "$repo" "$commit")" || continue
    [[ -z "$paths" ]] && continue
    all_paths="${all_paths}${paths}"$'\n'
  done <<< "$commits"
  [[ -n "$all_paths" ]] || return 0

  local old_files new_files
  old_files="$(_repo__list_files_at_revision "$repo" "$old_rev")" || return 1
  new_files="$(_repo__list_files_at_revision "$repo" "$new_rev")" || return 1

  awk '
    FILENAME == ARGV[1] { new_files[$0] = 1; next }
    FILENAME == ARGV[2] { old_files[$0] = 1; next }
    $0 == "" { next }
    {
      if (!($0 in new_files)) status = "removed"
      else if ($0 in old_files) status = "modified"
      else status = "added"
      printf "%s\t%s\n", status, $0
    }
  ' <(printf '%s\n' "$new_files") \
    <(printf '%s\n' "$old_files") \
    <(printf '%s' "$all_paths" | sort -u)
}
