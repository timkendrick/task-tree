#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_workspace_list__basic_output_has_header() {
  setup_workspace "list-header"
  output="" exit_code=0
  output=$(run_tt workspace list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "output has NAME header" "$output" "NAME"
  assert_contains "output has TASK ID header" "$output" "TASK ID"
  assert_contains "output has PATH header" "$output" "PATH"
}

test_workspace_list__default_workspace_has_none_task() {
  setup_workspace "list-none-task"
  output="" exit_code=0
  output=$(run_tt workspace list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "default row shows (none) for task" "$output" "(none)"
}

test_workspace_list__shows_task_id_for_task_workspace() {
  setup_workspace "list-task-id"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt workspace list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "output contains task ID" "$output" "$task_id"
}

test_workspace_list__task_inferred_from_ancestry() {
  # The workspace working copy has a plain jj commit on top of the task bookmark tip.
  # resolve_current should still find the task bookmark in the ancestry.
  setup_workspace "list-ancestry"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  # Add a plain jj commit on top of the task bookmark tip (does NOT advance the bookmark)
  jj_commit "Extra work beyond bookmark tip" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt workspace list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "output infers task ID from ancestry" "$output" "$task_id"
}

test_workspace_list__repo_flag() {
  setup_workspace "list-repo-flag"
  output="" exit_code=0
  output=$(run_tt workspace list --repo "$REPO" 2>&1) || exit_code=$?
  assert_success "list with --repo succeeds" "$exit_code"
  assert_contains "output has header" "$output" "NAME"
}

test_workspace_list__unknown_option_fails() {
  setup_workspace "list-unknown-opt"
  output="" exit_code=0
  output=$(run_tt workspace list --unknown 2>&1) || exit_code=$?
  assert_failure "unknown option fails" "$exit_code"
}

test_workspace_list__task_filter() {
  setup_workspace "list-filter"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt workspace list --task "$task_id" 2>&1) || exit_code=$?
  assert_success "list --task succeeds" "$exit_code"
  assert_contains "filtered output contains task ID" "$output" "$task_id"
  assert_not_contains "filtered output omits other workspaces" "$output" "default"
}

test_workspace_list__task_filter_no_match() {
  setup_workspace "list-filter-nomatch"
  proj_id=$(create_project "proj" "Project") || true

  # proj_id exists as a bookmark but has no worktree checked out with that task
  # (only the repo's default workspace exists; it won't have proj_id as resolved task)
  output="" exit_code=0
  output=$(run_tt workspace list --task "$proj_id" 2>&1) || exit_code=$?
  assert_success "list with no-match task filter still succeeds" "$exit_code"
  assert_contains "header is still present" "$output" "NAME"
  assert_not_contains "proj_id row absent" "$output" "$proj_id"
}

test_workspace_list__task_filter_invalid_id() {
  setup_workspace "list-filter-invalid"
  output="" exit_code=0
  output=$(run_tt workspace list --task "not-a-task-id" 2>&1) || exit_code=$?
  assert_failure "invalid --task ID rejected" "$exit_code"
}

test_workspace_list__quiet_mode() {
  setup_workspace "list-quiet"
  output="" exit_code=0
  output=$(run_tt workspace list --quiet 2>&1) || exit_code=$?
  assert_success "list --quiet succeeds" "$exit_code"
  assert_not_contains "quiet output has no NAME header" "$output" "NAME"
  assert_not_contains "quiet output has no TASK ID header" "$output" "TASK ID"
  assert_contains "quiet output lists a workspace name" "$output" "default"
}

test_workspace_list__quiet_with_task_filter() {
  setup_workspace "list-quiet-filter"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt workspace list --quiet --task "$task_id" 2>&1) || exit_code=$?
  assert_success "list --quiet --task succeeds" "$exit_code"
  assert_contains "quiet output contains workspace name" "$output" "$task_id"
  assert_not_contains "quiet output omits other workspaces" "$output" "default"
  assert_not_contains "quiet output has no header" "$output" "NAME"
}


test_workspace_list__help() {
  setup_workspace "ws-list-help"
  output="" exit_code=0
  output=$(run_tt workspace list --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt workspace list"
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --quiet" "$output" "--quiet"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt workspace list"
