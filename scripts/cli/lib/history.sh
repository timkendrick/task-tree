# Transaction history management for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# A "transaction" records the VCS operation ID before and after a mutating tt
# command, enabling `tt history undo` to restore the repository state.
#
# Log file: <canonical-repo>/.tt/history
# Format:   one line per transaction: <before-op-id>:<after-op-id>
#           An in-progress transaction has an empty after-op-id: <before-op-id>:
#
# History location: the history file always lives in the **canonical** repo
# root (the repo whose .jj/repo entry is a directory, not a pointer file).
# Secondary workspaces have a .jj/repo *file* containing a relative path
# back to the canonical repo's .jj/repo directory. _repo__resolve_repository_root
# follows that pointer so all workspaces share a single history file.
#
# Nesting: sub-commands invoked by a top-level command inherit TT_TRANSACTION_ID
# via the environment. _history__begin_transaction is a no-op when TT_TRANSACTION_ID is
# already set. The internal (non-exported) _TT_TRANSACTION_OWNER variable
# stores the resolved history file path for the owning process; it is not
# exported so sub-processes never inherit it (they are not the transaction owner).
#
# Closing a transaction — by commit or by rollback — unsets TT_TRANSACTION_ID as
# well as the ownership flag, so that a sub-command the owner runs afterwards
# opens a transaction of its own. A command that keeps working past its own
# commit is not unusual (a check-in propagates to the siblings once the merge
# has landed), and work done then is still work that must be recorded and still
# work a failure has to unwind.
#
# Public surface:
#   _history__init                 — create an empty .tt/history file if absent
#   _history__replace_last_line    — rewrite the file's last line when it matches
#   _history__delete_lines         — rewrite the file without a given line
#   _history__resolve_file         — path to the canonical .tt/history file
#   _history__resolve_operation    — identifier of the repository's current operation
#   _history__restore_operation    — return the repository to a recorded operation
#   _history__begin_transaction    — record an in-progress entry and set the rollback trap
#   _history__commit_transaction   — finalize the in-progress entry with the after-op-id
#   _history__rollback_transaction — restore the before-op state and drop the entry
#
# Functions named with a double underscore (__history__*) are internal helpers
# private to this module and not part of the public surface.

# Usage: _history__replace_last_line FILE EXPECTED NEW
# Rewrites FILE so that its last line, when it is exactly EXPECTED, becomes
# NEW; any other last line is left as it is. Pure bash: the file is small.
_history__replace_last_line() {
  local file="$1" expected="$2" new="$3"
  local content
  content="$(<"$file")"
  [[ -n "$content" ]] || return 0
  local head='' last="$content"
  if [[ "$content" == *$'\n'* ]]; then
    head="${content%$'\n'*}"
    last="${content##*$'\n'}"
  fi
  [[ "$last" == "$expected" ]] && last="$new"
  if [[ -n "$head" ]]; then
    printf '%s\n%s\n' "$head" "$last" > "$file"
  else
    printf '%s\n' "$last" > "$file"
  fi
}

# Usage: _history__delete_lines FILE LINE
# Rewrites FILE without any line that is exactly LINE. Pure bash.
_history__delete_lines() {
  local file="$1" match="$2"
  local line out=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$match" ]] && continue
    out+="$line"$'\n'
  done < "$file"
  printf '%s' "$out" > "$file"
}

# Usage: _history__init REPO
# Creates an empty .tt/history file in REPO if it does not already exist.
# The history file is gitignored (via .tt/.gitignore) and used by the
# transaction system to record before/after VCS operation IDs for `tt history undo`.
_history__init() {
  local repo="$1"
  local history_file="$repo/$(_path__metadata 'history')"
  if [[ ! -f "$history_file" ]]; then
    touch "$history_file"
  fi
}

# Usage: _history__resolve_file REPO
# Returns the path to the .tt/history file for REPO.
# Follows .jj/repo pointer files so secondary workspaces resolve to the
# canonical repo's history file rather than a per-worktree copy.
# Canonical repos return <repo>/.tt/history directly.
_history__resolve_file() {
  local repo="$1"
  local canonical_repo
  canonical_repo="$(_repo__resolve_repository_root "$repo")" || return 1
  printf '%s/%s' "$canonical_repo" "$(_path__metadata 'history')"
}

# Usage: _history__resolve_operation REPO
# Prints the identifier of the operation REPO is currently at — the value a
# transaction entry records at each of its two ends. Documented pass-through to
# _repo__get_operation_id, so a command that reads or repairs the history file can
# name the current operation without reaching into the VCS layer. Returns
# non-zero (nothing printed) when the operation log cannot be read.
_history__resolve_operation() {
  local repo="$1"
  _repo__get_operation_id "$repo"
}

# Usage: _history__restore_operation REPO OPERATION
# Returns REPO to the state recorded at OPERATION, discarding everything done
# since — the working copy included. Documented pass-through to
# _repo__restore_operation, so a command that undoes a recorded transaction can
# revert to its before-op without reaching into the VCS layer.
#
# The restore is itself recorded as a NEW operation: afterwards the repository's
# state matches OPERATION but its current operation ID does not equal OPERATION.
# A caller keeping the history file in step must therefore re-read the current
# operation (_history__resolve_operation) rather than assume it. Returns non-zero
# when the restore fails.
_history__restore_operation() {
  local repo="$1" operation="$2"
  _repo__restore_operation "$repo" "$operation"
}

# Usage: _history__begin_transaction REPO
# Begins a tt transaction. No-op if TT_TRANSACTION_ID is already set (nested call).
# Captures the current VCS operation ID, checks for in-progress transactions,
# appends "<before-op-id>:" to .tt/history, exports TT_TRANSACTION_ID, sets the
# abort trap (see __history__abort_transaction), and finally snapshots the
# current worktree's working copy so pending on-disk changes are captured as
# part of the transaction. The ordering is deliberate: the before-op ID is recorded
# first, so the operation created by the snapshot falls inside the transaction
# and `tt history undo` reverts it along with everything else.
#
# The bookmark-on-@ precondition (_worktree__ensure_working_copy) is NOT
# checked here: it needs branch-model knowledge this module does not have, so
# commands that write to branches must check it themselves before beginning
# the transaction.
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

  # Capture current VCS operation ID
  local before_op
  before_op="$(_repo__get_operation_id "$repo")" || {
    _ui__log "Error: Could not read the VCS operation ID to begin transaction"
    exit 1
  }

  # Check for in-progress transaction (last line has empty after-op-id)
  if [[ -f "$history_file" && -s "$history_file" ]]; then
    local last_line
    last_line="$(<"$history_file")"
    last_line="${last_line##*$'\n'}"
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

  # Auto-rollback on any exit that does not pass through the commit
  trap '__history__abort_transaction "'"$repo"'"' ERR EXIT

  # Capture pending working-copy changes into the working-copy commit. This
  # must run AFTER the before-op ID is recorded above so that undoing the
  # transaction also reverts the snapshot. A failure here rolls the
  # transaction back via the ERR trap just installed.
  local snapshot_worktree
  snapshot_worktree="$(_repo__resolve_worktree_root "$repo")"
  _repo__snapshot_worktree "$snapshot_worktree"
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
  canonical_repo="$(cd "$(_path__dirname "$history_file")" && _repo__find_repository_root)" || {
    _ui__log "Warning: Could not derive canonical repo from history file path; history may be incomplete"
    canonical_repo="$repo"
  }

  # Capture current VCS operation ID
  local after_op
  after_op="$(_repo__get_operation_id "$canonical_repo")" || {
    _ui__log "Warning: Could not read the VCS operation ID for transaction commit; history may be incomplete"
    after_op="unknown"
  }

  # Replace the last line (in-progress: "<before>:") with the completed entry ("<before>:<after>")
  _history__replace_last_line "$history_file" "${before_op}:" "${before_op}:${after_op}"

  # The transaction is closed: clear the abort trap, and with it every trace
  # that would make a later sub-command believe it is running inside one.
  trap - ERR EXIT
  unset _TT_TRANSACTION_OWNER
  unset TT_TRANSACTION_ID
}

# Usage: __history__abort_transaction REPO
#
# Trap handler installed by _history__begin_transaction, for an open
# transaction that the shell is leaving without having committed it.
#
# It is installed on ERR *and* EXIT because neither alone is enough. An ERR
# trap does not fire for `exit`, which is how every command reports a failed
# precondition, so an ERR-only trap leaves the repository half-written and the
# in-progress entry in the log, where it blocks the next command as a stale
# lock. An EXIT trap alone would catch that, but a command killed by `set -e`
# fires ERR first, so both are taken and the handler disarms both before doing
# anything: a set -e failure would otherwise roll back twice, and the handler's
# own `exit` would re-enter it.
#
# The status that triggered the trap is captured first and re-raised last, so
# the command's own exit code survives the rollback. A rollback that itself
# fails warns from within _history__rollback_transaction and does not change
# the status: the caller asked about its command, not about the recovery.
#
# Any exit reaching the handler rolls back, a successful one included, because
# an open transaction means the command never reached its commit point: its
# writes are half-applied by definition, and exiting zero with one open is a
# bug that would otherwise leave the lock behind silently.
__history__abort_transaction() {
  local status=$?
  local repo="$1"
  trap - ERR EXIT
  _history__rollback_transaction "$repo"
  exit "$status"
}

# Usage: _history__rollback_transaction REPO
# Rolls back the transaction by restoring the VCS to the before-op state and
# removing the in-progress line from .tt/history.
# No-op when called from a nested sub-command (not the transaction owner).
#
# When the restore itself fails, the in-progress line is KEPT rather than
# removed: it locks the repository so the next tt command refuses with the
# existing "Another tt command is in progress" error instead of running
# against a half-written repository. The failure is reported as an error
# carrying the operation to restore and both ways out (tt history undo
# --force, or tt history unlock --force once recovered by hand). The calling
# command's own exit status is unaffected either way.
#
# Working-copy preservation: restoring an operation also resets the on-disk
# working copy, which would strip the changes captured by the transaction's
# begin-time snapshot (and any captured later) from disk. To keep the user's
# uncommitted work, the files changed in the working-copy commit are copied
# aside before the restore and copied back afterwards (deletions are
# likewise re-applied), but only when the restore lands on the same change —
# i.e. the transaction never moved the working copy; when it did, the plain
# restore semantics stand and the pre-transaction position wins. The
# preserved files end up exactly as they were before the transaction: on
# disk, not yet captured, picked up by the next snapshot. Preservation is
# best-effort: every step degrades to a plain restore (e.g. when the
# worktree has been deleted mid-transaction).
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
  canonical_repo="$(cd "$(_path__dirname "$history_file")" && _repo__find_repository_root)" || canonical_repo="$repo"

  _ui__log "Rolling back transaction (restoring VCS operation: ${before_op:0:12}...)"

  # Copy the working-copy commit's changed files aside before the restore so
  # they can be re-applied afterwards (see the header comment). Best-effort:
  # failures simply skip preservation.
  local wc_worktree='' wc_change_before='' preserve_dir='' rel
  wc_worktree="$(_repo__resolve_worktree_root "$repo")" || wc_worktree=''
  if [[ -n "$wc_worktree" && -d "$wc_worktree" ]]; then
    _repo__snapshot_worktree "$wc_worktree" || true
    wc_change_before="$(_repo__resolve_change "$wc_worktree" '@')" || wc_change_before=''
    local changed_files=''
    changed_files="$(_repo__list_changed_files "$wc_worktree" '@')" || changed_files=''
    if [[ -n "$changed_files" ]]; then
      preserve_dir="$(mktemp -d)" || preserve_dir=''
    fi
    if [[ -n "$preserve_dir" ]]; then
      while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        if [[ -e "$wc_worktree/$rel" || -L "$wc_worktree/$rel" ]]; then
          mkdir -p "$preserve_dir/files/$(_path__dirname "$rel")" 2>/dev/null || continue
          cp -pRP "$wc_worktree/$rel" "$preserve_dir/files/$rel" 2>/dev/null || true
        else
          # The working-copy change is a deletion: remember it so the file
          # the restore re-creates can be deleted again.
          printf '%s\n' "$rel" >> "$preserve_dir/deleted"
        fi
      done <<< "$changed_files"
    fi
  fi

  # Restore the VCS to the before-op state. The backend operation works even
  # when the caller's working directory has been deleted (e.g. after
  # worktree delete).
  #
  # A restore that fails leaves the repository mid-transaction, so the
  # in-progress entry is KEPT: it is the lock that makes the next tt command
  # refuse instead of running against a half-written repository.
  if ! _repo__restore_operation "$canonical_repo" "$before_op"; then
    # Discard the preserved copies without re-applying them. A failed restore
    # never disturbed the files, and the re-apply is gated on a working-copy
    # comparison that means nothing once the restore did not happen.
    if [[ -n "$preserve_dir" ]]; then
      rm -rf "$preserve_dir"
    fi

    _ui__log "Error: Could not restore the VCS operation state."
    _ui__log "  The repository was left mid-transaction at operation $before_op."
    _ui__log "  The transaction is still recorded, so the next tt command will refuse."
    _ui__log "  To retry the revert:        tt history undo --force"
    _ui__log "  Or, once recovered by hand: tt history unlock --force"

    # Close out this process's transaction state so no second rollback runs;
    # only the history entry survives, which is what makes the damage visible.
    trap - ERR EXIT
    unset _TT_TRANSACTION_OWNER
    unset TT_TRANSACTION_ID
    return 0
  fi

  # Re-apply the preserved working-copy changes when the restore landed on
  # the same change (i.e. the transaction never moved the working copy).
  if [[ -n "$preserve_dir" ]]; then
    local wc_change_after=''
    wc_change_after="$(_repo__resolve_change "$wc_worktree" '@')" || wc_change_after=''
    if [[ -n "$wc_change_before" && "$wc_change_after" == "$wc_change_before" ]]; then
      if [[ -d "$preserve_dir/files" ]]; then
        ( cd "$preserve_dir/files" && find . \( -type f -o -type l \) -print ) 2>/dev/null \
          | while IFS= read -r rel; do
              rel="${rel#./}"
              [[ -z "$rel" ]] && continue
              mkdir -p "$wc_worktree/$(_path__dirname "$rel")" 2>/dev/null || continue
              rm -f "$wc_worktree/$rel" 2>/dev/null
              cp -pRP "$preserve_dir/files/$rel" "$wc_worktree/$rel" 2>/dev/null || \
                _ui__log "Warning: Could not preserve uncommitted change to $rel; it may still be recoverable from the VCS operation log"
            done
      fi
      if [[ -f "$preserve_dir/deleted" ]]; then
        while IFS= read -r rel; do
          [[ -z "$rel" ]] && continue
          rm -f "$wc_worktree/$rel" 2>/dev/null || true
        done < "$preserve_dir/deleted"
      fi
    fi
    rm -rf "$preserve_dir"
  fi

  # Remove the in-progress line from history
  if [[ -f "$history_file" ]]; then
    _history__delete_lines "$history_file" "${before_op}:"
  fi

  # The transaction is closed: clear the abort trap, and with it every trace
  # that would make a later sub-command believe it is running inside one.
  trap - ERR EXIT
  unset _TT_TRANSACTION_OWNER
  unset TT_TRANSACTION_ID
}
