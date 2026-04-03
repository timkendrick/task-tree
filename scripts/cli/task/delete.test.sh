#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_delete__delete_completed_task() {
  setup_workspace "del-done"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true
  checkin_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$task_id" 2>&1) || exit_code=$?
  assert_success "delete succeeds" "$exit_code"
  assert_bookmark_not_exists "bookmark deleted" "$task_id"
  assert_no_subtask_entry "no subtask entry" "$proj_id" "$task_id"
}


test_task_delete__delete_task_with_descendants() {
  setup_workspace "del-tree"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  parent=$(create_task "parent" "P") || true
  checkout_task "$parent" >/dev/null || true
  child=$(create_task "child" "C") || true
  checkout_task "$child" >/dev/null || true
  grandchild=$(create_task "gc" "GC") || true

  # Complete all leaf-first (checkout each before completing)
  checkout_task "$grandchild" >/dev/null || true
  complete_task >/dev/null || true
  checkout_task "$child" >/dev/null || true
  complete_task --force >/dev/null || true
  checkout_task "$parent" >/dev/null || true
  complete_task --force >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$parent" 2>&1) || exit_code=$?
  assert_success "delete with descendants" "$exit_code"
  assert_bookmark_not_exists "parent bookmark deleted" "$parent"
  assert_bookmark_not_exists "child bookmark deleted" "$child"
  assert_bookmark_not_exists "grandchild bookmark deleted" "$grandchild"
}


test_task_delete__non_done_task_fails() {
  setup_workspace "del-notdone"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$task_id" 2>&1) || exit_code=$?
  assert_failure "non-DONE delete rejected" "$exit_code"
}


test_task_delete__non_done_with_force_succeeds() {
  setup_workspace "del-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$task_id" --force 2>&1) || exit_code=$?
  assert_success "--force delete succeeds" "$exit_code"
  assert_bookmark_not_exists "bookmark deleted" "$task_id"
}


test_task_delete__dirty_wc_fails() {
  setup_workspace "del-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true

  edit_file "dirty-file.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt task delete "$task_id" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
}


test_task_delete__parentless_task_fails() {
  setup_workspace "del-parentless"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$proj_id" 2>&1) || exit_code=$?
  assert_failure "parentless delete rejected" "$exit_code"
}


test_task_delete__records_transaction() {
  setup_workspace "del-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true
  checkin_task "$task_id" >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task delete "$task_id" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after delete"
}


run_tests "tt task delete"
