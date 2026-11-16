#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_history_undo__undo_last_command() {
  setup_workspace "undo-basic"
  proj_id=$(create_project "proj" "Project") || true

  assert_bookmark_exists "project exists before undo" "$proj_id"

  output="" exit_code=0
  output=$(run_tt history undo 2>&1) || exit_code=$?
  assert_success "undo succeeds" "$exit_code"
  assert_bookmark_not_exists "project gone after undo" "$proj_id"
}


test_history_undo__multiple_sequential_undos() {
  setup_workspace "undo-multi"
  proj_id=$(create_project "proj" "Project") || true
  task_id=$(create_task_under "$proj_id" "t" "T") || true

  assert_bookmark_exists "project exists" "$proj_id"
  assert_bookmark_exists "task exists" "$task_id"

  # Undo task create (no checkout in between, so this is the most recent entry)
  run_tt history undo >/dev/null 2>&1 || true
  assert_bookmark_exists "project still exists after first undo" "$proj_id"
  assert_bookmark_not_exists "task gone after first undo" "$task_id"

  # Undo project create
  run_tt history undo >/dev/null 2>&1 || true
  assert_bookmark_not_exists "project gone after second undo" "$proj_id"
}


test_history_undo__history_chain_integrity_after_undo() {
  setup_workspace "undo-chain"
  proj_id=$(create_project "proj" "Project") || true
  task_id=$(create_task_under "$proj_id" "t" "T") || true

  run_tt history undo >/dev/null 2>&1 || true
  assert_history_integrity "history integrity after undo"
}


test_history_undo__dirty_wc_fails() {
  setup_workspace "undo-dirty"
  proj_id=$(create_project "proj" "Project") || true
  edit_file "dirty.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt history undo 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
}


test_history_undo__empty_history() {
  setup_workspace "undo-empty"
  output="" exit_code=0
  output=$(run_tt history undo 2>&1) || exit_code=$?
  assert_failure "empty history rejected" "$exit_code"
  assert_contains "nothing to undo" "$output" "Nothing to undo"
}


test_history_undo__preserves_outgoing_op_id_in_output() {
  setup_workspace "undo-opid"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt history undo 2>&1) || exit_code=$?
  assert_success "undo succeeds" "$exit_code"
  assert_contains "names the outgoing operation" "$output" "Outgoing operation"
}


test_history_undo__undo_with_force_bypasses_dirty_wc() {
  setup_workspace "undo-force"
  proj_id=$(create_project "proj" "Project") || true
  edit_file "dirty.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt history undo --force 2>&1) || exit_code=$?
  assert_success "force undo succeeds" "$exit_code"
  assert_bookmark_not_exists "project gone after force undo" "$proj_id"
}


# Usage: open_transaction
# Runs `tt history lock` and prints the key it returns.
open_transaction() {
  run_tt history lock 2>/dev/null
}


test_history_undo__key_reverts_transaction() {
  setup_workspace "undo-key"
  base_id=$(create_project "base" "Base") || true
  key="$(open_transaction)"
  proj_id=$( export TT_TRANSACTION_ID="$key"; create_project "proj" "Project" ) || true
  assert_bookmark_exists "the project was created" "$proj_id"

  output="" exit_code=0
  output=$(run_tt history undo --key "$key" 2>&1) || exit_code=$?
  assert_success "undo --key succeeds" "$exit_code"
  assert_contains "reports the revert" "$output" "Undone: transaction reverted"
  assert_bookmark_not_exists "the transaction is reverted" "$proj_id"
  assert_bookmark_exists "work before the transaction is kept" "$base_id"
  assert_history_count "the transaction entry is removed" 1
  assert_history_integrity "the history is complete and current"
}


test_history_undo__key_keeps_uncommitted_changes() {
  setup_workspace "undo-key-dirty"
  edit_file "before.txt" "before"
  key="$(open_transaction)"
  ( export TT_TRANSACTION_ID="$key"; create_project "proj" "Project" >/dev/null ) || true
  edit_file "during.txt" "during"
  edit_file "before.txt" "changed"

  output="" exit_code=0
  output=$(run_tt history undo --key "$key" 2>&1) || exit_code=$?
  assert_success "undo --key succeeds with a dirty working copy" "$exit_code"
  assert_eq "a file edited before the lock is kept" "$(cat "$REPO/before.txt")" "changed"
  assert_eq "a file created during the transaction is kept" "$(cat "$REPO/during.txt")" "during"
}


test_history_undo__key_mismatch_fails() {
  setup_workspace "undo-key-mismatch"
  key="$(open_transaction)"
  proj_id=$( export TT_TRANSACTION_ID="$key"; create_project "proj" "Project" ) || true

  output="" exit_code=0
  output=$(run_tt history undo --key "not-the-key" 2>&1) || exit_code=$?
  assert_failure "undo --key exits 1 on a mismatch" "$exit_code"
  assert_contains "reports the mismatch" "$output" \
    "Error: The key does not match the transaction in progress."
  assert_bookmark_exists "nothing is reverted" "$proj_id"
  get_history_lines
  assert_eq "the entry is still in progress" "${HISTORY_LINES[0]}" "${key}:"
}


test_history_undo__key_without_transaction_fails() {
  setup_workspace "undo-key-none"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt history undo --key "some-key" 2>&1) || exit_code=$?
  assert_failure "undo --key exits 1 with no transaction in progress" "$exit_code"
  assert_contains "reports no transaction" "$output" "Error: No transaction is in progress."
  assert_bookmark_exists "nothing is reverted" "$proj_id"
}


test_history_undo__key_with_force_fails() {
  setup_workspace "undo-key-force"
  key="$(open_transaction)"

  output="" exit_code=0
  output=$(run_tt history undo --force --key "$key" 2>&1) || exit_code=$?
  assert_failure "--force and --key are rejected together" "$exit_code"
  assert_contains "reports the conflict" "$output" "Error: --force and --key cannot be combined."
  assert_history_count "the entry is kept" 1
}


test_history_undo__help() {
  setup_workspace "undo-help"
  output="" exit_code=0
  output=$(run_tt history undo --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt history undo"
  assert_required_usage_argument "argument: --force" "$output" "--force"
  assert_required_usage_argument "argument: --key" "$output" "--key"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt history undo"
