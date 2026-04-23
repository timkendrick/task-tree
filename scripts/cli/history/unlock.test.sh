#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


# Helper: inject a stale (in-progress) transaction entry into .tt/history.
# Prints the before-op ID that was injected.
inject_pending_transaction() {
  local before_op
  before_op="$(get_jj_op)"
  printf '%s:\n' "$before_op" >> "$REPO/.tt/history"
  printf '%s' "$before_op"
}


test_history_unlock__no_transaction_is_silent_noop() {
  setup_workspace "unlock-noop"
  create_project "proj" "Project" >/dev/null 2>&1

  local output="" exit_code=0
  output=$(run_tt history unlock 2>&1) || exit_code=$?
  assert_success "unlock succeeds" "$exit_code"
  assert_output_empty "unlock is silent" "$output"
  assert_no_pending_transaction "no pending transaction after unlock"
}


test_history_unlock__no_transaction_with_force_is_silent_noop() {
  setup_workspace "unlock-noop-force"
  create_project "proj" "Project" >/dev/null 2>&1

  local output="" exit_code=0
  output=$(run_tt history unlock --force 2>&1) || exit_code=$?
  assert_success "unlock --force succeeds" "$exit_code"
  assert_output_empty "unlock --force is silent when no lock" "$output"
}


test_history_unlock__empty_history_is_silent_noop() {
  setup_workspace "unlock-empty"
  # No commands run: history file is empty

  local output="" exit_code=0
  output=$(run_tt history unlock 2>&1) || exit_code=$?
  assert_success "unlock exits 0 on empty history" "$exit_code"
  assert_output_empty "unlock is silent on empty history" "$output"
}


test_history_unlock__missing_history_exits_error() {
  setup_workspace "unlock-missing"
  rm -f "$REPO/.tt/history"

  local output="" exit_code=0
  output=$(run_tt history unlock 2>&1) || exit_code=$?
  assert_failure "unlock exits 1 on missing history" "$exit_code"
  assert_contains "error message mentions history file" "$output" "History file not found"
}


test_history_unlock__in_progress_without_force_exits_error() {
  setup_workspace "unlock-no-force"
  create_project "proj" "Project" >/dev/null 2>&1
  inject_pending_transaction >/dev/null

  local output="" exit_code=0
  output=$(run_tt history unlock 2>&1) || exit_code=$?
  assert_failure "unlock exits 1 without --force" "$exit_code"
  assert_contains "error mentions --force" "$output" "--force"
  assert_contains "error mentions undo" "$output" "tt history undo --force"
}


test_history_unlock__force_clears_pending_transaction() {
  setup_workspace "unlock-force"
  create_project "proj" "Project" >/dev/null 2>&1
  inject_pending_transaction >/dev/null

  local output="" exit_code=0
  output=$(run_tt history unlock --force 2>&1) || exit_code=$?
  assert_success "unlock --force succeeds" "$exit_code"
  assert_no_pending_transaction "no pending transaction after unlock --force"
}


test_history_unlock__force_sets_after_to_current_op() {
  setup_workspace "unlock-entry"
  create_project "proj" "Project" >/dev/null 2>&1
  local before_op
  before_op="$(inject_pending_transaction)"

  # Capture the current jj op ID (which unlock --force will use as after-op)
  local current_op
  current_op="$(get_jj_op)"

  run_tt history unlock --force >/dev/null 2>&1

  # Read the last history line and verify before preserved, after == current jj op
  get_history_lines
  local last_line="${HISTORY_LINES[${#HISTORY_LINES[@]}-1]}"
  local entry_before entry_after
  entry_before="$(history_before_op "$last_line")"
  entry_after="$(history_after_op "$last_line")"
  assert_eq "before-op preserved" "$entry_before" "$before_op"
  assert_eq "after-op equals current jj op" "$entry_after" "$current_op"
}


test_history_unlock__force_unblocks_subsequent_commands() {
  setup_workspace "unlock-unblock"
  local proj_id
  proj_id=$(create_project "proj" "Project")
  inject_pending_transaction >/dev/null

  run_tt history unlock --force >/dev/null 2>&1

  # A subsequent tt command should be able to start a new transaction
  local output="" exit_code=0
  output=$(run_tt task create --parent "$proj_id" --slug "new" --title "New Task" <<< "" 2>&1) || exit_code=$?
  assert_success "subsequent command succeeds after unlock" "$exit_code"
}


test_history_unlock__jj_state_unchanged_after_force() {
  setup_workspace "unlock-jj-unchanged"

  create_project "proj" "Project" >/dev/null 2>&1

  local after_create_op
  after_create_op="$(get_jj_op)"

  inject_pending_transaction >/dev/null

  run_tt history unlock --force >/dev/null 2>&1

  local current_op
  current_op="$(get_jj_op)"
  assert_eq "jj state unchanged after unlock" "$current_op" "$after_create_op"
}


test_history_unlock__help() {
  setup_workspace "unlock-help"
  local output="" exit_code=0
  output=$(run_tt history unlock --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt history unlock"
  assert_required_usage_argument "argument: --force" "$output" "--force"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt history unlock"
