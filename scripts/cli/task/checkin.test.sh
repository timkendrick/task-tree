#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"

test_task_checkin__basic_checkin_of_completed_task() {
  setup_workspace "ci-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task checkin "$task_id" 2>&1) || exit_code=$?
  assert_success "checkin succeeds" "$exit_code"
  assert_subtask_entry "parent [x]" "$proj_id" "$task_id" "[x]"
  assert_current_task "WC on parent" "$proj_id"
  assert_no_conflicts "no conflicts"
  assert_history_integrity "history after checkin"
}


test_task_checkin__partial_in_progress() {
  setup_workspace "ci-partial"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Partial" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task checkin "$task_id" 2>&1) || exit_code=$?
  assert_success "partial checkin" "$exit_code"
  assert_subtask_entry "parent [-]" "$proj_id" "$task_id" "[-]"
}


test_task_checkin__with_complete() {
  setup_workspace "ci-complete"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  run_tt task checkin --complete "$task_id" >/dev/null 2>&1 || true
  assert_task_status "DONE" "$task_id" "DONE"
  assert_subtask_entry "parent [x]" "$proj_id" "$task_id" "[x]"
}


test_task_checkin__with_delete() {
  setup_workspace "ci-delete"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  run_tt task checkin --delete "$task_id" >/dev/null 2>&1 || true
  assert_bookmark_not_exists "bookmark deleted" "$task_id"
  assert_no_subtask_entry "no subtask entry" "$proj_id" "$task_id"
}


test_task_checkin__project_branch_rejected() {
  setup_workspace "ci-project"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task checkin "$proj_id" 2>&1) || exit_code=$?
  assert_failure "project checkin rejected" "$exit_code"
  assert_contains "suggests publish" "$output" "publish"
}


test_task_checkin__not_on_task_branch_without_id_fails() {
  # Use a fresh workspace with no task checkouts so resolve_current finds no task ancestor
  setup_workspace "ci-notask"
  output="" exit_code=0
  output=$(run_tt task checkin 2>&1) || exit_code=$?
  assert_failure "checkin with no tasks fails" "$exit_code"
}


test_task_checkin__single_transaction() {
  setup_workspace "ci-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after checkin"
}


test_task_checkin__head_no_symlink_loop_when_working_from_head_directory() {
  # Regression: when the user works from inside the HEAD-linked directory
  # (e.g. their editor opens /virtual/HEAD which symlinks to a real worktree),
  # find_repo_root resolves $repo to the symlink path /virtual/HEAD via `pwd`
  # rather than the real worktree path. This causes find_worktrees_for_branch
  # to fall back to $repo (= /virtual/HEAD) as target_ws, and
  # perform_workspace_switch then sets HEAD -> /virtual/HEAD, a self-referential
  # loop that breaks all subsequent tt commands.
  setup_workspace "ci-symlink-loop"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # Create a sibling task so --propagate has work to do after checkin
  create_task "sibling" "Sibling" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  # Create the task under test
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  # Run checkin from inside the HEAD symlink directory, without TT_REPO set,
  # so find_repo_root resolves $repo via `pwd` to the symlink path.
  local head_path="$VIRTUAL/HEAD"
  output="" exit_code=0
  output=$(cd "$head_path" && unset TT_REPO && "$TT" task checkin --complete --propagate "$task_id" 2>&1) || exit_code=$?
  assert_success "checkin --complete --propagate succeeds" "$exit_code"

  local head_target
  head_target="$(readlink "$VIRTUAL/HEAD")"
  assert_neq "HEAD does not point to itself" "$head_target" "$head_path"
}


test_task_checkin__head_symlink_is_absolute() {
  setup_workspace "ci-head-abs"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  local head_target
  head_target="$(readlink "$VIRTUAL/HEAD")"
  assert_eq "HEAD is absolute" "${head_target:0:1}" "/"
}


test_task_checkin__head_symlink_updated_from_worktree() {
  # Regression: when running `tt task checkin` from inside a task's dedicated
  # worktree, HEAD should be updated to point to the parent's workspace, not
  # left pointing at the task worktree.
  setup_workspace "ci-head-wt-switch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  # Checkout with a dedicated worktree and switch HEAD to it
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"

  # Checkpoint from within the worktree
  TT_REPO="$worktree_path" run_tt task checkpoint -m "work" >/dev/null 2>&1 || true

  # HEAD currently points to the task worktree
  local head_before
  head_before="$(readlink "$VIRTUAL/HEAD")"
  assert_contains "HEAD points to task worktree before checkin" "$head_before" "$task_id"

  # Run checkin FROM WITHIN the worktree (no TT_REPO set)
  local exit_code=0
  (cd "$worktree_path" && unset TT_REPO && "$TT" task checkin --complete 2>&1) || exit_code=$?

  assert_success "checkin from worktree succeeds" "$exit_code"

  local head_after
  head_after="$(readlink "$VIRTUAL/HEAD")"
  assert_not_contains "HEAD no longer points to task worktree" "$head_after" "$task_id"
  assert_neq "HEAD was updated from task worktree" "$head_after" "$head_before"
}


test_task_checkin__worktree_deleted_after_complete_checkin() {
  # After a complete (DONE) checkin the task's dedicated worktree should be
  # forgotten from jj and its files deleted from disk.
  setup_workspace "ci-wt-cleanup"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  # Create a dedicated worktree (no --switch; HEAD stays on proj)
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"
  assert_file_exists "worktree exists before checkin" "$worktree_path"

  # Checkpoint from the worktree
  TT_REPO="$worktree_path" run_tt task checkpoint -m "work" >/dev/null 2>&1 || true

  # Complete checkin (from main repo, with explicit task_id)
  run_tt task checkin --complete "$task_id" >/dev/null 2>&1 || true

  # Worktree should be deleted
  assert_file_not_exists "worktree deleted after complete checkin" "$worktree_path"
}


test_task_checkin__retain_worktree_flag() {
  # With --retain-worktree, the worktree should NOT be deleted after checkin.
  setup_workspace "ci-retain-wt"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"
  assert_file_exists "worktree exists before checkin" "$worktree_path"

  TT_REPO="$worktree_path" run_tt task checkpoint -m "work" >/dev/null 2>&1 || true

  # Checkin with --retain-worktree
  run_tt task checkin --complete --retain-worktree "$task_id" >/dev/null 2>&1 || true

  # Worktree should still exist
  assert_file_exists "worktree retained with --retain-worktree" "$worktree_path"
}


test_task_checkin__worktree_not_deleted_after_partial_checkin() {
  # A partial (IN-PROGRESS) checkin should NOT delete the worktree.
  setup_workspace "ci-partial-wt"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"

  TT_REPO="$worktree_path" run_tt task checkpoint -m "work" >/dev/null 2>&1 || true

  # Partial checkin (IN-PROGRESS, not complete)
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  assert_file_exists "worktree retained after partial checkin" "$worktree_path"
}


test_task_checkin__cwd_outside_repo() {
  # Regression: jj file show resolves paths relative to CWD, not the repo root.
  # tt commands must use root: prefix so checkin works when CWD is outside the repo
  # (e.g. when -R receives the canonical path but CWD is a symlinked or parent path).
  setup_workspace "ci-cwd"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  # Run checkin from /tmp (completely outside the repo) using the canonical repo path.
  local canonical_repo
  canonical_repo="$(cd "$REPO" && pwd -P)"

  output="" exit_code=0
  output=$(cd /tmp && TT_REPO="$canonical_repo" "$TT" task checkin "$task_id" 2>&1) || exit_code=$?
  assert_success "checkin from outside repo (canonical path) succeeds" "$exit_code"
}


test_task_checkin__help() {
  setup_workspace "checkin-help"
  output="" exit_code=0
  output=$(run_tt task checkin --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task checkin"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
  assert_optional_usage_argument "argument: --force" "$output" "--force"
  assert_optional_usage_argument "argument: --delete" "$output" "--delete"
}


run_tests "tt task checkin"
