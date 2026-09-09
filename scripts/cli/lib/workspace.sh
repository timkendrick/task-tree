# Workspace resolution and configuration for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _workspace__resolve_repo        — resolve the repository root (--repo, TT_REPO, walk-up)
#   _workspace__check_repository    — whether a path is a repository root
#   _workspace__resolve_canonical_repo — canonical repository root behind a worktree
#   _workspace__get_task_prefix     — task branch prefix from .tt/config.toml
#   _workspace__get_project_prefix  — project branch prefix from .tt/config.toml
#   _workspace__set_dir             — point the .tt/workspace symlink at a directory
#   _workspace__get_dir             — read the configured workspace directory
#   _workspace__update_head         — point <workspace-dir>/HEAD at a worktree
#   _workspace__get_active_worktree — read the active worktree from <workspace-dir>/HEAD

# Usage: repo=$(_workspace__resolve_repo "$repo_flag_value")
#
# Resolves the repository root using the following priority order:
#   1. $repo_flag_value — the value passed to --repo (if non-empty)
#   2. $TT_REPO        — the TT_REPO environment variable (if set and non-empty)
#   3. _repo__find_repository_root — walk up from CWD to find the enclosing repo
#
# Prints the resolved repo path to stdout as an absolute, symlink-resolved path.
#
# Exits 1 with an error message if the path cannot be resolved or is not a
# version-control repository.
_workspace__resolve_repo() {
  local repo="${1:-}"

  # Priority 1: explicit --repo flag (already in $repo if set)
  if [[ -z "$repo" ]]; then
    # Priority 2: TT_REPO environment variable
    if [[ -n "${TT_REPO:-}" ]]; then
      repo="$TT_REPO"
    else
      # Priority 3: walk up from CWD
      if ! repo="$(_repo__find_repository_root)"; then
        _ui__log "Error: No enclosing repository. Use --repo or set TT_REPO."
        exit 1
      fi
    fi
  fi

  if ! _repo__check_is_repository "$repo"; then
    _ui__log "Error: Not a repository: $repo"
    exit 1
  fi

  # Canonicalize the path so that it matches the VCS-backed repository root unambiguously
  repo="$(_path__resolve_symlinks "$repo")"
  printf '%s' "$repo"
}

# Usage: _workspace__check_repository PATH
# Returns 0 when PATH is the root of a repository the backend understands.
# Documented pass-through to _repo__check_is_repository so commands that must
# validate a path before the repository is resolved can test it without
# reaching into the VCS layer.
_workspace__check_repository() {
  local path="$1"
  _repo__check_is_repository "$path"
}

# Usage: _workspace__resolve_canonical_repo REPO
# Prints the canonical repository root behind REPO. REPO may itself be the
# canonical root (printed back unchanged) or a task worktree, in which case
# this resolves to the primary repository the worktree is attached to — where
# the shared repository state, and everything tt keeps beside it, actually
# lives. Returns non-zero with an error logged when the link cannot be
# followed. Documented pass-through to _repo__resolve_repository_root.
_workspace__resolve_canonical_repo() {
  local repo="$1"
  _repo__resolve_repository_root "$repo"
}

# Read task_prefix from .tt/config.toml; default "task/" if missing or unreadable.
_workspace__get_task_prefix() {
  local repo="$1"
  local config="$repo/$(_path__metadata 'config.toml')"
  local default_prefix='task/'
  if [[ -r "$config" ]]; then
    convfmt --from toml --to json < "$config" | jq -r '.task_prefix // "'"$default_prefix"'"'
  else
    printf '%s' "$default_prefix"
  fi
}

# Read project_prefix from .tt/config.toml; default "project/" if missing or unreadable.
_workspace__get_project_prefix() {
  local repo="$1"
  local config="$repo/$(_path__metadata 'config.toml')"
  local default_prefix='project/'
  if [[ -r "$config" ]]; then
    convfmt --from toml --to json < "$config" | jq -r '.project_prefix // "'"$default_prefix"'"'
  else
    printf '%s' "$default_prefix"
  fi
}

# Usage: _workspace__set_dir REPO VIRTUAL_DIR
# Creates or replaces the <repo>/.tt/workspace symlink pointing at VIRTUAL_DIR.
# Always uses an absolute target path; the absolute-path guarantee is an
# implementation detail enforced here so callers never need to think about it.
_workspace__set_dir() {
  local repo="$1" virtual_dir="$2"
  _path__make_absolute_symlink "$virtual_dir" "$repo/$(_path__metadata 'workspace')"
}

# Read workspace dir from .tt/workspace symlink; returns 1 if not configured.
# Always resolves to an absolute path to prevent symlink loops.
_workspace__get_dir() {
  local repo="$1"
  local symlink="$repo/$(_path__metadata 'workspace')"
  if [[ -L "$symlink" ]]; then
    local ws_dir
    ws_dir="$(readlink "$symlink")"
    if [[ -n "$ws_dir" ]]; then
      # Resolve relative targets against the symlink's parent directory,
      # then canonicalise to strip OS-level symlinks (e.g. /var -> /private/var).
      if [[ "$ws_dir" != /* ]]; then
        ws_dir="$(_path__resolve_symlinks "$(cd "$(dirname "$symlink")" && cd "$ws_dir" && pwd)")"
      else
        ws_dir="$(_path__resolve_symlinks "$ws_dir")"
      fi
      printf '%s' "$ws_dir"
      return 0
    fi
  fi
  return 1
}

# Usage: _workspace__update_head WORKSPACE_DIR TARGET_PATH
# Updates <workspace-dir>/HEAD to point at TARGET_PATH using an absolute path
# to prevent symlink loops.
_workspace__update_head() {
  local workspace_dir="$1" target_path="$2"
  [[ -z "$workspace_dir" ]] && return 0
  [[ ! -d "$workspace_dir" ]] && return 0
  local head_path="$workspace_dir/HEAD"
  _path__make_absolute_symlink "$target_path" "$head_path"
  _ui__log "Updated HEAD -> $target_path"
}

# Read the active worktree path from <workspace-dir>/HEAD.
# Returns 1 if the HEAD symlink is absent or unreadable; never falls back.
# Always returns a canonicalised absolute path (pwd -P).
_workspace__get_active_worktree() {
  local workspace_dir="$1"
  local head_path="$workspace_dir/HEAD"
  [[ -L "$head_path" ]] || return 1
  local head_target
  head_target="$(readlink "$head_path")" || return 1
  [[ -n "$head_target" ]] || return 1
  # Resolve relative symlink
  if [[ "$head_target" != /* ]]; then
    head_target="${workspace_dir}/${head_target}"
  fi
  resolved="$(_path__resolve_symlinks "$head_target")"
  printf '%s' "$resolved"
}
