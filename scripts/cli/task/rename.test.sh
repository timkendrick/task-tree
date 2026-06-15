#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_rename__basic_rename() {
  setup_workspace "rename-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "old-name" "Old Task" "Task body") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task rename --slug "new-name" 2>&1) || exit_code=$?
  assert_success "rename succeeds" "$exit_code"
  assert_contains "output has rename message" "$output" "new-name"

  # Old bookmark gone
  old_hex="${task_id#task/old-name-}"
  old_id="task/old-name-${old_hex}"
  assert_bookmark_not_exists "old bookmark gone" "$old_id"

  # New bookmark exists
  new_id="task/new-name-${old_hex}"
  assert_bookmark_exists "new bookmark exists" "$new_id"
  assert_task_title "title preserved" "$new_id" "Old Task"
  assert_task_body_contains "body preserved" "$new_id" "Task body"
}


test_task_rename__same_slug_is_no_op() {
  setup_workspace "rename-same"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "same" "Same Task") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")

  output="" exit_code=0
  output=$(run_tt task rename --slug "same" 2>&1) || exit_code=$?
  assert_success "same slug succeeds" "$exit_code"
  bm_after=$(get_bookmark_commit "$task_id")
  assert_eq "bookmark unchanged" "$bm_before" "$bm_after"
}


test_task_rename__invalid_slug_rejected() {
  setup_workspace "rename-invalid"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task rename --slug "UPPERCASE" 2>&1) || exit_code=$?
  assert_failure "invalid slug rejected" "$exit_code"
}


test_task_rename__dirty_wc_rejected() {
  setup_workspace "rename-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  edit_file "dirty.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt task rename --slug "new" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
}


test_task_rename__parent_subtask_entry_updated() {
  setup_workspace "rename-parent"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "child" "Child") || true
  checkout_task "$task_id" >/dev/null || true

  run_tt task rename --slug "renamed" >/dev/null 2>&1 || true

  old_hex="${task_id#task/child-}"
  new_id="task/renamed-${old_hex}"
  assert_subtask_entry "parent subtask updated" "$proj_id" "$new_id" "[ ]"
  assert_no_subtask_entry "old subtask removed" "$proj_id" "$task_id"
}


test_task_rename__preserves_task_file_content() {
  setup_workspace "rename-preserve"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(run_tt task create --slug "t" --title "T" --label "bug" <<< "Body text" 2>/dev/null | tail -1) || true
  checkout_task "$task_id" >/dev/null || true

  run_tt task rename --slug "renamed" >/dev/null 2>&1 || true

  old_hex="${task_id#task/t-}"
  new_id="task/renamed-${old_hex}"
  assert_task_title "title preserved" "$new_id" "T"
  assert_task_body_contains "body preserved" "$new_id" "Body text"
  assert_task_label "label preserved" "$new_id" "bug"
  assert_task_status "status preserved" "$new_id" "IN-PROGRESS"
}


test_task_rename__records_transaction() {
  setup_workspace "rename-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task rename --slug "renamed" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after rename"
}


test_task_rename__help() {
  setup_workspace "rename-help"
  output="" exit_code=0
  output=$(run_tt task rename --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task rename"
  assert_required_usage_argument "argument: --slug" "$output" "--slug"
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task rename"
