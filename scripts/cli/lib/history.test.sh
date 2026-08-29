#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

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
  descriptions="$(jj -R "$REPO" log -r 'all()' --no-graph \
    -T 'description.first_line() ++ "\n"' 2>/dev/null)"
  assert_not_contains "rolled-back commit is gone from the op state" \
    "$descriptions" "history txn rollback"
  assert_history_count "in-progress line removed from history" 0
}

test__history__transaction__nested_begin_is_noop() {
  setup_workspace "history-nested"

  local exit_code=0
  ( export TT_TRANSACTION_ID="already-set"; _history__begin_transaction "$REPO" ) || exit_code=$?
  assert_success "nested begin returns 0" "$exit_code"
  assert_history_count "nested begin appends no entry" 0
}

run_tests "tt lib/history (unit)"
