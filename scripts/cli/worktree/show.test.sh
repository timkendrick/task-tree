#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_worktree_show__no_dedicated_worktree_errors() {
  setup_workspace "worktree-default"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true

  output="" exit_code=0
  output=$(run_tt worktree show --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "worktree lookup fails" "$exit_code"
  assert_contains "mentions task ID" "$output" "$task_id"
  assert_contains "mentions missing worktree" "$output" "No dedicated worktree"
}


test_worktree_show__main_workspace_checkout_errors() {
  setup_workspace "worktree-main-ws"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  checkout_task "$task_id" || true

  output="" exit_code=0
  output=$(run_tt worktree show --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "main-workspace checkout is not a dedicated worktree" "$exit_code"
  assert_contains "mentions missing worktree" "$output" "No dedicated worktree"
}


test_worktree_show__dedicated_worktree_returned() {
  setup_workspace "worktree-dedicated"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  worktree_path=$(create_task_worktree "$task_id")

  output="" exit_code=0
  output=$(run_tt worktree show --task "$task_id" 2>&1) || exit_code=$?
  assert_success "worktree lookup succeeds" "$exit_code"
  assert_eq "output is the dedicated worktree" "$output" "$worktree_path"
}


test_worktree_show__non_existent_bookmark() {
  setup_workspace "worktree-noexist"
  output="" exit_code=0
  output=$(run_tt worktree show --task "task/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent bookmark rejected" "$exit_code"
  assert_contains "distinct not-found error" "$output" "not found in repository"
}


test_worktree_show__bare_positional_arg_rejected() {
  setup_workspace "worktree-positional"
  output="" exit_code=0
  output=$(run_tt worktree show "task/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "bare positional arg rejected" "$exit_code"
  assert_contains "shows usage" "$output" "Usage:"
}


test_worktree_show__help() {
  setup_workspace "wt-show-help"
  output="" exit_code=0
  output=$(run_tt worktree show --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt worktree show"
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt worktree show"
