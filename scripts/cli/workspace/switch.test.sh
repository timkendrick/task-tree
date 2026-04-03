#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_workspace_switch__invalid_task_id_rejected() {
  setup_workspace "switch-invalid"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt workspace switch "not-a-task-id" 2>&1) || exit_code=$?
  assert_failure "invalid task ID rejected" "$exit_code"
}


test_workspace_switch__non_existent_bookmark_rejected() {
  setup_workspace "switch-noexist"
  output="" exit_code=0
  output=$(run_tt workspace switch "task/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent bookmark rejected" "$exit_code"
}


run_tests "tt workspace switch"
