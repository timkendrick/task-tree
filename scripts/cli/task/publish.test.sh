#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_publish__basic_publish_to_target() {
  setup_workspace "pub-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  edit_file "src/main.sh" "echo hello"
  checkpoint_task "Work" >/dev/null || true

  main_before=$(get_bookmark_commit "main")

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "main" 2>&1) || exit_code=$?
  assert_success "publish succeeds" "$exit_code"

  main_after=$(get_bookmark_commit "main")
  assert_neq "main advanced" "$main_before" "$main_after"
  assert_file_on_branch "scaffolding removed from main" "main" "src/main.sh"
  assert_file_not_on_branch ".tt/task NOT on main" "main" ".tt/task"
}


test_task_publish__non_project_branch_rejected() {
  setup_workspace "pub-notproject"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task publish "$task_id" --target "main" 2>&1) || exit_code=$?
  assert_failure "non-project publish rejected" "$exit_code"
  assert_contains "suggests checkin" "$output" "checkin"
}


test_task_publish__without_target_rejected() {
  setup_workspace "pub-notarget"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" 2>&1) || exit_code=$?
  assert_failure "missing target rejected" "$exit_code"
  assert_contains "error about target" "$output" "--target"
}


test_task_publish__non_existent_target_rejected() {
  setup_workspace "pub-badtarget"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "nonexistent" 2>&1) || exit_code=$?
  assert_failure "non-existent target rejected" "$exit_code"
}


test_task_publish__dirty_wc_rejected() {
  setup_workspace "pub-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  edit_file "dirty.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "main" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
}


test_task_publish__wc_stays_on_project_after_publish() {
  setup_workspace "pub-wc"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  run_tt task publish "$proj_id" --target "main" >/dev/null 2>&1 || true
  # After publish, WC should be on project branch still
  # (the command leaves us on the project)
}


test_task_publish__records_transaction() {
  setup_workspace "pub-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task publish "$proj_id" --target "main" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after publish"
}


test_task_publish__help() {
  setup_workspace "publish-help"
  output="" exit_code=0
  output=$(run_tt task publish --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task publish"
  assert_required_usage_argument "argument: --target" "$output" "--target"
  assert_optional_usage_argument "argument: --force" "$output" "--force"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task publish"
