# Worktree management for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _worktree__parse_list_line  — parse one `jj workspace list` line into name/path
#   _worktree__list_entries     — one "name<TAB>path" record per jj workspace
#   _worktree__list             — one "name<TAB>path<TAB>task_id" record per jj workspace
#   _worktree__resolve_name     — workspace name for a worktree path
#   _worktree__resolve_path     — recorded filesystem path for a workspace name
#   _worktree__resolve_current  — root of the worktree the command runs in
#   _worktree__resolve_repository_root — canonical primary workspace root
#   _worktree__check_clean      — whether a worktree has no uncommitted changes
#   _worktree__find_for_branch  — workspace roots whose current branch is a bookmark
#   _worktree__delete           — forget a workspace and remove its files from disk
#   _worktree__switch           — hooks + HEAD symlink update for a workspace switch
#   _worktree__ensure_working_copy — refuse branch writes while @ carries a bookmark
#   _worktree__reattach_current — follow a branch advance with the current worktree
#   _worktree__reattach_current_on_branch — follow a merge advance, own-branch worktree only
#   _worktree__move_subtree     — rewrite a subtree the current working copy may sit in
#   _worktree__refresh_current  — update the current worktree after a bare rewrite of @
#   _worktree__list_holding_descendants — other worktrees positioned inside a rewrite range
#   _worktree__list_unsynced    — worktrees left behind by a write to their branch
#   _worktree__report_unsynced  — stderr warning naming out-of-sync worktrees
#   _worktree__sync             — bring a worktree forward onto its branch head
#
# Functions named with a double underscore (__worktree__*) are internal helpers
# private to this module and not part of the public surface.

# Usage: _worktree__parse_list_line LINE
# Parses one line from `jj workspace list -T 'name ++ ": " ++ root ++ "\n"'`.
# Outputs two lines to stdout:
#   line 1: workspace name
#   line 2: absolute filesystem path, or empty string if the path is an error
#            (i.e. the workspace has no recorded or resolvable path)
# Lines with error paths look like: "name: <Error: Workspace has no recorded path: name>"
_worktree__parse_list_line() {
  local line="$1"
  local ws_name ws_path
  ws_name="$(printf '%s' "$line" | sed 's/: .*//')"
  ws_path="$(printf '%s' "$line" | sed 's/^[^:]*: //')"
  if [[ "$ws_path" == '<Error:'* ]]; then
    ws_path=''
  fi
  printf '%s\n%s\n' "$ws_name" "$ws_path"
}

# Usage: _worktree__list_entries REPO
# Prints one tab-separated "name<TAB>path" record per jj workspace in REPO.
# path is the empty string when the workspace has no resolvable path.
# Returns 1 if the workspace list cannot be read.
_worktree__list_entries() {
  local repo="$1"
  local ws_raw
  ws_raw="$(_repo__list_worktrees "$repo")" || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local parsed
    parsed="$(_worktree__parse_list_line "$line")"
    printf '%s\t%s\n' \
      "$(printf '%s' "$parsed" | sed -n '1p')" \
      "$(printf '%s' "$parsed" | sed -n '2p')"
  done <<< "$ws_raw"
}

# Usage: _worktree__list REPO TASK_PREFIX PROJECT_PREFIX
# Prints tab-separated workspace data, one line per workspace:
#   name\tpath\ttask_id
# path is empty string if unavailable; task_id is empty string if unresolved.
_worktree__list() {
  local repo="$1" task_prefix="$2" project_prefix="$3"
  local entries
  entries="$(_worktree__list_entries "$repo")" || return 0
  local ws_name ws_path task_id
  while IFS=$'\t' read -r ws_name ws_path; do
    [[ -z "$ws_name" ]] && continue

    task_id=''
    if [[ -n "$ws_path" && -d "$ws_path" ]]; then
      task_id="$(_task__resolve_current_branch "$ws_path" "$task_prefix" "$project_prefix" 2>/dev/null)" || true
    fi

    printf '%s\t%s\t%s\n' "$ws_name" "$ws_path" "$task_id"
  done <<< "$entries"
}

# Usage: _worktree__resolve_name REPO WORKTREE_PATH
# Prints the jj workspace name for the workspace at WORKTREE_PATH.
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
# Prints the recorded filesystem path of the jj workspace named WS_NAME.
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

# Usage: _worktree__find_for_branch REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX
# Outputs one workspace root path per line for each jj workspace whose
# working-copy commit sits on BOOKMARK. Classification uses the fork-point
# ranking of __worktree__resolve_branch rather than the nearest bookmarked
# ancestor, so a worktree that a branch write has left behind (its branch tip
# no longer in the working copy's ancestry) is still attributed to its own
# branch instead of to whichever ancestor bookmark remains reachable.
_worktree__find_for_branch() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  local entries
  entries="$(_worktree__list_entries "$repo")" || return 0
  local ws_root wc_commit ws_bookmark
  while IFS=$'\t' read -r _ ws_root; do
    [[ -z "$ws_root" || ! -d "$ws_root" ]] && continue
    wc_commit="$(_repo__resolve_commit "$ws_root" '@' 2>/dev/null)" || continue
    ws_bookmark="$(__worktree__resolve_branch "$repo" "$wc_commit" 2>/dev/null)" || continue
    [[ "$ws_bookmark" == "$bookmark" ]] && printf '%s\n' "$ws_root"
  done <<< "$entries"
  return 0
}

# Usage: _worktree__delete REPO WORKSPACE_NAME [WORKTREE_PATH]
# Forgets the jj workspace from the repository model.
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
  local name
  name="$(printf '%s\n' "$bookmarks" | sed -n '1p')"
  [[ -z "$name" ]] && return 0
  _ui__log "Error: The working-copy commit is the tip of bookmark '$name'."
  _ui__log "  tt cannot write to a branch while the working copy carries a bookmark, because"
  _ui__log "  capturing the working copy would absorb unrelated changes into that branch."
  _ui__log "  Move off it first:"
  _ui__log "    jj new"
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
# invoking worktree, so the worktree's own branch is resolved first by
# fork-point ranking (__worktree__resolve_branch) and anything not on BRANCH
# is left alone (status 0). The descent check from OLD_TIP is still applied
# after that, so a worktree already left behind on an older tip of BRANCH is
# reported by _worktree__report_unsynced rather than silently rewritten.
#
# MUST be called while BRANCH's bookmark still sits at OLD_TIP (i.e. before
# the caller advances it to NEW_REV): the fork-point ranking breaks ties in
# favor of a bookmark still sitting at its fork point, which is exactly what
# identifies a worktree checked out directly on BRANCH's tip.
_worktree__reattach_current_on_branch() {
  local repo="$1" branch="$2" old_tip="$3" new_rev="$4"
  local worktree
  worktree="$(_repo__resolve_worktree_root "$repo")" || return 1
  local wc_change wc_commit
  wc_change="$(_repo__resolve_change "$worktree" '@')" || return 1
  wc_commit="$(_repo__resolve_commit "$worktree" '@')" || return 1
  local wc_branch
  wc_branch="$(__worktree__resolve_branch "$repo" "$wc_commit")" || return 0
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
    wt_branch="$(__worktree__resolve_branch "$repo" "$wc_commit")" || wt_branch=''
    printf '%s\t%s\n' "$ws_path" "$wt_branch"
  done <<< "$entries"
  return 0
}

# Usage: __worktree__resolve_branch REPO WC_COMMIT
#
# Prints the name of the branch that the working-copy commit WC_COMMIT sits
# on. Internal helper for the sync machinery below.
#
# The naive resolution — the nearest bookmarked ancestor of the commit —
# breaks down for exactly the worktrees this machinery exists for: a bare
# write advances the branch bookmark past the worktree's position, so the
# bookmark leaves the working-copy commit's ancestry entirely and the nearest
# bookmarked ancestor degrades to some outer branch (e.g. main). Instead,
# every bookmark is ranked by where its history forks from the working-copy
# commit's history: the bookmark with the deepest fork point is the branch
# the worktree sits on, whether the bookmark still sits at that fork point
# (worktree in sync) or has moved past it (worktree behind). When two
# bookmarks share a fork point, one still sitting at it (a plain bookmarked
# ancestor) wins over one that has diverged from it.
#
# A bookmark whose fork point is WC_COMMIT itself is skipped: that means the
# working-copy commit is part of the bookmark's own ancestry rather than a
# working copy sitting on top of it. Returns 1 (nothing printed) when no
# bookmark qualifies.
__worktree__resolve_branch() {
  local repo="$1" wc_commit="$2"
  local best_name='' best_fork='' best_at_fork=''
  local name tip fork at_fork
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    tip="$(_repo__resolve_commit "$repo" "$name")" || continue
    fork="$(_repo__find_fork_point_commit "$repo" "$wc_commit" "$name")" || continue
    [[ -n "$fork" && "$fork" != "$wc_commit" ]] || continue
    if [[ "$tip" == "$fork" ]]; then at_fork=1; else at_fork=''; fi
    if [[ -z "$best_name" ]]; then
      best_name="$name" best_fork="$fork" best_at_fork="$at_fork"
    elif [[ "$fork" == "$best_fork" ]]; then
      if [[ -n "$at_fork" && -z "$best_at_fork" ]]; then
        best_name="$name" best_at_fork="$at_fork"
      fi
    elif _repo__check_is_ancestor "$repo" "$best_fork" "$fork"; then
      best_name="$name" best_fork="$fork" best_at_fork="$at_fork"
    fi
  done < <(_repo__list_bookmark_names "$repo")
  [[ -n "$best_name" ]] || return 1
  printf '%s' "$best_name"
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
_worktree__list_unsynced() {
  local repo="$1" branch="$2"
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
    wt_branch="$(__worktree__resolve_branch "$repo" "$wc_commit")" || continue
    [[ "$wt_branch" == "$branch" ]] || continue
    _repo__check_is_ancestor "$repo" "$branch" "$wc_commit" && continue
    printf '%s\t%s\n' "$ws_path" "$wt_branch"
  done <<< "$entries"
  return 0
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
# changes jj has not yet captured — including files it has never seen — ride
# along with the reattach instead of being lost. The branch is then resolved
# from the worktree's working-copy commit (__worktree__resolve_branch) and,
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
  branch="$(__worktree__resolve_branch "$repo" "$wc_commit")" || {
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
