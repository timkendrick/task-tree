#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_move__basic_reparenting() {
  setup_workspace "move-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "Task A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "Task B") || true
  checkout_task "$proj_id" >/dev/null || true

  # Move B under A
  output="" exit_code=0
  output=$(run_tt task move --task "$task_b" --parent "$task_a" 2>&1) || exit_code=$?
  assert_success "move succeeds" "$exit_code"

  # Old parent (project) no longer has B
  assert_no_subtask_entry "old parent loses subtask" "$proj_id" "$task_b"
  # New parent (A) now has B
  assert_subtask_entry "new parent gains subtask" "$task_a" "$task_b" "[ ]"
  # B is VCS descendant of A
  assert_is_ancestor "B descends from A" "$task_a" "$task_b"
}


test_task_move__cycle_detection() {
  setup_workspace "move-cycle"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  parent=$(create_task "p" "Parent") || true
  checkout_task "$parent" >/dev/null || true
  child=$(create_task "c" "Child") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task move --task "$parent" --parent "$child" 2>&1) || exit_code=$?
  assert_failure "cycle detected" "$exit_code"
}


test_task_move__same_parent_is_error() {
  setup_workspace "move-same"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task move --task "$task_id" --parent "$proj_id" 2>&1) || exit_code=$?
  assert_failure "same parent rejected" "$exit_code"
}


test_task_move__parentless_task_cannot_be_moved() {
  setup_workspace "move-parentless"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt task move --task "$proj_id" --parent "main" 2>&1) || exit_code=$?
  assert_failure "parentless move rejected" "$exit_code"
}


test_task_move__dirty_wc_rejected() {
  setup_workspace "move-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  checkout_task "$proj_id" >/dev/null || true
  edit_file "dirty.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt task move --task "$task_b" --parent "$task_a" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
}


test_task_move__wc_on_old_parent_stays_on_old_parent() {
  setup_workspace "move-wc-old"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  checkout_task "$proj_id" >/dev/null || true

  run_tt task move --task "$task_b" --parent "$task_a" >/dev/null 2>&1 || true
  assert_current_task "WC on old parent" "$proj_id"
}


test_task_move__records_transaction() {
  setup_workspace "move-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  checkout_task "$proj_id" >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task move --task "$task_b" --parent "$task_a" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after move"
}


test_task_move__no_conflicts_after_reparent() {
  setup_workspace "move-noconflict"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  checkout_task "$proj_id" >/dev/null || true

  run_tt task move --task "$task_b" --parent "$task_a" >/dev/null 2>&1 || true
  assert_no_conflicts "no conflicts after move"
}


run_tests "tt task move"
