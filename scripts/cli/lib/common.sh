# Common functions for tt bootstrap CLI scripts.
# Source this file; do not execute directly.

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

# Return true if bookmark name matches project ID pattern (<prefix><slug>-<hex>).
is_project_branch() {
  local bookmark="$1"
  local prefix="$2"
  [[ "$bookmark" == "$prefix"* ]] && [[ "$bookmark" =~ -[0-9a-fA-F]{8}$ ]]
}

# Usage: resolve_current REPO TASK_PREFIX PROJECT_PREFIX
#
# Resolve the "current branch" (closest ancestor of the working copy @ that has a bookmark).
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

  current_branch="$(jj "${jj_opts[@]}" log -r 'ancestors(@) & bookmarks()' -n 1 --no-graph -T 'local_bookmarks.map(|b| b.name()).join(",")' 2>/dev/null)" || true
  current_branch="${current_branch%%,*}"  # Take first if comma-separated

  if [[ -z "$current_branch" ]]; then
    printf '%s\n\n\n' '@'
  else
    local parent_rev
    if ! parent_rev="$(jj "${jj_opts[@]}" log -r "$current_branch" -n 1 --no-graph -T 'commit_id' 2>/dev/null)"; then
      log "Error: Could not resolve current branch: $current_branch"
      exit 1
    fi
    if is_task_branch "$current_branch" "$task_prefix"; then
      printf '%s\n%s\n%s\n' "$parent_rev" ".tt/task/${current_branch#$task_prefix}.md" "$current_branch"
    elif is_project_branch "$current_branch" "$project_prefix"; then
      printf '%s\n%s\n%s\n' "$parent_rev" ".tt/task/${current_branch#$project_prefix}.md" "$current_branch"
    else
      printf '%s\n\n\n' "$parent_rev"
    fi
  fi
}
