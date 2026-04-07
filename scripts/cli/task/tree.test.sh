#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_tree__basic_tree_output() {
  setup_workspace "tree-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child_a=$(create_task "ca" "Child A") || true
  checkout_task "$proj_id" >/dev/null || true
  child_b=$(create_task "cb" "Child B") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task tree 2>&1) || exit_code=$?
  assert_success "tree succeeds" "$exit_code"
  assert_contains "project in output" "$output" "project/proj-"
  assert_contains "child A in output" "$output" "Child A"
  assert_contains "child B in output" "$output" "Child B"
}


test_task_tree__focus_shows_current_chain() {
  setup_workspace "tree-focus"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child") || true
  checkout_task "$child" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task tree --focus 2>&1) || exit_code=$?
  assert_success "focus succeeds" "$exit_code"
  assert_contains "project in chain" "$output" "project/proj-"
  assert_contains "child in chain" "$output" "Child"
  # Current task is bold-formatted
  assert_contains "current task bold" "$output" "**"
}


test_task_tree__project_filter() {
  setup_workspace "tree-filter"
  proj_a=$(create_project "a" "Proj A") || true
  proj_b=$(create_project "b" "Proj B") || true

  output="" exit_code=0
  output=$(run_tt task tree --project "$proj_a" 2>&1) || exit_code=$?
  assert_success "filter succeeds" "$exit_code"
  assert_contains "proj A shown" "$output" "Proj A"
  assert_not_contains "proj B hidden" "$output" "Proj B"
}


test_task_tree__completed_subtask_with_x() {
  setup_workspace "tree-done"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "Task") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task tree 2>&1) || exit_code=$?
  assert_success "tree succeeds" "$exit_code"
  assert_contains "completed checkbox [x]" "$output" "[x]"
}


test_task_tree__empty_project_no_subtasks() {
  setup_workspace "tree-empty"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt task tree 2>&1) || exit_code=$?
  assert_success "tree succeeds" "$exit_code"
  assert_contains "project in output" "$output" "project/proj-"
}


test_task_tree__focus_with_no_current_branch_fails() {
  setup_workspace "tree-nofocus"
  # On main by default
  output="" exit_code=0
  output=$(run_tt task tree --focus 2>&1) || exit_code=$?
  assert_failure "focus without current fails" "$exit_code"
}


test_task_tree__help() {
  setup_workspace "tree-help"
  output="" exit_code=0
  output=$(run_tt task tree --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task tree"
  assert_optional_usage_argument "argument: --project" "$output" "--project"
  assert_optional_usage_argument "argument: --detached" "$output" "--detached"
  assert_optional_usage_argument "argument: --all" "$output" "--all"
  assert_optional_usage_argument "argument: --focus" "$output" "--focus"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task tree"
