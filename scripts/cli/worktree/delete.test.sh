#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_worktree_delete__basic_delete() {
  setup_workspace "wt-del-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  # Complete from within the worktree so @ is left clean (empty change on top of bookmark)
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  run_tt_in_worktree "$worktree_path" task complete "$task_id" >/dev/null 2>&1 || true

  assert_neq "worktree is not repo" "$worktree_path" "$REPO"
  assert_file_exists "worktree dir exists" "$worktree_path"

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_success "delete succeeds" "$exit_code"
  assert_file_not_exists "worktree dir removed" "$worktree_path"
  assert_bookmark_exists "bookmark preserved" "$task_id"
}


test_worktree_delete__no_worktree_found() {
  setup_workspace "wt-del-noexist"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  # Don't checkout with --worktree

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "no worktree rejected" "$exit_code"
  assert_contains "error mentions no worktree" "$output" "No worktree found"
}


test_worktree_delete__nonexistent_task() {
  setup_workspace "wt-del-notask"
  output="" exit_code=0
  output=$(run_tt worktree delete --task "task/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent task rejected" "$exit_code"
}


test_worktree_delete__invalid_task_id() {
  setup_workspace "wt-del-invalid"
  output="" exit_code=0
  output=$(run_tt worktree delete --task "not-a-valid-id" 2>&1) || exit_code=$?
  assert_failure "invalid task ID rejected" "$exit_code"
}


test_worktree_delete__dirty_wc_rejected() {
  setup_workspace "wt-del-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  # Complete from within the worktree (leaves clean @), then make WC dirty
  run_tt_in_worktree "$worktree_path" task complete "$task_id" >/dev/null 2>&1 || true

  echo "dirty" > "$worktree_path/dirty-file.txt"

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
  assert_contains "mentions uncommitted" "$output" "uncommitted changes"
}


test_worktree_delete__dirty_wc_force() {
  setup_workspace "wt-del-dirty-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  echo "dirty" > "$worktree_path/dirty-file.txt"

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" --force 2>&1) || exit_code=$?
  assert_success "--force succeeds with dirty WC" "$exit_code"
  assert_file_not_exists "worktree dir removed" "$worktree_path"
}


test_worktree_delete__commits_after_bookmark_rejected() {
  setup_workspace "wt-del-ahead"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  # Complete from within worktree (leaves clean @ on top of bookmark); then add a new commit
  run_tt_in_worktree "$worktree_path" task complete "$task_id" >/dev/null 2>&1 || true

  echo "some work" > "$worktree_path/work.txt"
  jj -R "$worktree_path" commit -m "Some work" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "commits after bookmark rejected" "$exit_code"
  assert_contains "mentions bookmark" "$output" "bookmark"
}


test_worktree_delete__commits_after_bookmark_force() {
  setup_workspace "wt-del-ahead-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  echo "some work" > "$worktree_path/work.txt"
  jj -R "$worktree_path" commit -m "Some work" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" --force 2>&1) || exit_code=$?
  assert_success "--force succeeds with commits after bookmark" "$exit_code"
  assert_file_not_exists "worktree dir removed" "$worktree_path"
}


test_worktree_delete__head_symlink_reset() {
  setup_workspace "wt-del-head"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  run_tt_in_worktree "$worktree_path" task complete "$task_id" >/dev/null 2>&1 || true

  # Verify HEAD points to the worktree
  local head_target
  head_target=$(readlink "$VIRTUAL/HEAD") || true
  assert_contains "HEAD points to worktree" "$head_target" "$task_id"

  run_tt worktree delete --task "$task_id" >/dev/null 2>&1 || true

  # Verify HEAD now points to repo
  head_target=$(readlink "$VIRTUAL/HEAD") || true
  assert_eq "HEAD reset to repo" "$(realpath "$head_target")" "$(realpath "$REPO")"
}


test_worktree_delete__head_symlink_unchanged() {
  setup_workspace "wt-del-head-no"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # Create two tasks with worktrees
  task_a=$(create_task "task-a" "Task A") || true
  run_tt task checkout "$task_a" --worktree --switch >/dev/null 2>&1 || true
  worktree_a=$(run_tt worktree show "$task_a" 2>/dev/null) || true
  run_tt_in_worktree "$worktree_a" task complete "$task_a" >/dev/null 2>&1 || true
  task_b=$(create_task "task-b" "Task B") || true
  run_tt task checkout "$task_b" --worktree --switch >/dev/null 2>&1 || true

  # HEAD now points to task_b's worktree. Delete task_a's worktree.
  run_tt worktree delete --task "$task_a" >/dev/null 2>&1 || true

  # HEAD should still point to task_b
  local head_target
  head_target=$(readlink "$VIRTUAL/HEAD") || true
  assert_contains "HEAD unchanged, still task_b" "$head_target" "$task_b"
}

test_worktree_delete__records_transaction() {
  setup_workspace "wt-del-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  run_tt_in_worktree "$worktree_path" task complete "$task_id" >/dev/null 2>&1 || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt worktree delete --task "$task_id" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after delete"
}

test_worktree_delete__bookmark_preserved() {
  setup_workspace "wt-del-bm"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  (cd "$worktree_path" && checkpoint_task "Work" >/dev/null 2>&1) || true
  run_tt_in_worktree "$worktree_path" task complete "$task_id" >/dev/null 2>&1 || true

  run_tt worktree delete --task "$task_id" >/dev/null 2>&1 || true

  assert_bookmark_exists "bookmark still exists" "$task_id"
}


test_worktree_delete__multiple_worktrees_requires_disambiguation() {
  setup_workspace "wt-del-multi"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true

  # Create worktree via task checkout
  run_tt task checkout "$task_id" --worktree="$VIRTUAL/${task_id}-a" --switch >/dev/null 2>&1 || true

  # Manually create a second jj workspace with a different name but same bookmark,
  # simulating a user who created an additional workspace by hand.
  local second_ws_path="$VIRTUAL/${task_id}-b"
  jj -R "$REPO" workspace add \
    --name "alt-${task_id}" \
    -r "$task_id" \
    "$second_ws_path" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "multiple worktrees without disambiguation rejected" "$exit_code"
  assert_contains "mentions multiple" "$output" "Multiple worktrees"
}


test_worktree_delete__non_done_status_rejected() {
  setup_workspace "wt-del-not-done"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  # Task is IN-PROGRESS after checkout; do NOT complete it

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "non-DONE task rejected" "$exit_code"
  assert_contains "mentions DONE" "$output" "DONE"
}


test_worktree_delete__non_done_status_with_force() {
  setup_workspace "wt-del-not-done-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  # Task is IN-PROGRESS; --force bypasses the status check

  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" --force 2>&1) || exit_code=$?
  assert_success "--force succeeds with non-DONE task" "$exit_code"
  assert_file_not_exists "worktree dir removed" "$worktree_path"
}


test_worktree_delete__done_status_allowed() {
  setup_workspace "wt-del-done"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  run_tt_in_worktree "$worktree_path" task complete "$task_id" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_success "DONE task deletion succeeds without --force" "$exit_code"
  assert_file_not_exists "worktree dir removed" "$worktree_path"
}


test_worktree_delete__current_wc_rejected() {
  setup_workspace "wt-del-cur-wc"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true

  # Run delete from inside the target worktree (without --force)
  cd "$worktree_path"

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "current WC deletion rejected" "$exit_code"
  assert_contains "mentions current" "$output" "current working copy"
  assert_file_exists "worktree dir still exists" "$worktree_path"

  cd "$REPO"
}


test_worktree_delete__current_wc_force() {
  setup_workspace "wt-del-cur-wc-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true

  # --force bypasses the current WC check
  cd "$worktree_path"

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" --force 2>&1) || exit_code=$?
  assert_success "--force allows deleting current WC worktree" "$exit_code"

  cd "$REPO"
}


test_worktree_delete__help() {
  setup_workspace "wt-delete-help"
  output="" exit_code=0
  output=$(run_tt worktree delete --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt worktree delete"
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --worktree=<path>" "$output" "--worktree=<path>"
  assert_required_usage_argument "argument: --force" "$output" "--force"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt worktree delete"
