#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


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


test_task_current__after_the_branch_advanced_elsewhere() {
  # A write issued from another worktree advances this worktree's branch without
  # moving its working copy, leaving the bookmark on a sibling of the
  # working-copy commit: the nearest bookmarked ancestor is then the project the
  # task forked from, but the task checked out here has not changed.
  setup_workspace "current-advanced-elsewhere"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mine" "Mine") || true
  other_id=$(create_task "other" "Other") || true
  other_wt=$(create_task_worktree "$other_id")
  checkout_task "$task_id" >/dev/null || true

  run_tt_in_worktree "$other_wt" task edit "$task_id" --title "Mine, advanced" >/dev/null 2>&1 || true
  assert_not_ancestor "this worktree is left behind its branch" "$task_id" '@'

  output="" exit_code=0
  output=$(run_tt task current 2>&1) || exit_code=$?
  assert_success "current succeeds" "$exit_code"
  assert_eq "current names the task checked out here" "$output" "$task_id"
}


test_task_current__not_on_a_task_branch() {
  setup_workspace "current-none"
  output="" exit_code=0
  output=$(run_tt task current 2>&1) || exit_code=$?
  assert_failure "current on non-task fails" "$exit_code"
}


test_task_current__help() {
  setup_workspace "current-help"
  output="" exit_code=0
  output=$(run_tt task current --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task current"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task current"
