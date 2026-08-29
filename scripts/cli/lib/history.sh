# Transaction history management for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# A "transaction" records the jj operation ID before and after a mutating tt
# command, enabling `tt history undo` to restore the repository state.
#
# Log file: <canonical-repo>/.tt/history
# Format:   one line per transaction: <before-op-id>:<after-op-id>
#           An in-progress transaction has an empty after-op-id: <before-op-id>:
#
# History location: the history file always lives in the **canonical** jj repo
# root (the repo whose .jj/repo entry is a directory, not a pointer file).
# Secondary jj workspaces have a .jj/repo *file* containing a relative path
# back to the canonical repo's .jj/repo directory. _repo__resolve_repository_root
# follows that pointer so all workspaces share a single history file.
#
# Nesting: sub-commands invoked by a top-level command inherit TT_TRANSACTION_ID
# via the environment. _history__begin_transaction is a no-op when TT_TRANSACTION_ID is
# already set. The internal (non-exported) _TT_TRANSACTION_OWNER variable
# stores the resolved history file path for the owning process; it is not
# exported so sub-processes never inherit it (they are not the transaction owner).
#
# Public surface:
#   _history__init                 — create an empty .tt/history file if absent
#   _history__resolve_file         — path to the canonical .tt/history file
#   _history__begin_transaction    — record an in-progress entry and set the rollback trap
#   _history__commit_transaction   — finalize the in-progress entry with the after-op-id
#   _history__rollback_transaction — restore the before-op state and drop the entry

# Usage: _history__init REPO
# Creates an empty .tt/history file in REPO if it does not already exist.
# The history file is gitignored (via .tt/.gitignore) and used by the
# transaction system to record before/after jj operation IDs for `tt history undo`.
_history__init() {
  local repo="$1"
  local history_file="$repo/$(_path__metadata 'history')"
  if [[ ! -f "$history_file" ]]; then
    touch "$history_file"
  fi
}

# Usage: _history__resolve_file REPO
# Returns the path to the .tt/history file for REPO.
# Follows .jj/repo pointer files so secondary jj workspaces resolve to the
# canonical repo's history file rather than a per-worktree copy.
# Canonical repos return <repo>/.tt/history directly.
_history__resolve_file() {
  local repo="$1"
  local canonical_repo
  canonical_repo="$(_repo__resolve_repository_root "$repo")" || return 1
  printf '%s/%s' "$canonical_repo" "$(_path__metadata 'history')"
}

# Usage: _history__begin_transaction REPO
# Begins a tt transaction. No-op if TT_TRANSACTION_ID is already set (nested call).
# Captures the current jj operation ID, checks for in-progress transactions,
# appends "<before-op-id>:" to .tt/history, exports TT_TRANSACTION_ID, and sets
# an ERR trap to auto-rollback on failure.
#
# Resolves and caches the canonical history file path in _TT_TRANSACTION_OWNER
# at begin time (while the repo/worktree still exists on disk), so that
# _history__commit_transaction and _history__rollback_transaction can use it even if the
# worktree has been deleted by the time they run (e.g. worktree delete).
_history__begin_transaction() {
  local repo="$1"
  # No-op when nested (parent command already began a transaction)
  if [[ -n "${TT_TRANSACTION_ID:-}" ]]; then
    return 0
  fi

  local history_file
  history_file="$(_history__resolve_file "$repo")" || exit 1

  # Capture current jj operation ID
  local before_op
  before_op="$(_repo__get_operation_id "$repo")" || {
    _ui__log "Error: Could not read jj operation ID to begin transaction"
    exit 1
  }

  # Check for in-progress transaction (last line has empty after-op-id)
  if [[ -f "$history_file" && -s "$history_file" ]]; then
    local last_line
    last_line="$(tail -n 1 "$history_file" 2>/dev/null)" || true
    if [[ -n "$last_line" ]]; then
      local last_after="${last_line#*:}"
      if [[ -z "$last_after" ]]; then
        _ui__log "Error: Another tt command is in progress (incomplete transaction)."
        _ui__log "  To revert a crashed process: tt history undo --force"
        _ui__log "  Or to keep the current state: tt history unlock --force"
        exit 1
      fi
    fi
  fi

  # Append in-progress entry to history log
  printf '%s:\n' "$before_op" >> "$history_file"

  # Export for sub-commands (nested _history__begin_transaction calls will be no-ops)
  export TT_TRANSACTION_ID="$before_op"
  # Store resolved history file path for commit/rollback (not exported — sub-processes
  # are not the transaction owner). Using the file path rather than `true` means we
  # avoid re-resolving at commit/rollback time, which may fail if the worktree has
  # been deleted by then (e.g. worktree delete).
  _TT_TRANSACTION_OWNER="$history_file"

  # Set ERR trap to auto-rollback on failure
  trap '_history__rollback_transaction "'"$repo"'"' ERR
}

# Usage: _history__commit_transaction REPO
# Finalizes the transaction by writing the after-op-id into .tt/history.
# No-op when called from a nested sub-command (not the transaction owner).
_history__commit_transaction() {
  local repo="$1"
  # Only the owning process commits the transaction
  if [[ -z "${_TT_TRANSACTION_OWNER:-}" ]]; then
    return 0
  fi

  local history_file="${_TT_TRANSACTION_OWNER}"
  local before_op="${TT_TRANSACTION_ID}"

  # Derive canonical repo from the history file path (walk up from .tt/ to find .jj/).
  # This is safe even if $repo (a worktree) has been deleted, since history_file
  # is always inside the canonical repo which remains on disk.
  local canonical_repo
  canonical_repo="$(cd "$(dirname "$history_file")" && _repo__find_repository_root)" || {
    _ui__log "Warning: Could not derive canonical repo from history file path; history may be incomplete"
    canonical_repo="$repo"
  }

  # Capture current jj operation ID
  local after_op
  after_op="$(_repo__get_operation_id "$canonical_repo")" || {
    _ui__log "Warning: Could not read jj operation ID for transaction commit; history may be incomplete"
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

# Usage: _history__rollback_transaction REPO
# Rolls back the transaction by restoring jj to the before-op state and
# removing the in-progress line from .tt/history.
# No-op when called from a nested sub-command (not the transaction owner).
_history__rollback_transaction() {
  local repo="$1"
  # Only the owning process rolls back
  if [[ -z "${_TT_TRANSACTION_OWNER:-}" ]]; then
    return 0
  fi

  local before_op="${TT_TRANSACTION_ID:-}"
  if [[ -z "$before_op" ]]; then
    return 0
  fi

  local history_file="${_TT_TRANSACTION_OWNER}"

  # Derive canonical repo from the history file path (walk up from .tt/ to find .jj/).
  local canonical_repo
  canonical_repo="$(cd "$(dirname "$history_file")" && _repo__find_repository_root)" || canonical_repo="$repo"

  _ui__log "Rolling back transaction (restoring jj operation: ${before_op:0:12}...)"

  # Restore jj to before-op state.
  # Use a subshell to cd into the canonical repo first, so jj can resolve CWD
  # even when the caller's working directory has been deleted (e.g. after
  # worktree delete).
  (cd "$canonical_repo" && jj -R "$canonical_repo" op restore "$before_op" 2>/dev/null) || \
    _ui__log "Warning: Could not restore jj operation state; manual recovery may be needed"

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
