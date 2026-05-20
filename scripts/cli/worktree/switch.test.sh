#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_worktree_switch__non_workspace_path_rejected() {
  setup_workspace "switch-invalid"
  output="" exit_code=0
  output=$(run_tt worktree switch "/tmp/nonexistent-path" 2>&1) || exit_code=$?
  assert_failure "non-workspace path rejected" "$exit_code"
  assert_contains "error mentions workspace" "$output" "not a jj workspace"
}


test_worktree_switch__switches_to_existing_worktree() {
  setup_workspace "switch-worktree"
  local proj_id task_id
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_id=$(create_task "my-task" "My Task") || true

  # Check out the task with a dedicated worktree
  local worktree_path="$_TEST_ROOT/switch-worktree-task-wt"
  run_tt task checkout "$task_id" --worktree="$worktree_path" >/dev/null 2>&1 || true

  # Switch back to the main repo WC on the project branch
  jj -R "$REPO" new "$proj_id" >/dev/null 2>&1 || true

  # Now switch HEAD to the task worktree via tt worktree switch
  output="" exit_code=0
  output=$(run_tt worktree switch "$worktree_path" 2>&1) || exit_code=$?
  assert_success "worktree switch succeeds" "$exit_code"

  # HEAD symlink should now resolve to the task worktree
  local virtual_dir
  virtual_dir="$(readlink "$REPO/.tt/workspace")"
  local head_target resolved_head
  head_target="$(readlink "$virtual_dir/HEAD" 2>/dev/null || true)"
  if [[ "$head_target" != /* ]]; then
    head_target="$virtual_dir/$head_target"
  fi
  resolved_head="$(cd "$head_target" 2>/dev/null && pwd -P)" || true
  local canonical_worktree
  canonical_worktree="$(cd "$worktree_path" 2>/dev/null && pwd -P)" || true
  assert_eq "HEAD points to task worktree" "$resolved_head" "$canonical_worktree"
}


test_worktree_switch__help() {
  setup_workspace "switch-help"
  output="" exit_code=0
  output=$(run_tt worktree switch --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt worktree switch"
  assert_required_usage_argument "argument: <worktree-path>" "$output" "<worktree-path>"
  assert_required_usage_argument "argument: --force" "$output" "--force"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt worktree switch"
