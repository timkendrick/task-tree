#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_worktree_list__basic_output_has_header() {
  setup_workspace "list-header"
  output="" exit_code=0
  output=$(run_tt worktree list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "output has NAME header" "$output" "NAME"
  assert_contains "output has TASK ID header" "$output" "TASK ID"
  assert_contains "output has PATH header" "$output" "PATH"
}

test_worktree_list__default_workspace_has_none_task() {
  setup_workspace "list-none-task"
  output="" exit_code=0
  output=$(run_tt worktree list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "default row shows (none) for task" "$output" "(none)"
}

test_worktree_list__shows_task_id_for_task_workspace() {
  setup_workspace "list-task-id"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "output contains task ID" "$output" "$task_id"
}

test_worktree_list__task_read_beyond_the_bookmark_tip() {
  # The workspace working copy has a plain jj commit on top of the task bookmark
  # tip. The task travels with the working copy that records it, so commits made
  # beyond the bookmark do not change which task the worktree holds.
  setup_workspace "list-beyond-tip"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  # Add a plain jj commit on top of the task bookmark tip (does NOT advance the bookmark)
  jj_commit "Extra work beyond bookmark tip" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt worktree list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "output still names the checked-out task" "$output" "$task_id"
}

# Commit ID of the working-copy commit in the worktree at PATH, read without
# snapshotting that worktree.
_worktree_wc_commit() {
  jj -R "$1" --ignore-working-copy log -r '@' --no-graph -T 'commit_id' 2>/dev/null
}

test_worktree_list__task_survives_a_sibling_branch_advance() {
  # Two worktrees on different branches. A write issued from one of them
  # advances the other's branch without moving its working copy, so that
  # worktree's bookmark ends up on a sibling of its working-copy commit and the
  # nearest bookmarked ancestor of both worktrees is the project below them.
  # Each worktree must still be listed against the task it has checked out.
  setup_workspace "list-sibling-advance"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  first_id=$(create_task "first" "First") || true
  second_id=$(create_task "second" "Second") || true
  second_wt=$(create_task_worktree "$second_id")
  checkout_task "$first_id" >/dev/null || true

  run_tt task edit "$second_id" --title "Second, advanced" >/dev/null 2>&1 || true
  assert_not_ancestor "the dedicated worktree is left behind its branch" \
    "$second_id" "$(_worktree_wc_commit "$second_wt")"
  assert_task_symlink "the dedicated worktree records its own task" "$second_id" "$second_wt"
  assert_task_symlink "the default worktree records the task it checked out" "$first_id"

  output="" exit_code=0
  output=$(run_tt worktree list --quiet --task "$second_id" 2>&1) || exit_code=$?
  assert_success "list --task on the advanced branch succeeds" "$exit_code"
  assert_eq "the worktree left behind still holds its own task" "$output" "$second_id"

  output="" exit_code=0
  output=$(run_tt worktree list --quiet --task "$first_id" 2>&1) || exit_code=$?
  assert_success "list --task on the other branch succeeds" "$exit_code"
  assert_eq "the default worktree holds the task it checked out" "$output" "default"

  output="" exit_code=0
  output=$(run_tt worktree list --quiet --task "$proj_id" 2>&1) || exit_code=$?
  assert_success "list --task on the project succeeds" "$exit_code"
  assert_output_empty "no worktree is attributed to the project below them" "$output"
}

test_worktree_list__repo_flag() {
  setup_workspace "list-repo-flag"
  output="" exit_code=0
  output=$(run_tt worktree list --repo "$REPO" 2>&1) || exit_code=$?
  assert_success "list with --repo succeeds" "$exit_code"
  assert_contains "output has header" "$output" "NAME"
}

test_worktree_list__unknown_option_fails() {
  setup_workspace "list-unknown-opt"
  output="" exit_code=0
  output=$(run_tt worktree list --unknown 2>&1) || exit_code=$?
  assert_failure "unknown option fails" "$exit_code"
}

test_worktree_list__task_filter() {
  setup_workspace "list-filter"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree list --task "$task_id" 2>&1) || exit_code=$?
  assert_success "list --task succeeds" "$exit_code"
  assert_contains "filtered output contains task ID" "$output" "$task_id"
  assert_not_contains "filtered output omits other workspaces" "$output" "default"
}

test_worktree_list__task_filter_no_match() {
  setup_workspace "list-filter-nomatch"
  proj_id=$(create_project "proj" "Project") || true

  # proj_id exists as a bookmark but has no worktree checked out with that task
  # (only the repo's default workspace exists; it won't have proj_id as resolved task)
  output="" exit_code=0
  output=$(run_tt worktree list --task "$proj_id" 2>&1) || exit_code=$?
  assert_success "list with no-match task filter still succeeds" "$exit_code"
  assert_contains "header is still present" "$output" "NAME"
  assert_not_contains "proj_id row absent" "$output" "$proj_id"
}

test_worktree_list__task_filter_invalid_id() {
  setup_workspace "list-filter-invalid"
  output="" exit_code=0
  output=$(run_tt worktree list --task "not-a-task-id" 2>&1) || exit_code=$?
  assert_failure "invalid --task ID rejected" "$exit_code"
}

test_worktree_list__quiet_mode() {
  setup_workspace "list-quiet"
  output="" exit_code=0
  output=$(run_tt worktree list --quiet 2>&1) || exit_code=$?
  assert_success "list --quiet succeeds" "$exit_code"
  assert_not_contains "quiet output has no NAME header" "$output" "NAME"
  assert_not_contains "quiet output has no TASK ID header" "$output" "TASK ID"
  assert_contains "quiet output lists a workspace name" "$output" "default"
}

test_worktree_list__quiet_with_task_filter() {
  setup_workspace "list-quiet-filter"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree list --quiet --task "$task_id" 2>&1) || exit_code=$?
  assert_success "list --quiet --task succeeds" "$exit_code"
  assert_contains "quiet output contains workspace name" "$output" "$task_id"
  assert_not_contains "quiet output omits other workspaces" "$output" "default"
  assert_not_contains "quiet output has no header" "$output" "NAME"
}


test_worktree_list__help() {
  setup_workspace "worktree-list-help"
  output="" exit_code=0
  output=$(run_tt worktree list --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt worktree list"
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --quiet" "$output" "--quiet"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt worktree list"
