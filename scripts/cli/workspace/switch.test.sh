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


test_workspace_switch__switches_to_existing_worktree() {
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

  # Now switch HEAD to the task worktree via tt workspace switch
  output="" exit_code=0
  output=$(run_tt workspace switch "$task_id" 2>&1) || exit_code=$?
  assert_success "workspace switch succeeds" "$exit_code"

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


run_tests "tt workspace switch"
