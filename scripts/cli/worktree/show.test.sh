#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_worktree_show__dedicated_worktree_returned() {
  setup_workspace "worktree-dedicated"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  worktree_path=$(create_task_worktree "$task_id")

  output="" exit_code=0
  output=$(run_tt worktree show --name "$task_id" 2>&1) || exit_code=$?
  assert_success "worktree lookup succeeds" "$exit_code"
  assert_eq "output is the dedicated worktree" "$output" "$worktree_path"
}


test_worktree_show__unknown_name_errors() {
  setup_workspace "worktree-unknown"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true

  output="" exit_code=0
  output=$(run_tt worktree show --name "$task_id" 2>&1) || exit_code=$?
  assert_failure "unnamed workspace rejected" "$exit_code"
  assert_contains "mentions the name" "$output" "$task_id"
  assert_contains "reports no such worktree" "$output" "No worktree named"
}


test_worktree_show__repository_root_errors() {
  setup_workspace "worktree-root"
  output="" exit_code=0
  output=$(run_tt worktree show --name "default" 2>&1) || exit_code=$?
  assert_failure "repository root rejected" "$exit_code"
  assert_contains "reports the repository root" "$output" "is the repository root"
}


# Regression: invoked from inside a dedicated worktree with no TT_REPO set,
# resolve_repo walks up to the worktree's own .jj and returns the worktree, not
# the canonical repo. Comparing the match against that path rejected the
# worktree. The repository root check must use the canonical repo root.
test_worktree_show__from_inside_worktree_returns_own_worktree() {
  setup_workspace "wt-show-inside-own"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  worktree_path=$(create_task_worktree "$task_id")

  output="" exit_code=0
  output=$(run_tt_in_worktree "$worktree_path" worktree show --name "$task_id" 2>&1) || exit_code=$?
  assert_success "lookup from inside own worktree succeeds" "$exit_code"
  assert_eq "returns own worktree" "$output" "$worktree_path"
}


test_worktree_show__from_inside_worktree_returns_other_worktree() {
  setup_workspace "wt-show-inside-other"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "task-a" "Task A") || true
  task_b=$(create_task "task-b" "Task B") || true
  worktree_a=$(create_task_worktree "$task_a")
  worktree_b=$(create_task_worktree "$task_b")

  output="" exit_code=0
  output=$(run_tt_in_worktree "$worktree_a" worktree show --name "$task_b" 2>&1) || exit_code=$?
  assert_success "cross-worktree lookup succeeds" "$exit_code"
  assert_eq "returns the other worktree" "$output" "$worktree_b"
}


# The workspace name is fixed when the worktree is created and does not track
# subsequent checkouts, so a worktree is found by its own name even while a
# different task is checked out in it.
test_worktree_show__name_independent_of_checked_out_task() {
  setup_workspace "wt-show-other-task"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "task-a" "Task A") || true
  task_b=$(create_task "task-b" "Task B") || true
  worktree_a=$(create_task_worktree "$task_a")
  run_tt_in_worktree "$worktree_a" task checkout "$task_b" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree show --name "$task_a" 2>&1) || exit_code=$?
  assert_success "worktree found by its own name" "$exit_code"
  assert_eq "returns the worktree" "$output" "$worktree_a"

  output="" exit_code=0
  output=$(run_tt worktree show --name "$task_b" 2>&1) || exit_code=$?
  assert_failure "checked-out task is not a workspace name" "$exit_code"
  assert_contains "reports no such worktree" "$output" "No worktree named"
}


test_worktree_show__missing_directory_errors() {
  setup_workspace "wt-show-missing-dir"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  worktree_path=$(create_task_worktree "$task_id")
  rm -rf "$worktree_path"

  output="" exit_code=0
  output=$(run_tt worktree show --name "$task_id" 2>&1) || exit_code=$?
  assert_failure "workspace without a usable path rejected" "$exit_code"
  assert_contains "reports an invalid path" "$output" "has an invalid path"
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
  assert_required_usage_argument "argument: --name" "$output" "--name"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt worktree show"
