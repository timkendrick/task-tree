#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_worktree_active__after_init_returns_repo() {
  setup_workspace "wt-active-init"
  # After workspace init, HEAD points at the repo root
  output="" exit_code=0
  output=$(run_tt worktree active 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "HEAD points to repo root after init" "$output" "$REPO"
}

test_worktree_active__alias_tt_active() {
  setup_workspace "wt-active-alias"
  output="" exit_code=0
  output=$(run_tt active 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "alias resolves to active worktree" "$output" "$REPO"
}

test_worktree_active__repo_flag() {
  setup_workspace "wt-active-repo-flag"
  output="" exit_code=0
  output=$(run_tt worktree active --repo "$REPO" 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "output with --repo flag" "$output" "$REPO"
}

test_worktree_active__worktree_without_switch_keeps_head() {
  setup_workspace "wt-active-no-switch"
  proj_id=$(create_project "proj" "Project") || true
  task_id=$(create_task "my-task" "My Task") || true

  # --worktree without --switch creates the worktree but must NOT move HEAD
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  assert_file_exists "dedicated worktree created" "$VIRTUAL/$task_id/TASK.md"

  output="" exit_code=0
  output=$(run_tt worktree active 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "HEAD stays at repo root without --switch" "$output" "$REPO"
}

test_worktree_active__after_checkout_switch_returns_worktree() {
  setup_workspace "wt-active-checkout"
  proj_id=$(create_project "proj" "Project") || true
  task_id=$(create_task "my-task" "My Task") || true

  # --worktree --switch creates the worktree and points HEAD at it
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  local expected_path
  expected_path="$(realpath "$VIRTUAL/$task_id")"

  output="" exit_code=0
  output=$(run_tt worktree active 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "HEAD points to task worktree after --switch" "$output" "$expected_path"
}

test_worktree_active__no_workspace_configured() {
  setup_workspace "wt-active-no-ws"
  rm -f "$REPO/.tt/workspace"
  output="" exit_code=0
  output=$(run_tt worktree active 2>&1) || exit_code=$?
  assert_failure "exits with error when workspace not configured" "$exit_code"
  assert_contains "error mentions workspace init" "$output" "tt workspace init"
}

test_worktree_active__no_head_symlink() {
  setup_workspace "wt-active-no-head"
  rm -f "$VIRTUAL/HEAD"
  output="" exit_code=0
  output=$(run_tt worktree active 2>&1) || exit_code=$?
  assert_failure "exits with error when HEAD absent" "$exit_code"
  assert_contains "error mentions HEAD" "$output" "HEAD"
}

test_worktree_active__rejects_unknown_flags() {
  setup_workspace "wt-active-unknown-flag"
  output="" exit_code=0
  output=$(run_tt worktree active --unknown 2>&1) || exit_code=$?
  assert_failure "unknown flag rejected" "$exit_code"
}

test_worktree_active__rejects_positional_args() {
  setup_workspace "wt-active-pos-arg"
  output="" exit_code=0
  output=$(run_tt worktree active somearg 2>&1) || exit_code=$?
  assert_failure "positional argument rejected" "$exit_code"
}

test_worktree_active__help() {
  setup_workspace "wt-active-help"
  output="" exit_code=0
  output=$(run_tt worktree active --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt worktree active"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt worktree active"
