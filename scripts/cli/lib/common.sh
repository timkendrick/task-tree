# Common functions for tt bootstrap CLI scripts.
# Source this file; do not execute directly.

# ---------------------------------------------------------------------------
# VCS file-read helpers
# ---------------------------------------------------------------------------

# Usage: jj_show_at_revision REPO REV PATH
# Reads a file at a named revision from a jj repo using a root:-relative path.
# Always passes --ignore-working-copy since these calls never read from @.
# Outputs file content to stdout. Returns jj's exit code (non-zero = file absent).
jj_show_at_revision() {
  local repo="$1" rev="$2" path="$3"
  jj -R "$repo" --ignore-working-copy file show -r "$rev" -- "root:$path" 2>/dev/null
}

# Usage: get_jj_op_id REPO
# Prints the current jj operation ID to stdout.
# Returns 1 if the operation ID cannot be read.
get_jj_op_id() {
  local repo="$1"
  jj -R "$repo" op log --no-graph -T id -n 1 2>/dev/null
}

# Usage: jj_show_at_op REPO OP REV PATH
# Reads a file at a specific jj operation ID and revision, using a root:-relative path.
# Used for historical rescue (e.g. recovering pre-rename file content).
# Outputs file content to stdout. Returns jj's exit code (non-zero = file absent).
jj_show_at_op() {
  local repo="$1" op="$2" rev="$3" path="$4"
  jj -R "$repo" --at-operation "$op" file show -r "$rev" -- "root:$path" 2>/dev/null
}

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
# Uses pwd -P to resolve symlinks so that working from inside a symlinked directory
# (e.g. /virtual/HEAD) does not produce a symlink path as the repo root.
find_repo_root() {
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

# Usage: repo=$(resolve_repo "$repo_flag_value")
#
# Resolves the repository root using the following priority order:
#   1. $repo_flag_value — the value passed to --repo (if non-empty)
#   2. $TT_REPO        — the TT_REPO environment variable (if set and non-empty)
#   3. find_repo_root  — walk up from CWD to find a .jj directory
#
# Prints the resolved repo path to stdout.
# Exits 1 with an error message if the path cannot be resolved or is not a jj repo.
resolve_repo() {
  local repo="${1:-}"

  # Priority 1: explicit --repo flag (already in $repo if set)
  if [[ -z "$repo" ]]; then
    # Priority 2: TT_REPO environment variable
    if [[ -n "${TT_REPO:-}" ]]; then
      repo="$TT_REPO"
    else
      # Priority 3: walk up from CWD
      if ! repo="$(find_repo_root)"; then
        log "Error: No enclosing jj repository. Use --repo or set TT_REPO."
        exit 1
      fi
    fi
  fi

  if [[ ! -d "$repo/.jj" ]]; then
    log "Error: Not a jj repository: $repo"
    exit 1
  fi

  # Canonicalize to match jj's own path representation (e.g. /var → /private/var on macOS)
  repo="$(cd "$repo" && pwd -P)"
  printf '%s' "$repo"
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

# Usage: set_workspace_dir REPO VIRTUAL_DIR
# Creates or replaces the <repo>/.tt/workspace symlink pointing at VIRTUAL_DIR.
# Always uses an absolute target path; the absolute-path guarantee is an
# implementation detail enforced here so callers never need to think about it.
set_workspace_dir() {
  local repo="$1" virtual_dir="$2"
  make_absolute_symlink "$virtual_dir" "$repo/.tt/workspace"
}

# Usage: init_tt_history REPO
# Creates an empty .tt/history file in REPO if it does not already exist.
# The history file is gitignored (via .tt/.gitignore) and used by the
# transaction system to record before/after jj operation IDs for `tt history undo`.
init_tt_history() {
  local repo="$1"
  local history_file="$repo/.tt/history"
  if [[ ! -f "$history_file" ]]; then
    touch "$history_file"
  fi
}

# Read workspace dir from .tt/workspace symlink; returns 1 if not configured.
# Always resolves to an absolute path to prevent symlink loops.
get_workspace_dir() {
  local repo="$1"
  local symlink="$repo/.tt/workspace"
  if [[ -L "$symlink" ]]; then
    local ws_dir
    ws_dir="$(readlink "$symlink")"
    if [[ -n "$ws_dir" ]]; then
      # Resolve relative targets against the symlink's parent directory
      if [[ "$ws_dir" != /* ]]; then
        ws_dir="$(cd "$(dirname "$symlink")" && cd "$ws_dir" && pwd)"
      fi
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

# Usage: assert_bookmark_up_to_date REPO BOOKMARK
# Exits 1 if there are any commits between BOOKMARK and the working-copy parent
# (@-) that are not tracked by the bookmark. Used by commands that operate on
# the implicit current branch to ensure all work has been checkpointed.
#
# Skip this check when the user passes an explicit task-id, as that constitutes
# an intentional acknowledgement that the bookmark may be behind.
assert_bookmark_up_to_date() {
  local repo="$1" bookmark="$2"
  if ! check_bookmark_up_to_date "$repo" "$bookmark"; then
    log "Error: There are commits since the last checkpoint that are not tracked by the task bookmark."
    log "  Run 'tt task checkpoint' to record them before checking in."
    log "  Alternatively, pass the task ID explicitly to skip this check:"
    log "    tt task checkin ${bookmark}"
    exit 1
  fi
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

# Usage: make_absolute_symlink TARGET_PATH SYMLINK_PATH
# Creates or replaces SYMLINK_PATH pointing at TARGET_PATH, always using an
# absolute path for the target to prevent symlink loops (e.g. HEAD -> ./HEAD).
# TARGET_PATH must be an existing directory or file; exits 1 otherwise.
make_absolute_symlink() {
  local target_path="$1" symlink_path="$2"
  if [[ "$target_path" != /* ]]; then
    target_path="$(cd "$target_path" && pwd)"
  fi
  ln -snf "$target_path" "$symlink_path"
}

# Usage: update_head_symlink WORKSPACE_DIR TARGET_PATH
# Updates <workspace-dir>/HEAD to point at TARGET_PATH using an absolute path
# to prevent symlink loops.
update_head_symlink() {
  local workspace_dir="$1" target_path="$2"
  [[ -z "$workspace_dir" ]] && return 0
  [[ ! -d "$workspace_dir" ]] && return 0
  local head_path="$workspace_dir/HEAD"
  make_absolute_symlink "$target_path" "$head_path"
  log "Updated HEAD -> $target_path"
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
# Extracts the raw value of a YAML frontmatter field from multi-line content,
# preserving any quotes that were in the original.
parse_frontmatter_field() {
  local content="$1" field="$2"
  printf '%s' "$content" | awk -v field="$field" '
    /^---$/ { n++; next }
    n == 1 && $0 ~ ("^" field ":") {
      sub("^" field ":[[:space:]]*", "")
      print; exit
    }
  '
}

# Usage: parse_quoted_frontmatter_field CONTENT FIELD
# Extracts the value of a YAML frontmatter field from multi-line content,
# stripping leading and trailing quotation marks.
parse_quoted_frontmatter_field() {
  local value
  value="$(parse_frontmatter_field "$1" "$2")"
  printf '%s' "$value" | sed 's/^"\(.*\)"$/\1/'
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
    content="$(jj_show_at_revision "$repo" "$branch" "$path")" || continue
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
    c="$(jj_show_at_revision "$repo" "$branch" "$path")" || continue
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
# Prints the change_id of @ in the given worktree. Exits 1 on failure.
# We return the change_id (not the commit_id) because change IDs survive
# rebases: if @ is a descendant of a rebased branch, jj creates a new
# commit with the same change ID, so `jj edit <change_id>` will always
# resolve to the correct (post-rebase) version of the working-copy commit.
get_worktree_current_rev() {
  local worktree="$1"
  jj -R "$worktree" log -r '@' --no-graph -T 'change_id' 2>/dev/null
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

# Usage: parse_workspace_list_line LINE
# Parses one line from `jj workspace list -T 'name ++ ": " ++ root ++ "\n"'`.
# Outputs two lines to stdout:
#   line 1: workspace name
#   line 2: absolute filesystem path, or empty string if the path is an error
#            (i.e. the workspace has no recorded or resolvable path)
# Lines with error paths look like: "name: <Error: Workspace has no recorded path: name>"
parse_workspace_list_line() {
  local line="$1"
  local ws_name ws_path
  ws_name="$(printf '%s' "$line" | sed 's/: .*//')"
  ws_path="$(printf '%s' "$line" | sed 's/^[^:]*: //')"
  if [[ "$ws_path" == '<Error:'* ]]; then
    ws_path=''
  fi
  printf '%s\n%s\n' "$ws_name" "$ws_path"
}

# Usage: find_worktrees_for_branch REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX
# Outputs one workspace root path per line for each jj workspace where
# BOOKMARK is the current branch (resolved via resolve_current).
# Uses jj template 'name ++ ": " ++ root ++ "\n"' to get workspace paths.
find_worktrees_for_branch() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  # Get all workspace names + root paths using explicit template.
  # Format per line: "name: /absolute/path" or "name: <Error: ...>" for missing paths.
  local ws_list
  ws_list="$(jj -R "$repo" --ignore-working-copy workspace list --no-pager \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || return 0
  while IFS= read -r ws_line; do
    [[ -z "$ws_line" ]] && continue
    local parsed ws_name ws_root
    parsed="$(parse_workspace_list_line "$ws_line")"
    ws_name="$(printf '%s' "$parsed" | sed -n '1p')"
    ws_root="$(printf '%s' "$parsed" | sed -n '2p')"
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

# Usage: resolve_workspace_name REPO WORKTREE_PATH
# Prints the jj workspace name for the workspace at WORKTREE_PATH.
# Returns 0 and prints name if found, returns 1 if not found.
resolve_workspace_name() {
  local repo="$1" worktree_path="$2"
  local ws_list
  ws_list="$(jj -R "$repo" --ignore-working-copy workspace list \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || return 1
  while IFS= read -r ws_line; do
    [[ -z "$ws_line" ]] && continue
    local parsed ws_name ws_root
    parsed="$(parse_workspace_list_line "$ws_line")"
    ws_name="$(printf '%s' "$parsed" | sed -n '1p')"
    ws_root="$(printf '%s' "$parsed" | sed -n '2p')"
    if [[ "$ws_root" == "$worktree_path" ]]; then
      printf '%s' "$ws_name"
      return 0
    fi
  done <<< "$ws_list"
  return 1
}

# Usage: forget_worktree REPO WORKSPACE_NAME [WORKTREE_PATH]
# Forgets the jj workspace from the repository model.
# If WORKTREE_PATH is provided, also removes all files from disk.
forget_worktree() {
  local repo="$1" ws_name="$2" worktree_path="${3:-}"
  jj -R "$repo" workspace forget "$ws_name"
  if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
    rm -rf "$worktree_path"
  fi
}

# Usage: check_bookmark_up_to_date REPO BOOKMARK
# Returns 0 if there are no commits between BOOKMARK and the working-copy parent
# (@-) that are not tracked by the bookmark. Returns 1 if commits exist.
check_bookmark_up_to_date() {
  local repo="$1" bookmark="$2"
  local ahead_commits
  ahead_commits="$(jj -R "$repo" log \
    -r "(::@- & ~::${bookmark})" \
    --no-graph -T 'change_id ++ "\n"' 2>/dev/null)" || return 0
  [[ -z "$ahead_commits" ]]
}

# Usage: resolve_head_worktree WORKSPACE_DIR REPO
# Resolves the worktree path that HEAD currently points to.
# Falls back to REPO if HEAD is not a symlink or doesn't exist.
# Always returns an absolute path.
resolve_head_worktree() {
  local workspace_dir="$1" repo="$2"
  local head_path="${workspace_dir}/HEAD"
  if [[ -n "$workspace_dir" && -L "$head_path" ]]; then
    local head_target
    head_target="$(readlink "$head_path")" || true
    if [[ -n "$head_target" ]]; then
      # Resolve relative symlink
      if [[ "$head_target" != /* ]]; then
        head_target="${workspace_dir}/${head_target}"
      fi
      # Canonicalize (returns repo if target doesn't exist)
      local resolved
      resolved="$(cd "$head_target" 2>/dev/null && pwd)" || resolved="$repo"
      printf '%s' "$resolved"
      return 0
    fi
  fi
  printf '%s' "$repo"
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

# ---------------------------------------------------------------------------
# Descendant task helpers
# ---------------------------------------------------------------------------

# Usage: collect_descendant_task_dirs REPO BRANCH TASK_ID TASK_PREFIX PROJECT_PREFIX
#
# Outputs one `.tt/task/<slug>` directory path per line for every task that
# is a descendant of TASK_ID (direct children, grandchildren, etc.), read
# from BRANCH.  Traversal follows `subtask:` frontmatter entries.
#
# Only task IDs whose prefix matches TASK_PREFIX or PROJECT_PREFIX are
# followed; unknown entries are skipped silently.
#
# Does not output the task's own directory (the caller already handles that).
collect_descendant_task_dirs() {
  local repo="$1" branch="$2" task_id="$3" task_prefix="$4" project_prefix="$5"

  # BFS queue (bash array)
  local -a queue=("$task_id")
  local -a visited=("$task_id")

  while [[ ${#queue[@]} -gt 0 ]]; do
    local current="${queue[0]}"
    queue=("${queue[@]:1}")      # shift

    # Derive slug and read task file from branch
    local suffix
    if is_task_branch "$current" "$task_prefix"; then
      suffix="${current#$task_prefix}"
    elif is_project_branch "$current" "$project_prefix"; then
      suffix="${current#$project_prefix}"
    else
      continue
    fi

    local tf
    tf="$(task_file_path "$suffix")"
    local content
    content="$(jj_show_at_revision "$repo" "$branch" "$tf")" || continue

    # Extract all subtask IDs (any checkbox state)
    while IFS= read -r subtask_id; do
      [[ -z "$subtask_id" ]] && continue
      # Skip if already visited (cycle guard)
      local already=false
      local v
      for v in "${visited[@]}"; do
        [[ "$v" == "$subtask_id" ]] && { already=true; break; }
      done
      "$already" && continue

      visited+=("$subtask_id")

      # Emit directory for this descendant
      local sub_suffix
      if is_task_branch "$subtask_id" "$task_prefix"; then
        sub_suffix="${subtask_id#$task_prefix}"
      elif is_project_branch "$subtask_id" "$project_prefix"; then
        sub_suffix="${subtask_id#$project_prefix}"
      else
        continue
      fi
      task_dir_path "$sub_suffix"
      printf '\n'

      # Enqueue for further traversal
      queue+=("$subtask_id")
    done < <(printf '%s' "$content" | awk '
      /^---$/ { n++; next }
      n == 1 && /^subtask:/ {
        sub(/^subtask:[[:space:]]*\[[[:space:]x\-]\][[:space:]]*/, "")
        print
      }
    ')
  done
}

# ---------------------------------------------------------------------------
# Task frontmatter parsing
# ---------------------------------------------------------------------------

# parse_task_frontmatter CONTENT
#
# Populates global variables from task frontmatter:
#   PARSED_TITLE, PARSED_STATUS, PARSED_CREATED, PARSED_UPDATED, PARSED_BODY
#   PARSED_LABELS (array), PARSED_CONTEXTS (array), PARSED_SUBTASKS (array)
#
# Exits 1 with an error message if any unrecognized frontmatter key is found.
# Known keys: title, status, created, updated, label, context, subtask
parse_task_frontmatter() {
  local content="$1"

  PARSED_TITLE="$(parse_quoted_frontmatter_field "$content" "title")"
  PARSED_STATUS="$(parse_frontmatter_field "$content" "status")"
  PARSED_CREATED="$(parse_frontmatter_field "$content" "created")"
  PARSED_UPDATED="$(parse_frontmatter_field "$content" "updated")"
  PARSED_BODY="$(parse_body "$content")"

  PARSED_LABELS=()
  while IFS= read -r lbl; do [[ -n "$lbl" ]] && PARSED_LABELS+=("$lbl"); done \
    < <(printf '%s' "$content" | awk '/^---$/{n++; if(n==2)exit} n==1 && /^label:/{sub(/^label:[[:space:]]*/,""); print}')

  PARSED_CONTEXTS=()
  while IFS= read -r ctx; do [[ -n "$ctx" ]] && PARSED_CONTEXTS+=("$ctx"); done \
    < <(printf '%s' "$content" | awk '/^---$/{n++; if(n==2)exit} n==1 && /^context:/{sub(/^context:[[:space:]]*/,""); print}')

  PARSED_SUBTASKS=()
  while IFS= read -r st; do [[ -n "$st" ]] && PARSED_SUBTASKS+=("$st"); done \
    < <(printf '%s' "$content" | awk '/^---$/{n++; if(n==2)exit} n==1 && /^subtask:/{sub(/^subtask:[[:space:]]*/,""); print}')

  # Reject unrecognized frontmatter keys
  local unknown
  unknown="$(printf '%s' "$content" | awk '
    /^---$/ { n++; if (n==2) exit; next }
    n==1 && /^[a-zA-Z]/ {
      key=$0; sub(/:.*/, "", key)
      if (key != "title" && key != "status" && key != "created" && key != "updated" \
          && key != "label" && key != "context" && key != "subtask")
        print key
    }
  ')"
  if [[ -n "$unknown" ]]; then
    printf 'Error: Unrecognized frontmatter field(s):\n%s\n' "$unknown" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Transaction management
#
# A "transaction" records the jj operation ID before and after a mutating tt
# command, enabling `tt history undo` to restore the repository state.
#
# Log file: <repo>/.tt/history
# Format:   one line per transaction: <before-op-id>:<after-op-id>
#           An in-progress transaction has an empty after-op-id: <before-op-id>:
#
# Nesting: sub-commands invoked by a top-level command inherit TT_TRANSACTION_ID
# via the environment. tt_begin_transaction is a no-op when TT_TRANSACTION_ID is
# already set. The internal (non-exported) _TT_TRANSACTION_OWNER flag ensures
# only the owning process commits or rolls back the transaction.
# ---------------------------------------------------------------------------

# Usage: tt_begin_transaction REPO
# Begins a tt transaction. No-op if TT_TRANSACTION_ID is already set (nested call).
# Captures the current jj operation ID, checks for in-progress transactions,
# appends "<before-op-id>:" to .tt/history, exports TT_TRANSACTION_ID, and sets
# an ERR trap to auto-rollback on failure.
tt_begin_transaction() {
  local repo="$1"
  # No-op when nested (parent command already began a transaction)
  if [[ -n "${TT_TRANSACTION_ID:-}" ]]; then
    return 0
  fi

  local history_file="$repo/.tt/history"

  # Capture current jj operation ID
  local before_op
  before_op="$(get_jj_op_id "$repo")" || {
    log "Error: Could not read jj operation ID to begin transaction"
    exit 1
  }

  # Check for in-progress transaction (last line has empty after-op-id)
  if [[ -f "$history_file" && -s "$history_file" ]]; then
    local last_line
    last_line="$(tail -n 1 "$history_file" 2>/dev/null)" || true
    if [[ -n "$last_line" ]]; then
      local last_after="${last_line#*:}"
      if [[ -z "$last_after" ]]; then
        log "Error: Another tt command is in progress (incomplete transaction)."
        log "  To revert a crashed process: tt history undo --force"
        log "  Or to keep the current state: tt history unlock --force"
        exit 1
      fi
    fi
  fi

  # Append in-progress entry to history log
  printf '%s:\n' "$before_op" >> "$history_file"

  # Export for sub-commands (nested tt_begin_transaction calls will be no-ops)
  export TT_TRANSACTION_ID="$before_op"
  # Mark this process as the transaction owner (not exported; sub-processes don't inherit)
  _TT_TRANSACTION_OWNER=true

  # Set ERR trap to auto-rollback on failure
  trap 'tt_rollback_transaction "'"$repo"'"' ERR
}

# Usage: tt_commit_transaction REPO
# Finalizes the transaction by writing the after-op-id into .tt/history.
# No-op when called from a nested sub-command (not the transaction owner).
tt_commit_transaction() {
  local repo="$1"
  # Only the owning process commits the transaction
  if [[ "${_TT_TRANSACTION_OWNER:-}" != "true" ]]; then
    return 0
  fi

  local history_file="$repo/.tt/history"
  local before_op="${TT_TRANSACTION_ID}"

  # Capture current jj operation ID
  local after_op
  after_op="$(get_jj_op_id "$repo")" || {
    log "Warning: Could not read jj operation ID for transaction commit; history may be incomplete"
    after_op="unknown"
  }

  # Replace the last line (in-progress: "<before>:") with the completed entry ("<before>:<after>")
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$ s|^${before_op}:\$|${before_op}:${after_op}|" "$history_file"
  else
    sed -i "$ s|^${before_op}:\$|${before_op}:${after_op}|" "$history_file"
  fi

  # Clear ERR trap and ownership flag
  trap - ERR
  unset _TT_TRANSACTION_OWNER
}

# Usage: tt_rollback_transaction REPO
# Rolls back the transaction by restoring jj to the before-op state and
# removing the in-progress line from .tt/history.
# No-op when called from a nested sub-command (not the transaction owner).
tt_rollback_transaction() {
  local repo="$1"
  # Only the owning process rolls back
  if [[ "${_TT_TRANSACTION_OWNER:-}" != "true" ]]; then
    return 0
  fi

  local before_op="${TT_TRANSACTION_ID:-}"
  if [[ -z "$before_op" ]]; then
    return 0
  fi

  local history_file="$repo/.tt/history"

  log "Rolling back transaction (restoring jj operation: ${before_op:0:12}...)"

  # Restore jj to before-op state
  jj -R "$repo" op restore "$before_op" 2>/dev/null || \
    log "Warning: Could not restore jj operation state; manual recovery may be needed"

  # Remove the in-progress line from history
  if [[ -f "$history_file" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "/^${before_op}:\$/d" "$history_file"
    else
      sed -i "/^${before_op}:\$/d" "$history_file"
    fi
  fi

  # Clear ERR trap and ownership flag
  trap - ERR
  unset _TT_TRANSACTION_OWNER
}
