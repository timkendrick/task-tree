#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_worktree_show__no_dedicated_worktree_falls_back_to_repo() {
  setup_workspace "worktree-default"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true

  output="" exit_code=0
  output=$(run_tt worktree show "$task_id" 2>&1) || exit_code=$?
  assert_success "worktree lookup succeeds" "$exit_code"
  assert_contains "output is repo root" "$output" "$REPO"
}


test_worktree_show__non_existent_bookmark() {
  setup_workspace "worktree-noexist"
  output="" exit_code=0
  output=$(run_tt worktree show "task/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent bookmark rejected" "$exit_code"
}


run_tests "tt worktree show"