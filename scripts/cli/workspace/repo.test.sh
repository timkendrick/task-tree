#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_workspace_repo__canonical_repo_returns_itself() {
  setup_workspace "ws-repo-canonical"
  output="" exit_code=0
  output=$(run_tt workspace repo 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "canonical repo is $REPO" "$output" "$REPO"
}

test_workspace_repo__alias_tt_repo() {
  setup_workspace "ws-repo-alias"
  output="" exit_code=0
  output=$(run_tt repo 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "alias resolves to canonical repo" "$output" "$REPO"
}

test_workspace_repo__from_worktree_resolves_canonical() {
  setup_workspace "ws-repo-from-wt"
  proj_id=$(create_project "proj" "Project") || true
  task_id=$(create_task "my-task" "My Task") || true

  # Check out the task with a dedicated worktree
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  # Find the worktree path for this task
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || worktree_path=""

  # Only run the worktree test if a dedicated worktree was actually created
  if [[ -n "$worktree_path" && "$worktree_path" != "$REPO" ]]; then
    output="" exit_code=0
    output=$(run_tt_in_worktree "$worktree_path" workspace repo 2>&1) || exit_code=$?
    assert_success "exit code from worktree" "$exit_code"
    assert_eq "workspace repo resolves to canonical repo" "$output" "$REPO"
  else
    # If no dedicated worktree was created, the repo itself is the canonical root
    output=$(run_tt workspace repo 2>&1)
    assert_eq "root is repo" "$output" "$REPO"
  fi
}

test_workspace_repo__repo_flag() {
  setup_workspace "ws-repo-repo-flag"
  output="" exit_code=0
  output=$(run_tt workspace repo --repo "$REPO" 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "output with --repo flag" "$output" "$REPO"
}

test_workspace_repo__rejects_unknown_flags() {
  setup_workspace "ws-repo-unknown-flag"
  output="" exit_code=0
  output=$(run_tt workspace repo --unknown 2>&1) || exit_code=$?
  assert_failure "unknown flag rejected" "$exit_code"
}

test_workspace_repo__rejects_positional_args() {
  setup_workspace "ws-repo-pos-arg"
  output="" exit_code=0
  output=$(run_tt workspace repo somearg 2>&1) || exit_code=$?
  assert_failure "positional argument rejected" "$exit_code"
}

test_workspace_repo__help() {
  setup_workspace "ws-repo-help"
  output="" exit_code=0
  output=$(run_tt workspace repo --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt workspace repo"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt workspace repo"
