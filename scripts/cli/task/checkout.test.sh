#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"

test_task_checkout__basic_checkout_of_todo_task() {
  setup_workspace "checkout-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  assert_task_status "TODO before checkout" "$task_id" "TODO"

  output="" exit_code=0
  output=$(checkout_task "$task_id") || exit_code=$?
  assert_success "checkout succeeds" "$exit_code"
  assert_task_status "IN-PROGRESS after checkout" "$task_id" "IN-PROGRESS"
  assert_current_task "WC on task branch" "$task_id"
  assert_wc_clean "WC clean after checkout"
}


test_task_checkout__already_in_progress_is_no_op() {
  setup_workspace "checkout-inprogress"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(run_tt task create --slug "mytask" --title "My Task" --checkout <<< "" | tail -1) || true
  assert_task_status "IN-PROGRESS" "$task_id" "IN-PROGRESS"

  checkout_task "$proj_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")
  checkout_task "$task_id" >/dev/null || true
  bm_after=$(get_bookmark_commit "$task_id")
  assert_eq "no new Begin commit" "$bm_before" "$bm_after"
}


test_task_checkout__dirty_wc_rejected() {
  setup_workspace "checkout-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  edit_file "dirty.txt" "dirty"
  output="" exit_code=0
  output=$(checkout_task "$task_id" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
}


test_task_checkout__dirty_wc_with_force() {
  setup_workspace "checkout-dirty-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  edit_file "dirty.txt" "dirty"
  output="" exit_code=0
  output=$(run_tt task checkout "$task_id" --force 2>&1) || exit_code=$?
  assert_success "checkout --force succeeds" "$exit_code"
}


test_task_checkout__invalid_task_id_rejected() {
  setup_workspace "checkout-invalid"
  output="" exit_code=0
  output=$(run_tt task checkout "not-a-task" 2>&1) || exit_code=$?
  assert_failure "invalid task ID rejected" "$exit_code"
}


test_task_checkout__non_existent_bookmark_rejected() {
  setup_workspace "checkout-noexist"
  output="" exit_code=0
  output=$(run_tt task checkout "task/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent bookmark rejected" "$exit_code"
}


test_task_checkout__records_transaction() {
  setup_workspace "checkout-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  checkout_task "$task_id" >/dev/null || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history integrity after checkout"
}


run_tests "tt task checkout"
