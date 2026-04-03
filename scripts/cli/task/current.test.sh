#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_current__on_a_task_branch() {
  setup_workspace "current-task"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task current 2>&1) || exit_code=$?
  assert_success "current succeeds" "$exit_code"
  assert_matches "output is task ID" "$output" "task/%t%"
}


test_task_current__on_a_project_branch() {
  setup_workspace "current-project"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task current 2>&1) || exit_code=$?
  assert_success "current succeeds" "$exit_code"
  assert_matches "output is project ID" "$output" "project/%proj%"
}


test_task_current__not_on_a_task_branch() {
  setup_workspace "current-none"
  output="" exit_code=0
  output=$(run_tt task current 2>&1) || exit_code=$?
  assert_failure "current on non-task fails" "$exit_code"
}


run_tests "tt task current"
