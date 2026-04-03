#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"

test_task_checkpoint__basic_with_message() {
  setup_workspace "cp-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(checkpoint_task "Test cp") || exit_code=$?
  assert_success "checkpoint succeeds" "$exit_code"
  assert_commit_message "commit has Checkpoint" "@-" "Checkpoint"
  assert_wc_clean "WC clean after checkpoint"
}


test_task_checkpoint__with_file_changes() {
  setup_workspace "cp-files"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  edit_file "src/main.sh" "echo hello"
  checkpoint_task "File cp" >/dev/null || true
  modified="$(get_modified_files "@-")"
  assert_contains "file committed" "$modified" "src/main.sh"
  assert_wc_clean "WC clean"
}


test_task_checkpoint__empty_wc_still_commits() {
  setup_workspace "cp-empty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")
  checkpoint_task "Empty cp" >/dev/null || true
  bm_after=$(get_bookmark_commit "$task_id")
  assert_neq "bookmark advanced" "$bm_before" "$bm_after"
}


test_task_checkpoint__not_on_task_branch_fails() {
  setup_workspace "cp-notask"
  output="" exit_code=0
  output=$(checkpoint_task "Should fail") || exit_code=$?
  assert_failure "checkpoint on non-task fails" "$exit_code"
}


test_task_checkpoint__multiple_sequential() {
  setup_workspace "cp-multi"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  get_history_lines; hc_before="${#HISTORY_LINES[@]}"

  checkpoint_task "First" >/dev/null || true
  checkpoint_task "Second" >/dev/null || true

  get_history_lines
  assert_eq "two new entries" "$((${#HISTORY_LINES[@]} - hc_before))" "2"
  assert_history_integrity "history after 2 checkpoints"
}


run_tests "tt task checkpoint"
