# Common functions for tt bootstrap CLI scripts.
# Source this file; do not execute directly.

# ---------------------------------------------------------------------------
# Shared slug / ID / timestamp helpers (used by create, edit, add-context)
# ---------------------------------------------------------------------------

# Generate slug from title: replace non-alphanumeric with -, collapse consecutive, lowercase, trim.
title_to_slug() {
  local t="$1"
  printf '%s' "$t" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | tr -s '-' | sed 's/^-//;s/-$//'
}

# Validate slug: only lowercase alphanumeric and single hyphens; no leading/trailing hyphens.
# Returns 0 if valid, 1 and logs error if invalid.
validate_slug() {
  local s="$1"
  if [[ -z "$s" ]]; then
    log "Error: Slug cannot be empty"
    return 1
  fi
  if [[ "$s" =~ [A-Z] ]]; then
    log "Error: Slug must be lowercase: $s"
    return 1
  fi
  if [[ "$s" =~ ^- ]]; then
    log "Error: Slug cannot start with hyphen: $s"
    return 1
  fi
  if [[ "$s" =~ -$ ]]; then
    log "Error: Slug cannot end with hyphen: $s"
    return 1
  fi
  if [[ "$s" =~ -- ]]; then
    log "Error: Slug cannot contain consecutive hyphens: $s"
    return 1
  fi
  if [[ "$s" =~ [^a-z0-9-] ]]; then
    log "Error: Slug must contain only lowercase letters, digits, and hyphens: $s"
    return 1
  fi
  return 0
}

# Generate an 8-character random hex string for task/context IDs.
generate_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4
  elif [[ -r /dev/urandom ]]; then
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n' | head -c 8
  else
    log "Error: Need openssl or /dev/urandom to generate ID"
    exit 1
  fi
}

# Generate an ISO 8601 UTC timestamp (e.g. 2026-03-12T23:04:57Z).
generate_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ---------------------------------------------------------------------------
# Task/context file path helpers
# ---------------------------------------------------------------------------

# Usage: task_file_path SUFFIX
# Returns the canonical path to a task's TASK.md file.
# SUFFIX is the slug-hex part (e.g. "my-task-abc12345").
task_file_path() {
  local suffix="$1"
  printf '.tt/task/%s/TASK.md' "$suffix"
}

# Usage: task_dir_path SUFFIX
# Returns the canonical directory path for a task.
task_dir_path() {
  local suffix="$1"
  printf '.tt/task/%s' "$suffix"
}

# Usage: task_context_path SUFFIX CTX_ID
# Returns the canonical path to a context file.
# CTX_ID is "context/<ctx-slug>-<ctx-hex>" (without .md).
task_context_path() {
  local suffix="$1"
  local ctx_id="$2"
  printf '.tt/task/%s/%s.md' "$suffix" "$ctx_id"
}

# ---------------------------------------------------------------------------
# Body parsing helper
# ---------------------------------------------------------------------------

# Usage: parse_body CONTENT
# Outputs everything after the second "---" line (the frontmatter closing delimiter).
parse_body() {
  local content="$1"
  printf '%s' "$content" | awk '/^---$/{n++; if(n==2){found=1; next}} found{print}'
}

log() {
  printf '%s\n' "$*" >&2
}

# Find repo root by walking up from current directory to find .jj; return 1 if not found.
find_repo_root() {
  local dir
  dir="$(pwd)"
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

# Read task_prefix from .tt/config.toml; default "task/" if missing or unreadable.
get_task_prefix() {
  local repo="$1"
  local config="$repo/.tt/config.toml"
  local default_prefix='task/'
  if [[ -r "$config" ]]; then
    convfmt --from toml --to json < "$config" | jq -r '.task_prefix // "'"$default_prefix"'"'
  else
    printf '%s' "$default_prefix"
  fi
}

# Read project_prefix from .tt/config.toml; default "project/" if missing or unreadable.
get_project_prefix() {
  local repo="$1"
  local config="$repo/.tt/config.toml"
  local default_prefix='project/'
  if [[ -r "$config" ]]; then
    convfmt --from toml --to json < "$config" | jq -r '.project_prefix // "'"$default_prefix"'"'
  else
    printf '%s' "$default_prefix"
  fi
}

# Return true if bookmark name matches task ID pattern (<prefix><slug>-<hex>).
is_task_branch() {
  local bookmark="$1"
  local prefix="$2"
  [[ "$bookmark" == "$prefix"* ]] && [[ "$bookmark" =~ -[0-9a-fA-F]{8}$ ]]
}

# Read workspace_dir from .tt/config.toml; returns 1 if not configured.
get_workspace_dir() {
  local repo="$1"
  local config="$repo/.tt/config.toml"
  if [[ -r "$config" ]]; then
    local ws_dir
    ws_dir="$(convfmt --from toml --to json < "$config" | jq -r '.workspace_dir // ""')" || true
    if [[ -n "$ws_dir" ]]; then
      printf '%s' "$ws_dir"
      return 0
    fi
  fi
  return 1
}

# Return true if bookmark name matches project ID pattern (<prefix><slug>-<hex>).
is_project_branch() {
  local bookmark="$1"
  local prefix="$2"
  [[ "$bookmark" == "$prefix"* ]] && [[ "$bookmark" =~ -[0-9a-fA-F]{8}$ ]]
}

# Usage: is_wc_clean REPO_OR_WORKTREE
# Returns 0 if the working copy at REPO_OR_WORKTREE has no pending changes.
is_wc_clean() {
  local r="$1"
  local result
  result="$(jj -R "$r" log -r '@' --no-graph -T 'empty' 2>/dev/null)" || return 1
  [[ "$result" == "true" ]]
}

# Usage: run_hook REPO HOOK_NAME BLOCKING WORKTREE_DIR WORKSPACE_DIR [VAR=val ...]
# Runs .tt/hooks/<hook-name> with TT_WORKSPACE_DIR and TT_WORKTREE_DIR set,
# plus any additional VAR=val pairs. Blocking hooks abort on non-zero exit.
run_hook() {
  local repo="$1" hook_name="$2" blocking="$3" worktree_dir="$4" workspace_dir="$5"
  shift 5
  local hook_path="$repo/.tt/hooks/$hook_name"
  [[ ! -x "$hook_path" ]] && return 0
  local exit_code=0
  env TT_WORKSPACE_DIR="${workspace_dir:-}" TT_WORKTREE_DIR="$worktree_dir" "$@" "$hook_path" \
    || exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    if [[ "$blocking" == true ]]; then
      log "Error: Hook '$hook_name' failed (exit $exit_code); aborting."
      exit 1
    else
      log "Warning: Hook '$hook_name' failed (exit $exit_code; non-blocking)."
    fi
  fi
}

# Usage: update_head_symlink WORKSPACE_DIR TARGET_PATH
# Updates <workspace-dir>/HEAD to point at TARGET_PATH (relative if possible).
update_head_symlink() {
  local workspace_dir="$1" target_path="$2"
  [[ -z "$workspace_dir" ]] && return 0
  [[ ! -d "$workspace_dir" ]] && return 0
  local head_path="$workspace_dir/HEAD"
  local rel_target
  if [[ "$target_path" == "$workspace_dir"/* ]]; then
    rel_target="./${target_path#"$workspace_dir"/}"
  else
    rel_target="$target_path"
  fi
  ln -snf "$rel_target" "$head_path"
  log "Updated HEAD -> $rel_target"
}

# Usage: perform_workspace_switch REPO WORKSPACE_DIR TASK_ID TARGET_WORKTREE OUTGOING_WORKTREE PREVIOUS_TASK_ID
# Fires pre-checkout hook, updates HEAD symlink, fires post-checkout hook.
perform_workspace_switch() {
  local repo="$1" workspace_dir="$2" task_id="$3"
  local target_worktree="$4" outgoing_worktree="$5" previous_task_id="$6"

  log "Switching to $task_id"

  run_hook "$repo" "pre-checkout" true "$outgoing_worktree" "${workspace_dir:-}" \
    "TT_TASK_ID=$task_id" \
    "TT_TASK_BRANCH=$task_id" \
    "TT_PREVIOUS_TASK_ID=${previous_task_id}" \
    "TT_PREVIOUS_TASK_BRANCH=${previous_task_id}"

  update_head_symlink "$workspace_dir" "$target_worktree"

  run_hook "$repo" "post-checkout" false "$target_worktree" "${workspace_dir:-}" \
    "TT_TASK_ID=$task_id" \
    "TT_TASK_BRANCH=$task_id" \
    "TT_PREVIOUS_TASK_ID=${previous_task_id}" \
    "TT_PREVIOUS_TASK_BRANCH=${previous_task_id}"
}

# Usage: parse_frontmatter_field CONTENT FIELD
# Extracts the value of a YAML frontmatter field from multi-line content.
parse_frontmatter_field() {
  local content="$1" field="$2"
  printf '%s' "$content" | awk -v field="$field" '
    /^---$/ { n++; next }
    n == 1 && $0 ~ ("^" field ":") {
      sub("^" field ":[[:space:]]*", "")
      gsub(/^"|"$/, "")
      print; exit
    }
  '
}

# Usage: raw=$(prompt_raw <<< "$template")
# Reads template from stdin, opens editor, returns raw file content (no stripping).
# Exits non-zero if editor exits non-zero.
prompt_raw() {
  local editor
  # Note: we use `vim` rather than `vi` because to ensure POSIX compliance, when it is invoked as `vi`,
  # vim exits with a non-zero status when an error is encountered at any point during the editing session
  # see https://stackoverflow.com/q/46665403
  DEFAULT_EDITOR="vim"
  editor="${TT_EDITOR:-${GIT_EDITOR:-${VISUAL:-${EDITOR:-$DEFAULT_EDITOR}}}}"
  local tmpfile
  tmpfile="$(mktemp -t TT_EDITMSG)"
  trap 'rm -f "$tmpfile"' RETURN
  cat > "$tmpfile"
  "$editor" "$tmpfile" </dev/tty >/dev/tty || {
    log "Error: Editor exited with non-zero status.";
    cat "$tmpfile" >&2
    return 1;
  }
  cat "$tmpfile"
}

# Usage: message=$(prompt <<< "$template")
# Reads template from stdin, opens editor, strips #-comment lines and trims whitespace,
# prints cleaned text to stdout (empty string if blank after stripping).
# Exits non-zero if editor exits non-zero.
prompt() {
  local raw
  raw="$(prompt_raw)" || return 1
  local msg
  msg="$(printf '%s' "$raw" | sed '/^#/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # trim leading/trailing blank lines
  msg="$(printf '%s' "$msg" | awk 'NF{found=1} found{print}' | sed -e 's/[[:space:]]*$//')"
  printf '%s' "$msg"
}

# Usage: has_conflicts REPO_OR_WORKTREE REVSET
# Returns 0 (true) if any commit in REVSET has conflicts.
has_conflicts() {
  local repo="$1" revset="$2"
  local result
  result="$(jj -R "$repo" log -r "$revset" \
    --no-graph -T 'if(conflict, "yes\n")' 2>/dev/null)" || true
  [[ -n "$result" ]]
}

# Usage: find_parent_branch REPO TASK_ID TASK_PREFIX PROJECT_PREFIX
# Scans all task/project bookmarks for one whose owner task file lists TASK_ID
# in a subtask: entry (any checkbox state). Outputs the parent bookmark name.
# Exit 0: parent found (printed to stdout).
# Exit 1: no parent found (task is parentless; nothing printed).
# Exit 2: multiple parents found (error printed to stderr).
find_parent_branch() {
  local repo="$1" task_id="$2" task_prefix="$3" project_prefix="$4"
  local jj_opts=(-R "$repo")

  local all_bookmarks
  all_bookmarks="$(jj "${jj_opts[@]}" --ignore-working-copy log -r 'bookmarks()' \
    -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' --no-graph 2>/dev/null)" || true

  local found=''
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    is_task_branch "$branch" "$task_prefix" || is_project_branch "$branch" "$project_prefix" || continue
    [[ "$branch" == "$task_id" ]] && continue
    local suffix
    if is_task_branch "$branch" "$task_prefix"; then
      suffix="${branch#$task_prefix}"
    else
      suffix="${branch#$project_prefix}"
    fi
    local path
    path="$(task_file_path "$suffix")"
    local content
    content="$(jj "${jj_opts[@]}" --ignore-working-copy file show -r "$branch" -- "$path" 2>/dev/null)" || continue
    if printf '%s' "$content" | grep -qE "^subtask:[[:space:]]*\[[[:space:]x\-]\][[:space:]]+${task_id}([[:space:]]|$)"; then
      if [[ -n "$found" ]]; then
        log "Error: Multiple parent branches found for '$task_id': '$found' and '$branch'."
        return 2
      fi
      found="$branch"
    fi
  done <<< "$all_bookmarks"

  [[ -z "$found" ]] && return 1
  printf '%s' "$found"
}

# Usage: find_parent_project REPO TASK_ID TASK_PREFIX PROJECT_PREFIX
# Walks up the task hierarchy from TASK_ID to find the nearest ancestor project branch.
# Outputs the project branch name to stdout.
# Exit 0: project found (printed to stdout).
# Exit 1: no ancestor project found.
# Exit 2: multiple parents found at some level (error printed to stderr by find_parent_branch).
find_parent_project() {
  local repo="$1" task_id="$2" task_prefix="$3" project_prefix="$4"
  local cursor="$task_id"
  while true; do
    local parent='' exit_code=0
    parent="$(find_parent_branch "$repo" "$cursor" "$task_prefix" "$project_prefix")" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      return $exit_code
    fi
    if is_project_branch "$parent" "$project_prefix"; then
      printf '%s' "$parent"
      return 0
    fi
    cursor="$parent"
  done
}

# Usage: find_branch_for_task REPO TASK_ID TASK_PREFIX PROJECT_PREFIX
# Locates the canonical branch for TASK_ID using the "where to read" rule:
# scans all task/project bookmarks for one whose owner task file contains
# "subtask: [x] <task-id>" (merged); if found, outputs that parent branch.
# Otherwise checks if TASK_ID itself is a valid branch (ongoing) and outputs it.
# Exits 1 if neither is found.
find_branch_for_task() {
  local repo="$1" task_id="$2" task_prefix="$3" project_prefix="$4"
  local all_bookmarks
  all_bookmarks="$(jj -R "$repo" --ignore-working-copy log -r 'bookmarks()' \
    -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' --no-graph 2>/dev/null)" || true

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    is_task_branch "$branch" "$task_prefix" || is_project_branch "$branch" "$project_prefix" || continue
    local suffix
    if is_task_branch "$branch" "$task_prefix"; then
      suffix="${branch#$task_prefix}"
    else
      suffix="${branch#$project_prefix}"
    fi
    local path
    path="$(task_file_path "$suffix")"
    local c
    c="$(jj -R "$repo" --ignore-working-copy file show -r "$branch" -- "$path" 2>/dev/null)" || continue
    if printf '%s' "$c" | grep -qE "^subtask:[[:space:]]*\[x\][[:space:]]+${task_id}([[:space:]]|$)"; then
      printf '%s' "$branch"
      return 0
    fi
  done <<< "$all_bookmarks"

  # Not merged — use task's own branch
  if jj -R "$repo" --ignore-working-copy log -r "$task_id" --no-graph -T '' 2>/dev/null; then
    printf '%s' "$task_id"
    return 0
  fi

  return 1
}

# Usage: get_worktree_current_rev WORKTREE
# Prints the commit_id of @ in the given worktree. Exits 1 on failure.
get_worktree_current_rev() {
  local worktree="$1"
  jj -R "$worktree" log -r '@' --no-graph -T 'commit_id' 2>/dev/null
}

# Usage: resolve_current_worktree REPO
# Prints the current workspace root; falls back to REPO if not in a workspace.
resolve_current_worktree() {
  local repo="$1"
  jj -R "$repo" workspace root 2>/dev/null || printf '%s' "$repo"
}

# Usage: resolve_task_worktree REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX CURRENT_WORKTREE [WORKTREE_ARG]
#
# Resolves which worktree to operate on for BOOKMARK:
#   0 matches → use CURRENT_WORKTREE (fallback)
#   1 match   → use that worktree
#   multiple  → if CURRENT_WORKTREE is one of them, use it;
#               else if WORKTREE_ARG is given, use it;
#               else error and list candidates
#
# Prints the resolved worktree path to stdout. Exits 1 on unresolvable ambiguity.
resolve_task_worktree() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  local current_worktree="$5" worktree_arg="${6:-}"

  local found wt_count
  found="$(find_worktrees_for_branch "$repo" "$bookmark" "$task_prefix" "$project_prefix")"
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
      log "Error: Multiple workspaces found for '$bookmark'; use --worktree=<path>:"
      printf '%s\n' "$found" | while IFS= read -r p; do log "  $p"; done
      return 1
      ;;
  esac
}

# Usage: find_worktrees_for_branch REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX
# Outputs one workspace root path per line for each jj workspace where
# BOOKMARK is the current branch (resolved via resolve_current).
find_worktrees_for_branch() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  # Get all workspace names + root paths
  local ws_list
  ws_list="$(jj -R "$repo" --ignore-working-copy workspace list --no-pager 2>/dev/null)" || return 0
  while IFS= read -r ws_line; do
    [[ -z "$ws_line" ]] && continue
    # Format: "name: /path/to/root (@ rev)"
    local ws_name ws_root
    ws_name="$(printf '%s' "$ws_line" | awk '{print $1}' | tr -d ':')"
    ws_root="$(printf '%s' "$ws_line" | awk '{print $2}')"
    [[ -z "$ws_root" ]] && continue
    [[ ! -d "$ws_root" ]] && continue
    # Resolve current bookmark in this workspace
    local resolve_out
    resolve_out="$(resolve_current "$ws_root" "$task_prefix" "$project_prefix" 2>/dev/null)" || continue
    local ws_bookmark
    ws_bookmark="$(printf '%s' "$resolve_out" | sed -n '3p')"
    if [[ "$ws_bookmark" == "$bookmark" ]]; then
      printf '%s\n' "$ws_root"
    fi
  done <<< "$ws_list"
}

# Usage: resolve_current REPO TASK_PREFIX PROJECT_PREFIX
#
# Resolve the "current branch" (closest ancestor of the working copy @ that has a bookmark).
# Uses heads() so that when @ is a working-copy commit (direct descendant of a task), we get
# the task bookmark, not a more distant ancestor like main.
# Outputs three lines to stdout:
#   line 1: rev       — commit ID at the current branch, or '@' if no bookmarks in ancestry
#   line 2: task_file — path to .tt/task/<slug>-<hex>.md, or empty if current branch is a root
#   line 3: bookmark  — bookmark name, or empty if current branch is a root
#
# Exits 1 if the current branch cannot be resolved.
resolve_current() {
  local repo="$1"
  local task_prefix="$2"
  local project_prefix="$3"
  local jj_opts=(-R "$repo")
  local current_branch

  current_branch="$(jj "${jj_opts[@]}" --ignore-working-copy log -r 'heads(ancestors(@) & bookmarks())' -n 1 --no-graph -T 'local_bookmarks.map(|b| b.name()).join(",")' 2>/dev/null)" || true
  current_branch="${current_branch%%,*}"  # Take first if comma-separated

  if [[ -z "$current_branch" ]]; then
    printf '%s\n\n\n' '@'
  else
    local parent_rev
    if ! parent_rev="$(jj "${jj_opts[@]}" --ignore-working-copy log -r "$current_branch" -n 1 --no-graph -T 'commit_id' 2>/dev/null)"; then
      log "Error: Could not resolve current branch: $current_branch"
      exit 1
    fi
    if is_task_branch "$current_branch" "$task_prefix"; then
      printf '%s\n%s\n%s\n' "$parent_rev" "$(task_file_path "${current_branch#$task_prefix}")" "$current_branch"
    elif is_project_branch "$current_branch" "$project_prefix"; then
      printf '%s\n%s\n%s\n' "$parent_rev" "$(task_file_path "${current_branch#$project_prefix}")" "$current_branch"
    else
      printf '%s\n\n\n' "$parent_rev"
    fi
  fi
}

# Map a task status field to a GFM checkbox string.
# TODO -> [ ], IN-PROGRESS -> [-], DONE/Done -> [x], else [ ]
status_to_checkbox() {
  local s="$1"
  case "$s" in
    TODO)        printf '[ ]' ;;
    IN-PROGRESS) printf '[-]' ;;
    DONE|Done)   printf '[x]' ;;
    *)           printf '[?]' ;;
  esac
}
