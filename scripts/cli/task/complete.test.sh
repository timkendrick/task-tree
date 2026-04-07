#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"

test_task_complete__complete_current_task() {
  setup_workspace "done-current"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(complete_task) || exit_code=$?
  assert_success "complete succeeds" "$exit_code"
  assert_task_status "DONE" "$task_id" "DONE"
  assert_commit_message "commit has Complete" "@-" "Complete"
  assert_wc_clean "WC clean"
}


test_task_complete__explicit_task_id_cross_branch() {
  setup_workspace "done-cross"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task complete "$task_id" 2>&1) || exit_code=$?
  assert_success "cross-branch complete" "$exit_code"
  assert_task_status "DONE on branch" "$task_id" "DONE"
  assert_current_task "WC on parent" "$proj_id"
}


test_task_complete__already_done_is_no_op() {
  setup_workspace "done-already"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")

  output="" exit_code=0
  output=$(complete_task) || exit_code=$?
  assert_success "second complete succeeds" "$exit_code"
  assert_contains "already DONE" "$output" "DONE"
  bm_after=$(get_bookmark_commit "$task_id")
  assert_eq "bookmark unchanged" "$bm_before" "$bm_after"
}


test_task_complete__incomplete_subtasks_fails_without_force() {
  setup_workspace "done-subtasks"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  parent=$(create_task "parent" "P") || true
  checkout_task "$parent" >/dev/null || true
  child_a=$(create_task "ca" "CA") || true
  child_b=$(create_task "cb" "CB") || true
  run_tt task complete "$child_a" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task complete "$parent" 2>&1) || exit_code=$?
  assert_failure "incomplete subtasks rejected" "$exit_code"

  exit_code=0
  output=$(run_tt task complete "$parent" --force 2>&1) || exit_code=$?
  assert_success "--force succeeds" "$exit_code"
  assert_task_status "parent DONE" "$parent" "DONE"
}


test_task_complete__records_transaction() {
  setup_workspace "done-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  complete_task >/dev/null || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after complete"
}


test_task_complete__help() {
  setup_workspace "complete-help"
  output="" exit_code=0
  output=$(run_tt task complete --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task complete"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_required_usage_argument "argument: --force" "$output" "--force"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task complete"
