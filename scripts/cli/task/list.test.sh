#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_task_list__lists_active_tasks_and_projects_sorted() {
  setup_workspace "list-sorted"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_z=$(create_task "zzz" "Task Z") || true
  checkout_task "$proj_id" || true
  task_a=$(create_task "aaa" "Task A") || true

  output="" exit_code=0
  output=$(run_tt task list 2>/dev/null) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_eq "IDs sorted, one per line" "$output" \
    "$(printf '%s\n' "$proj_id" "$task_z" "$task_a" | LC_ALL=C sort)"
}


test_task_list__done_tasks_only_with_all() {
  setup_workspace "list-done"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  done_task=$(create_task "done-task" "Done Task") || true
  checkout_task "$done_task" || true
  complete_task >/dev/null || true
  checkout_task "$proj_id" || true
  active_task=$(create_task "active" "Active Task") || true

  output=""
  output=$(run_tt task list 2>/dev/null) || true
  assert_contains "active task listed" "$output" "$active_task"
  assert_not_contains "done task hidden" "$output" "$done_task"

  output=$(run_tt task list --all 2>/dev/null) || true
  assert_contains "active task listed with --all" "$output" "$active_task"
  assert_contains "done task listed with --all" "$output" "$done_task"
}


test_task_list__checked_in_task_without_bookmark_listed_with_all() {
  setup_workspace "list-no-bookmark"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Task") || true
  checkout_task "$task_id" || true
  checkin_task --complete >/dev/null || true
  checkout_task "$proj_id" || true
  jj -R "$REPO" bookmark delete "$task_id" >/dev/null 2>&1

  output=""
  output=$(run_tt task list 2>/dev/null) || true
  assert_not_contains "done task hidden" "$output" "$task_id"
  output=$(run_tt task list --all 2>/dev/null) || true
  assert_contains "done task listed with --all" "$output" "$task_id"
}


test_task_list__unreadable_task_listed_with_warning() {
  setup_workspace "list-unreadable"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Task") || true
  jj -R "$REPO" bookmark delete "$task_id" >/dev/null 2>&1

  local err="$_TEST_ROOT/list-err.txt" output="" exit_code=0
  output=$(run_tt task list 2>"$err") || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "unreadable task listed as active" "$output" "$task_id"
  assert_contains "warning names the task" "$(cat "$err")" \
    "Warning: Cannot read the task file of '$task_id'."
}


test_task_list__no_tasks_prints_nothing() {
  setup_workspace "list-empty"

  output="" exit_code=0
  output=$(run_tt task list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_output_empty "nothing printed" "$output"
}


test_task_list__alias() {
  setup_workspace "list-alias"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt list 2>/dev/null) || exit_code=$?
  assert_success "alias succeeds" "$exit_code"
  assert_eq "alias lists the project" "$output" "$proj_id"
}


test_task_list__help() {
  setup_workspace "list-help"
  output="" exit_code=0
  output=$(run_tt task list --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task list"
  assert_optional_usage_argument "argument: --all" "$output" "--all"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task list"
