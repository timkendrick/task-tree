#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"

test_task_edit__edit_title() {
  setup_workspace "edit-title"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  run_tt task edit --title "Updated Title" <<< "" >/dev/null 2>&1 || true
  assert_task_title "title updated" "$task_id" "Updated Title"
  assert_commit_message "commit has Edit" "@-" ":edit]"
}


test_task_edit__edit_body_from_stdin() {
  setup_workspace "edit-body"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T" "Original") || true
  checkout_task "$task_id" >/dev/null || true

  echo "New body" | run_tt task edit >/dev/null 2>&1 || true
  assert_task_body_contains "body updated" "$task_id" "New body"
}


test_task_edit__add_labels() {
  setup_workspace "edit-labels"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  run_tt task edit --label "bug" --label "urgent" <<< "" >/dev/null 2>&1 || true
  assert_task_label "bug" "$task_id" "bug"
  assert_task_label "urgent" "$task_id" "urgent"
}


test_task_edit__delete_label() {
  setup_workspace "edit-dellabel"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(run_tt task create --slug "t" --title "T" --label "bug" --label "keep" <<< "" | tail -1) || true
  checkout_task "$task_id" >/dev/null || true

  run_tt task edit --delete-label "bug" <<< "" >/dev/null 2>&1 || true
  assert_task_no_label "bug removed" "$task_id" "bug"
  assert_task_label "keep preserved" "$task_id" "keep"
}


test_task_edit__cross_branch_edit() {
  setup_workspace "edit-cross"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "A") || true
  task_b=$(create_task "tb" "B") || true
  checkout_task "$task_a" >/dev/null || true

  run_tt task edit "$task_b" --title "Updated B" <<< "" >/dev/null 2>&1 || true
  assert_task_title "b updated" "$task_b" "Updated B"
  assert_current_task "WC on a" "$task_a"
}


test_task_edit__no_op_edit() {
  setup_workspace "edit-noop"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")

  # No stdin redirect: only --title with the same value, no body change
  run_tt task edit --title "T" </dev/null >/dev/null 2>&1 || true
  bm_after=$(get_bookmark_commit "$task_id")
  assert_eq "bookmark unchanged" "$bm_before" "$bm_after"
}


test_task_edit__records_transaction() {
  setup_workspace "edit-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task edit --title "New" <<< "" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after edit"
}


test_task_edit__help() {
  setup_workspace "edit-help"
  output="" exit_code=0
  output=$(run_tt task edit --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task edit"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_optional_usage_argument "argument: --title" "$output" "--title"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task edit"
