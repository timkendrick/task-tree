#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_parent__parent_of_a_task() {
  setup_workspace "parent-task"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task parent "$task_id" 2>&1) || exit_code=$?
  assert_success "parent succeeds" "$exit_code"
  assert_matches "output is project ID" "$output" "project/%proj%"
}


test_task_parent__parent_of_current_task_implicit() {
  setup_workspace "parent-implicit"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task parent 2>&1) || exit_code=$?
  assert_success "parent succeeds" "$exit_code"
  assert_matches "output is project ID" "$output" "project/%proj%"
}


test_task_parent__parent_of_project_no_parent() {
  setup_workspace "parent-project"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt task parent "$proj_id" 2>&1) || exit_code=$?
  assert_failure "no parent for project" "$exit_code"
}


test_task_parent__project_finds_ancestor_project() {
  setup_workspace "parent-ancestor"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  parent_task=$(create_task "pt" "Parent Task") || true
  checkout_task "$parent_task" >/dev/null || true
  child_task=$(create_task "ct" "Child Task") || true
  checkout_task "$child_task" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task parent --project "$child_task" 2>&1) || exit_code=$?
  assert_success "parent --project succeeds" "$exit_code"
  assert_matches "output is project ID" "$output" "project/%proj%"
}


test_task_parent__project_when_already_a_project() {
  setup_workspace "parent-already"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt task parent --project "$proj_id" 2>&1) || exit_code=$?
  assert_failure "no ancestor project for project" "$exit_code"
}


test_task_parent__help() {
  setup_workspace "parent-help"
  output="" exit_code=0
  output=$(run_tt task parent --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task parent"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_required_usage_argument "argument: --project" "$output" "--project"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task parent"
