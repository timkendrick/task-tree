#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


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
  assert_contains "shows op restore command" "$output" "jj op restore"
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


run_tests "tt history undo"
