#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_workspace_branch__valid_task_id() {
  setup_workspace "branch-valid"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true

  output="" exit_code=0
  output=$(run_tt workspace branch "$task_id" 2>&1) || exit_code=$?
  assert_success "branch lookup succeeds" "$exit_code"
  assert_eq "stdout is task ID" "$output" "$task_id"
}


test_workspace_branch__valid_project_id() {
  setup_workspace "branch-project"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt workspace branch "$proj_id" 2>&1) || exit_code=$?
  assert_success "branch project lookup succeeds" "$exit_code"
  assert_eq "stdout is project ID" "$output" "$proj_id"
}


test_workspace_branch__non_existent_bookmark() {
  setup_workspace "branch-noexist"
  output="" exit_code=0
  output=$(run_tt workspace branch "task/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent bookmark rejected" "$exit_code"
}


test_workspace_branch__invalid_format() {
  setup_workspace "branch-invalid"
  output="" exit_code=0
  output=$(run_tt workspace branch "not-a-task" 2>&1) || exit_code=$?
  assert_failure "invalid format rejected" "$exit_code"
}


run_tests "tt workspace branch"
