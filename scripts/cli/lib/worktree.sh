# Worktree management for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _worktree__parse_list_line  — parse one backend worktree-listing line into name/path
#   _worktree__list_entries     — one "name<TAB>path" record per worktree
#   _worktree__list             — one "name<TAB>path<TAB>task_id" record per worktree
#   _worktree__resolve_name     — workspace name for a worktree path
#   _worktree__resolve_path     — recorded filesystem path for a workspace name
#   _worktree__resolve_current  — root of the worktree the command runs in
#   _worktree__find_current     — root of the worktree containing the CWD, or none
#   _worktree__resolve_repository_root — canonical primary workspace root
#   _worktree__resolve_repository_path — canonical primary workspace root, symlink-resolved
#   _worktree__check_clean      — whether a worktree has no uncommitted changes
#   _worktree__check_stale      — whether a worktree's files match the commit it records
#   _worktree__check_exists     — whether a worktree already lives at a path
#   _worktree__create           — add a workspace at a path, started on a revision
#   _worktree__start_working_copy — move a worktree onto a new commit on a revision
#   _worktree__commit_working_copy — record a worktree's working copy as a commit
#   _worktree__resolve_working_copy_parent — commit a worktree's working copy sits on
#   _worktree__squash_into_working_copy — fold commits into a worktree's working copy
#   _worktree__record_working_copy — capture uncommitted work and name the operation holding it
#   _worktree__find_for_branch  — workspace roots whose current branch is a bookmark
#   _worktree__delete           — forget a workspace and remove its files from disk
#   _worktree__switch           — hooks + HEAD symlink update for a workspace switch
#   _worktree__ensure_working_copy — refuse branch writes while @ carries a bookmark
#   _worktree__reattach_current — follow a branch advance with the current worktree
#   _worktree__reattach_current_on_branch — follow a merge advance, own-branch worktree only
#   _worktree__move_subtree     — rewrite a subtree the current working copy may sit in
#   _worktree__refresh_current  — update the current worktree after a bare rewrite of @
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
# Prints one tab-separated "name<TAB>path" record per worktree in REPO.
# path is the empty string when the workspace has no resolvable path.
# Returns 1 if the workspace list cannot be read.
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

# Usage: _worktree__list REPO
# Prints tab-separated workspace data, one line per workspace:
#   name\tpath\ttask_id
# path is empty string if unavailable; task_id is empty string if the worktree
# holds no task — each worktree's task is the one its own working copy records
# (_worktree__resolve_branch), so a worktree a branch write has left behind is
# still named by the task it has checked out.
_worktree__list() {
  local repo="$1"
  local entries
  entries="$(_worktree__list_entries "$repo")" || return 0
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
# Prints the canonical repository root — the primary workspace — for REPO,
# which may itself be a secondary worktree. Documented pass-through to
# _repo__resolve_repository_root so commands can name the primary workspace
# (e.g. as a fallback when a branch is not checked out anywhere) without
# reaching into the VCS layer. Canonicalize the result with
# _path__resolve_symlinks before comparing it against other resolved paths.
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

# Usage: _worktree__find_for_branch REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX
# Outputs one worktree root path per line for each worktree whose working-copy
# commit records BOOKMARK as its checked-out task
# (_worktree__resolve_branch_at), so a worktree a branch write has left behind
# is still attributed to the branch it is on.
#
# More than one worktree can legitimately sit on a branch — a task checked out
# in a worktree of its own is also, for as long as nothing else is checked out
# there, under whatever workspace was parked above its tip. The result is
# therefore ordered by how well each worktree answers "where is this task
# checked out", so that a caller wanting one of them takes the first line:
#
#   1. the task's own dedicated worktree, whose workspace is named for the
#      branch (that is the name `tt task checkout --worktree` gives it);
#   2. any other dedicated worktree sitting on the branch;
#   3. the primary workspace — the canonical repository itself — last, since a
#      task is checked out there by default rather than by choice.
#
# Worktrees keep the order of the workspace listing within each group.
_worktree__find_for_branch() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  local entries
  entries="$(_worktree__list_entries "$repo")" || return 0
  local primary_path
  primary_path="$(_worktree__resolve_repository_path "$repo")" || primary_path=''
  local ws_name ws_root ws_path wc_commit ws_bookmark
  local named='' other='' primary=''
  while IFS=$'\t' read -r ws_name ws_root; do
    [[ -z "$ws_root" || ! -d "$ws_root" ]] && continue
    wc_commit="$(_repo__resolve_commit "$ws_root" '@' 2>/dev/null)" || continue
    ws_bookmark="$(_worktree__resolve_branch_at "$repo" "$wc_commit" 2>/dev/null)" || continue
    [[ "$ws_bookmark" == "$bookmark" ]] || continue
    ws_path="$(_path__resolve_symlinks "$ws_root" 2>/dev/null)" || ws_path="$ws_root"
    if [[ "$ws_name" == "$bookmark" ]]; then
      named="${named}${ws_root}"$'\n'
    elif [[ -n "$primary_path" && "$ws_path" == "$primary_path" ]]; then
      primary="${primary}${ws_root}"$'\n'
    else
      other="${other}${ws_root}"$'\n'
    fi
  done <<< "$entries"
  printf '%s' "${named}${other}${primary}"
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

# Usage: _worktree__reattach_current REPO OLD_TIP NEW_REV
#
# After a write advances a branch from OLD_TIP to NEW_REV, moves the current
# worktree's working-copy commit onto NEW_REV — but only when that commit
# descended from OLD_TIP, i.e. the current worktree was checked out on the
# line that moved. Any other position is left alone (status 0): the worktree
# sits elsewhere and the write does not concern it.
#
# The working-copy commit is addressed by its change ID, which survives
# rebases, so the reattach targets the right commit even after the graph has
# been rewritten. The rebase runs inside the worktree, so the on-disk working
# copy is updated to the reattached commit in the same step.
_worktree__reattach_current() {
  local repo="$1" old_tip="$2" new_rev="$3"
  local worktree
  worktree="$(_repo__resolve_worktree_root "$repo")" || return 1
  local wc_change
  wc_change="$(_repo__resolve_change "$worktree" '@')" || return 1
  _repo__check_is_ancestor "$repo" "$old_tip" "$wc_change" || return 0
  _repo__reattach_worktree "$worktree" "$wc_change" "$new_rev"
}

# Usage: _worktree__reattach_current_on_branch REPO BRANCH OLD_TIP NEW_REV
#
# Variant of _worktree__reattach_current for advances that land a MERGE on
# BRANCH (check-in and publish): moves the current worktree's working-copy
# commit onto NEW_REV only when the worktree actually sits ON BRANCH.
#
# Plain descent from OLD_TIP — the _worktree__reattach_current condition — is
# the wrong test here: every commit on the merged-in source branch also
# descends from the receiving branch's old tip (the source forked from it),
# so ancestry alone would drag a worktree checked out on the source branch —
# typically the very worktree the command is invoked from — onto the merge
# commit. A check-in must affect the target branch, never relocate the
# invoking worktree, so the worktree's own branch is resolved first
# (_worktree__resolve_branch_at) and anything not on BRANCH is left alone
# (status 0). The descent check from OLD_TIP is still applied after that, so a
# worktree already left behind on an older tip of BRANCH is reported by
# _worktree__report_unsynced rather than silently rewritten.
_worktree__reattach_current_on_branch() {
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
# symlink `tt task checkout` planted in it, naming the task directory of the
# task checked out there, and branch names *are* task IDs: the symlink is the
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
# tab-separated "<worktree-path>\t<task-id>" record per worktree whose
# working-copy commit no longer has, as an ancestor, the tip of the branch the
# worktree sits on.
#
# BRANCH restricts the result to worktrees sitting on that branch; passing an
# empty string considers every branch, each worktree judged against its own.
# SKIP_CURRENT is "true" to leave out the worktree the command is running in.
#
# Worktrees with no resolvable path, no directory on disk, no readable
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
  entries="$(_worktree__list_entries "$repo")" || return 0
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
# be surprising. The task-id column is the branch the worktree sits on
# (branch names are task IDs in the tt model). Always returns 0.
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
# worktree (whose caller reattaches it directly). This answers "what in this
# repository is behind?": every worktree is considered, the current one
# included, and each is judged against the branch it is itself checked out on.
# It is what a repository-wide sync iterates over. See __worktree__list_behind
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
# the status of each is decided by testing that path against the file listing
# at either end (_repo__list_files_at_revision). Both are line-oriented listings
# of repository-relative paths, matched whole-line, so a path containing spaces
# or shell metacharacters is handled exactly like any other — which a rendered
# diff, where the two sides of a header run together, could not promise.
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

  local path status
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if printf '%s\n' "$new_files" | grep -qFx -e "$path"; then
      if printf '%s\n' "$old_files" | grep -qFx -e "$path"; then
        status='modified'
      else
        status='added'
      fi
    else
      status='removed'
    fi
    printf '%s\t%s\n' "$status" "$path"
  done <<< "$(printf '%s' "$all_paths" | sort -u)"
  return 0
}
