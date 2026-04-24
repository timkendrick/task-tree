#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"

test_task_checkout__basic_checkout_of_todo_task() {
  setup_workspace "checkout-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  assert_task_status "TODO before checkout" "$task_id" "TODO"

  output="" exit_code=0
  output=$(checkout_task "$task_id") || exit_code=$?
  assert_success "checkout succeeds" "$exit_code"
  assert_task_status "IN-PROGRESS after checkout" "$task_id" "IN-PROGRESS"
  assert_current_task "WC on task branch" "$task_id"
  assert_wc_clean "WC clean after checkout"
}


test_task_checkout__already_in_progress_is_no_op() {
  setup_workspace "checkout-inprogress"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(run_tt task create --slug "mytask" --title "My Task" --checkout <<< "" | tail -1) || true
  assert_task_status "IN-PROGRESS" "$task_id" "IN-PROGRESS"

  checkout_task "$proj_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")
  checkout_task "$task_id" >/dev/null || true
  bm_after=$(get_bookmark_commit "$task_id")
  assert_eq "no new Begin commit" "$bm_before" "$bm_after"
}


test_task_checkout__dirty_wc_rejected() {
  setup_workspace "checkout-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  edit_file "dirty.txt" "dirty"
  output="" exit_code=0
  output=$(checkout_task "$task_id" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
}


test_task_checkout__dirty_wc_with_force() {
  setup_workspace "checkout-dirty-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  edit_file "dirty.txt" "dirty"
  output="" exit_code=0
  output=$(run_tt task checkout "$task_id" --force 2>&1) || exit_code=$?
  assert_success "checkout --force succeeds" "$exit_code"
}


test_task_checkout__invalid_task_id_rejected() {
  setup_workspace "checkout-invalid"
  output="" exit_code=0
  output=$(run_tt task checkout "not-a-task" 2>&1) || exit_code=$?
  assert_failure "invalid task ID rejected" "$exit_code"
}


test_task_checkout__non_existent_bookmark_rejected() {
  setup_workspace "checkout-noexist"
  output="" exit_code=0
  output=$(run_tt task checkout "task/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent bookmark rejected" "$exit_code"
}


test_task_checkout__records_transaction() {
  setup_workspace "checkout-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  checkout_task "$task_id" >/dev/null || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history integrity after checkout"
}


test_task_checkout__worktree_creates_history_file() {
  setup_workspace "co-worktree-history"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  # Checkout into a new dedicated worktree
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  # Derive the worktree path (conventional: <workspace_dir>/<task_id>)
  local worktree_path="$VIRTUAL/$task_id"

  # The new worktree must have a .tt/history file so that tt commands
  # run from within the worktree can record transactions.
  assert_file_exists ".tt/history exists in worktree" "$worktree_path/.tt/history"

  # Running a tt command from within the worktree should not error on
  # a missing history file (the sed "No such file or directory" failure).
  local wt_output wt_exit=0
  wt_output=$(run_tt_in_worktree "$worktree_path" task checkpoint -m "checkpoint from worktree" 2>&1) || wt_exit=$?
  assert_success "tt command in worktree succeeds" "$wt_exit"
}


test_task_checkout__head_symlink_is_absolute() {
  setup_workspace "co-head-abs"
  proj_id=$(create_project "proj" "Project") || true
  task_id=$(create_task "t" "T") || true

  run_tt task checkout "$task_id" >/dev/null 2>&1 || true

  local head_target
  head_target="$(readlink "$VIRTUAL/HEAD")"
  assert_eq "HEAD is absolute" "${head_target:0:1}" "/"
}


test_task_checkout__worktree_refuses_second_different_path() {
  setup_workspace "co-worktree-refuse-diff"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  # Checkout into a new worktree (conventional path)
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  local first_worktree="$VIRTUAL/$task_id"

  # Try to checkout into a DIFFERENT path
  local second_path="$VIRTUAL/other-worktree"
  output="" exit_code=0
  output=$(run_tt task checkout "$task_id" --worktree="$second_path" 2>&1) || exit_code=$?
  assert_failure "refuse second worktree with different path" "$exit_code"
  assert_contains "error mentions existing workspace" "$output" "$first_worktree"
  assert_contains "error mentions task" "$output" "$task_id"
}


test_task_checkout__worktree_same_path_succeeds() {
  setup_workspace "co-worktree-same-path"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  # Checkout into a new worktree with explicit path
  local worktree_path="$VIRTUAL/$task_id"
  run_tt task checkout "$task_id" --worktree="$worktree_path" --switch >/dev/null 2>&1 || true

  # Checkout again with the same explicit path — should succeed silently
  output="" exit_code=0
  output=$(run_tt task checkout "$task_id" --worktree="$worktree_path" 2>&1) || exit_code=$?
  assert_success "same path succeeds" "$exit_code"
}


test_task_checkout__help() {
  setup_workspace "checkout-help"
  output="" exit_code=0
  output=$(run_tt task checkout --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task checkout"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_required_usage_argument "argument: --worktree[=<path>]" "$output" "--worktree[=<path>]"
  assert_required_usage_argument "argument: --force" "$output" "--force"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task checkout"
