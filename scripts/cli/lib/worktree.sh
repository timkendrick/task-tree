# Worktree management for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _worktree__parse_list_line  — parse one `jj workspace list` line into name/path
#   _worktree__list_entries     — one "name<TAB>path" record per jj workspace
#   _worktree__list             — one "name<TAB>path<TAB>task_id" record per jj workspace
#   _worktree__resolve_name     — workspace name for a worktree path
#   _worktree__resolve_path     — recorded filesystem path for a workspace name
#   _worktree__find_for_branch  — workspace roots whose current branch is a bookmark
#   _worktree__resolve_for_task — pick the worktree to operate on for a bookmark
#   _worktree__delete           — forget a workspace and remove its files from disk
#   _worktree__switch           — hooks + HEAD symlink update for a workspace switch

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
      task_id="$(resolve_current_bookmark "$ws_path" "$task_prefix" "$project_prefix" 2>/dev/null)" || true
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

# Usage: _worktree__find_for_branch REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX
# Outputs one workspace root path per line for each jj workspace where
# BOOKMARK is the current branch (resolved via resolve_current).
_worktree__find_for_branch() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  local entries
  entries="$(_worktree__list_entries "$repo")" || return 0
  local ws_root ws_bookmark
  while IFS=$'\t' read -r _ ws_root; do
    [[ -z "$ws_root" || ! -d "$ws_root" ]] && continue
    ws_bookmark="$(resolve_current_bookmark "$ws_root" "$task_prefix" "$project_prefix" 2>/dev/null)" || continue
    [[ "$ws_bookmark" == "$bookmark" ]] && printf '%s\n' "$ws_root"
  done <<< "$entries"
  return 0
}

# Usage: _worktree__resolve_for_task REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX CURRENT_WORKTREE [WORKTREE_ARG]
#
# Resolves which worktree to operate on for BOOKMARK:
#   0 matches → use CURRENT_WORKTREE (fallback)
#   1 match   → use that worktree
#   multiple  → if CURRENT_WORKTREE is one of them, use it;
#               else if WORKTREE_ARG is given, use it;
#               else error and list candidates
#
# Prints the resolved worktree path to stdout. Exits 1 on unresolvable ambiguity.
_worktree__resolve_for_task() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  local current_worktree="$5" worktree_arg="${6:-}"

  local found wt_count
  found="$(_worktree__find_for_branch "$repo" "$bookmark" "$task_prefix" "$project_prefix")"
  wt_count="$(printf '%s' "$found" | grep -c . 2>/dev/null || true)"

  case "$wt_count" in
    0) printf '%s' "$current_worktree" ;;
    1) printf '%s' "$found" ;;
    *)
      if printf '%s\n' "$found" | grep -qxF "$current_worktree"; then
        printf '%s' "$current_worktree"
        return 0
      fi
      if [[ -n "$worktree_arg" ]]; then
        printf '%s' "$worktree_arg"
        return 0
      fi
      _ui__log "Error: Multiple workspaces found for '$bookmark'; use --worktree=<path>:"
      printf '%s\n' "$found" | while IFS= read -r p; do _ui__log "  $p"; done
      return 1
      ;;
  esac
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
