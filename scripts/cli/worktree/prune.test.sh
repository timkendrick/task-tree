#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


# Creates a project with two task worktrees: one DONE, one IN-PROGRESS.
# Sets DONE_ID, DONE_WT, ACTIVE_ID, ACTIVE_WT.
setup_done_and_active_worktrees() {
  setup_workspace "$1"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  DONE_ID=$(create_task "done-task" "Done Task") || true
  ACTIVE_ID=$(create_task "active-task" "Active Task") || true
  DONE_WT=$(create_task_worktree "$DONE_ID")
  ACTIVE_WT=$(create_task_worktree "$ACTIVE_ID")
  run_tt_in_worktree "$DONE_WT" task complete "$DONE_ID" >/dev/null 2>&1 || true
}


test_worktree_prune__deletes_done_worktrees_only() {
  setup_done_and_active_worktrees "wt-prune-basic"

  output="" exit_code=0
  output=$(run_tt worktree prune 2>/dev/null) || exit_code=$?
  assert_success "prune succeeds" "$exit_code"
  assert_file_not_exists "DONE worktree removed" "$DONE_WT"
  assert_file_exists "IN-PROGRESS worktree kept" "$ACTIVE_WT"
  assert_bookmark_exists "DONE bookmark preserved" "$DONE_ID"
  assert_line_count "one path printed" "$output" 1
  assert_contains "DONE worktree path printed" "$output" "$DONE_ID"
  assert_not_contains "IN-PROGRESS worktree not printed" "$output" "$ACTIVE_ID"
}


test_worktree_prune__no_done_worktrees() {
  setup_workspace "wt-prune-none"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  worktree_path=$(create_task_worktree "$task_id")

  stdout="" stderr_file="$_TEST_ROOT/prune-none.stderr" exit_code=0
  stdout=$(run_tt worktree prune 2>"$stderr_file") || exit_code=$?
  assert_success "prune succeeds" "$exit_code"
  assert_eq "nothing printed on stdout" "$stdout" ""
  assert_contains "reports nothing to prune" "$(cat "$stderr_file")" "No DONE worktrees to prune"
  assert_file_exists "IN-PROGRESS worktree kept" "$worktree_path"
}


test_worktree_prune__dry_run_deletes_nothing() {
  setup_done_and_active_worktrees "wt-prune-dry-run"

  dry_output="" exit_code=0
  dry_output=$(run_tt worktree prune --dry-run 2>/dev/null) || exit_code=$?
  assert_success "dry run succeeds" "$exit_code"
  assert_file_exists "DONE worktree kept" "$DONE_WT"
  assert_file_exists "IN-PROGRESS worktree kept" "$ACTIVE_WT"
  assert_line_count "one path printed" "$dry_output" 1
  assert_contains "DONE worktree path printed" "$dry_output" "$DONE_ID"

  output="" exit_code=0
  output=$(run_tt worktree prune 2>/dev/null) || exit_code=$?
  assert_success "prune succeeds" "$exit_code"
  assert_eq "dry run prints the same paths as prune" "$dry_output" "$output"
}


test_worktree_prune__failure_continues_and_exits_non_zero() {
  setup_workspace "wt-prune-failure"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  dirty_id=$(create_task "dirty-task" "Dirty Task") || true
  clean_id=$(create_task "clean-task" "Clean Task") || true
  dirty_wt=$(create_task_worktree "$dirty_id")
  clean_wt=$(create_task_worktree "$clean_id")
  run_tt_in_worktree "$dirty_wt" task complete "$dirty_id" >/dev/null 2>&1 || true
  run_tt_in_worktree "$clean_wt" task complete "$clean_id" >/dev/null 2>&1 || true
  echo "dirty" > "$dirty_wt/dirty-file.txt"

  stdout="" stderr_file="$_TEST_ROOT/prune-failure.stderr" exit_code=0
  stdout=$(run_tt worktree prune 2>"$stderr_file") || exit_code=$?
  assert_failure "prune fails" "$exit_code"
  assert_file_exists "dirty worktree kept" "$dirty_wt"
  assert_file_not_exists "clean worktree removed" "$clean_wt"
  assert_line_count "one path printed" "$stdout" 1
  assert_contains "clean worktree path printed" "$stdout" "$clean_id"
  assert_contains "reports uncommitted changes" "$(cat "$stderr_file")" "uncommitted changes"
}


test_worktree_prune__force_deletes_dirty_done_worktree() {
  setup_done_and_active_worktrees "wt-prune-force"
  echo "dirty" > "$DONE_WT/dirty-file.txt"

  output="" exit_code=0
  output=$(run_tt worktree prune --force 2>/dev/null) || exit_code=$?
  assert_success "prune --force succeeds" "$exit_code"
  assert_file_not_exists "dirty DONE worktree removed" "$DONE_WT"
  assert_file_exists "IN-PROGRESS worktree kept" "$ACTIVE_WT"
}


test_worktree_prune__help() {
  setup_workspace "wt-prune-help"
  output="" exit_code=0
  output=$(run_tt worktree prune --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt worktree prune"
  assert_required_usage_argument "argument: --dry-run" "$output" "--dry-run"
  assert_required_usage_argument "argument: --force" "$output" "--force"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


test_worktree_prune__unknown_argument_rejected() {
  setup_workspace "wt-prune-unknown"
  output="" exit_code=0
  output=$(run_tt worktree prune --bogus 2>&1) || exit_code=$?
  assert_failure "unknown flag rejected" "$exit_code"
  assert_contains "usage shown" "$output" "Usage:"
}


run_tests "tt worktree prune"
