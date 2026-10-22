# User hook execution for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _hook__run — run a repository hook with tt environment variables set

# Usage: _hook__run REPO HOOK_NAME BLOCKING WORKTREE_DIR WORKSPACE_DIR [VAR=val ...]
# Runs .tt/hooks/<hook-name> with TT_WORKSPACE_DIR and TT_WORKTREE_DIR set,
# plus any additional VAR=val pairs. Blocking hooks abort on non-zero exit.
_hook__run() {
  local repo="$1" hook_name="$2" blocking="$3" worktree_dir="$4" workspace_dir="$5"
  shift 5
  local hook_path="$repo/$(_path__metadata "hooks/$hook_name")"
  [[ ! -x "$hook_path" ]] && return 0
  local exit_code=0
  env TT_WORKSPACE_DIR="${workspace_dir:-}" TT_WORKTREE_DIR="$worktree_dir" "$@" "$hook_path" 1>&2 \
    || exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    if [[ "$blocking" == true ]]; then
      _ui__log "Error: Hook '$hook_name' failed (exit $exit_code); aborting."
      exit 1
    else
      _ui__log "Warning: Hook '$hook_name' failed (exit $exit_code; non-blocking)."
    fi
  fi
}
