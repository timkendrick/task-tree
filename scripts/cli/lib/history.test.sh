#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for transaction history management in lib/history.sh
# ---------------------------------------------------------------------------

test__history__transaction__begin_commit_round_trip() {
  setup_workspace "history-begin-commit"

  local before_op
  before_op="$(get_jj_op)"

  (
    unset TT_TRANSACTION_ID
    _history__begin_transaction "$REPO"
    edit_file "$REPO/work.txt" "work"
    jj_commit "history txn work"
    _history__commit_transaction "$REPO"
  )

  get_history_lines
  assert_eq "exactly one completed entry recorded" "${#HISTORY_LINES[@]}" "1"
  local entry="${HISTORY_LINES[0]}"
  assert_eq "before-op captured at begin" "$(history_before_op "$entry")" "$before_op"
  assert_eq "after-op is the current jj op" "$(history_after_op "$entry")" "$(get_jj_op)"
  assert_no_pending_transaction "entry is completed (non-empty after-op)"
}

test__history__transaction__begin_refuses_in_progress() {
  setup_workspace "history-begin-locked"

  # Simulate a crashed process: an in-progress entry with an empty after-op-id.
  printf '%s:\n' "deadbeefdeadbeef" >> "$REPO/.tt/history"

  local out exit_code=0
  out="$( (unset TT_TRANSACTION_ID; _history__begin_transaction "$REPO") 2>&1 )" || exit_code=$?
  assert_exit_code "begin aborts when a transaction is in progress" 1 "$exit_code"
  assert_contains "error names the incomplete transaction" "$out" \
    "Error: Another tt command is in progress (incomplete transaction)."
  assert_contains "suggests undo --force" "$out" \
    "To revert a crashed process: tt history undo --force"
  assert_contains "suggests unlock --force" "$out" \
    "Or to keep the current state: tt history unlock --force"
  assert_history_count "no new entry appended" 1
}

test__history__transaction__rollback_restores_op_and_removes_entry() {
  setup_workspace "history-rollback"

  (
    unset TT_TRANSACTION_ID
    _history__begin_transaction "$REPO"
    edit_file "$REPO/rollback.txt" "x"
    jj_commit "history txn rollback"
    _history__rollback_transaction "$REPO" 2>/dev/null
  )

  local descriptions
  descriptions="$(get_commit_message 'all()')"
  assert_not_contains "rolled-back commit is gone from the op state" \
    "$descriptions" "history txn rollback"
  assert_history_count "in-progress line removed from history" 0
}

test__history__transaction__begin_snapshots_working_copy() {
  setup_workspace "history-snapshot"

  # Capture the op ID BEFORE creating the pending file: the harness helper
  # itself snapshots the working copy, so calling it with the file already on
  # disk would fold the file into a snapshot op of its own.
  local before_op
  before_op="$(get_jj_op)"
  # A file jj has never snapshotted: only the transaction's own snapshot can
  # capture it into the working-copy commit.
  edit_file "$REPO/pending.txt" "pending"

  (
    unset TT_TRANSACTION_ID
    _history__begin_transaction "$REPO"
    # The before-op ID must be recorded ahead of the snapshot, so that
    # undoing the transaction also reverts the snapshot operation.
    get_history_lines
    assert_eq "before-op recorded is the pre-snapshot op" \
      "$(history_before_op "${HISTORY_LINES[${#HISTORY_LINES[@]}-1]}")" \
      "$before_op"
    assert_neq "snapshot advanced the op log inside the transaction" \
      "$(get_jj_op)" "$before_op"
    assert_contains "pending file captured in the working-copy commit" \
      "$(jj -R "$REPO" --ignore-working-copy diff -r '@' --name-only 2>/dev/null)" \
      "pending.txt"
    _history__rollback_transaction "$REPO" 2>/dev/null
  )

  # Rollback restores the pre-transaction state, but the user's uncommitted
  # work survives: the file stays on disk (re-applied onto the restored
  # working-copy commit rather than stripped by the operation restore).
  assert_file_exists "pending file still on disk after rollback" "$REPO/pending.txt"
  assert_eq "pending content intact after rollback" \
    "$(cat "$REPO/pending.txt")" "pending"
  assert_history_count "in-progress line removed by rollback" 0
}

test__history__transaction__nested_begin_is_noop() {
  setup_workspace "history-nested"

  local exit_code=0
  ( export TT_TRANSACTION_ID="already-set"; _history__begin_transaction "$REPO" ) || exit_code=$?
  assert_success "nested begin returns 0" "$exit_code"
  assert_history_count "nested begin appends no entry" 0
}

run_tests "tt lib/history (unit)"
