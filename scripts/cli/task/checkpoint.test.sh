#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"

test_task_checkpoint__basic_with_message() {
  setup_workspace "cp-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(checkpoint_task "Test cp") || exit_code=$?
  assert_success "checkpoint succeeds" "$exit_code"
  assert_commit_message_first_line "commit message" "@-" "[tt:task:$task_id:checkpoint] Test cp"
  assert_wc_clean "WC clean after checkpoint"
}


test_task_checkpoint__with_file_changes() {
  setup_workspace "cp-files"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  edit_file "src/main.sh" "echo hello"
  checkpoint_task "File cp" >/dev/null || true
  modified="$(get_modified_files "@-")"
  assert_contains "file committed" "$modified" "src/main.sh"
  assert_wc_clean "WC clean"
}


test_task_checkpoint__empty_wc_still_commits() {
  setup_workspace "cp-empty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")
  checkpoint_task "Empty cp" >/dev/null || true
  bm_after=$(get_bookmark_commit "$task_id")
  assert_neq "bookmark advanced" "$bm_before" "$bm_after"
}


test_task_checkpoint__not_on_task_branch_fails() {
  setup_workspace "cp-notask"
  output="" exit_code=0
  output=$(checkpoint_task "Should fail") || exit_code=$?
  assert_failure "checkpoint on non-task fails" "$exit_code"
}


test_task_checkpoint__multiple_sequential() {
  setup_workspace "cp-multi"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  get_history_lines; hc_before="${#HISTORY_LINES[@]}"

  checkpoint_task "First" >/dev/null || true
  checkpoint_task "Second" >/dev/null || true

  get_history_lines
  assert_eq "two new entries" "$((${#HISTORY_LINES[@]} - hc_before))" "2"
  assert_history_integrity "history after 2 checkpoints"
}


test_task_checkpoint__snapshots_work_and_advances_bookmark() {
  setup_workspace "cp-snapshot"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  edit_file "src/feature.sh" "echo feature"
  bm_before=$(get_bookmark_commit "$task_id")

  output="" exit_code=0
  output=$(checkpoint_task "Add feature") || exit_code=$?
  assert_success "checkpoint succeeds" "$exit_code"
  assert_neq "bookmark advanced" "$(get_bookmark_commit "$task_id")" "$bm_before"
  assert_file_on_branch "uncommitted work recorded on the branch" "$task_id" "src/feature.sh"
  assert_commit_message_first_line "branch tip is the checkpoint" "$task_id" \
    "[tt:task:$task_id:checkpoint] Add feature"
  assert_wc_clean "WC clean after checkpoint"
}


test_task_checkpoint__squash_collapses_commits_since_bookmark() {
  setup_workspace "cp-squash"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")

  # Two commits the bookmark does not yet track, plus uncommitted work on top.
  edit_file "one.txt" "one"
  jj_commit "raw one"
  edit_file "two.txt" "two"
  jj_commit "raw two"
  edit_file "three.txt" "three"

  output="" exit_code=0
  output=$(run_tt task checkpoint --squash -m "Collapsed" 2>&1) || exit_code=$?
  assert_success "--squash succeeds" "$exit_code"
  assert_revset_count "one commit added to the branch" \
    "${bm_before}::${task_id} ~ ${bm_before}" "1"
  assert_commit_message_first_line "branch tip is the checkpoint" "$task_id" \
    "[tt:task:$task_id:checkpoint] Collapsed"
  assert_file_on_branch "first commit's file kept" "$task_id" "one.txt"
  assert_file_on_branch "second commit's file kept" "$task_id" "two.txt"
  assert_file_on_branch "uncommitted work kept" "$task_id" "three.txt"
  assert_wc_clean "WC clean after squash checkpoint"
}


test_task_checkpoint__refuses_bookmark_on_working_copy() {
  setup_workspace "cp-bm-refusal"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  sibling_id=$(create_task "s" "S") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")

  # Clean working copy carrying the task's own bookmark: there is nothing
  # above the branch tip to record, so the checkpoint is refused rather than
  # amending the tip.
  jj -R "$REPO" bookmark set "$task_id" -r '@' >/dev/null 2>&1
  output="" exit_code=0
  output=$(checkpoint_task "On the tip") || exit_code=$?
  assert_failure "own bookmark on @ refused" "$exit_code"
  assert_contains "error names the bookmark" "$output" "tip of bookmark"

  # A bookmark for a different branch, parked on the working-copy commit: the
  # refusal covers any bookmark on @, not only the task's own.
  jj -R "$REPO" bookmark set "$task_id" -r "$bm_before" --allow-backwards >/dev/null 2>&1
  jj -R "$REPO" bookmark set "$sibling_id" -r '@' --allow-backwards >/dev/null 2>&1
  exit_code=0
  output=$(checkpoint_task "Sibling bookmark") || exit_code=$?
  assert_failure "sibling bookmark on @ refused" "$exit_code"
  assert_contains "error names the sibling bookmark" "$output" "$sibling_id"
  assert_eq "task bookmark unchanged" "$(get_bookmark_commit "$task_id")" "$bm_before"
  assert_no_pending_transaction "no transaction opened by a refusal"
}


test_task_checkpoint__omitted_message_without_terminal_fails() {
  setup_workspace "cp-no-tty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")
  wc_parent_before=$(get_full_commit_id "@-")

  output="" exit_code=0
  output=$(run_tt task checkpoint </dev/null 2>&1) || exit_code=$?
  assert_failure "checkpoint without --message fails" "$exit_code"
  assert_contains "error explains --message is required" "$output" \
    "cannot open an editor for the checkpoint message: stdin is not a terminal. Pass --message <msg>."
  assert_eq "bookmark unchanged" "$(get_bookmark_commit "$task_id")" "$bm_before"
  assert_eq "no commit recorded" "$(get_full_commit_id "@-")" "$wc_parent_before"
  assert_no_pending_transaction "no transaction opened"
}


test_task_checkpoint__omitted_message_without_terminal_ignores_single_commit_description() {
  setup_workspace "cp-no-tty-single"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")

  # A single commit since the bookmark would prefill the editor with its
  # description; without a terminal it must not be used as the message.
  edit_file "one.txt" "one"
  jj_commit "raw one"
  wc_parent_before=$(get_full_commit_id "@-")

  output="" exit_code=0
  output=$(run_tt task checkpoint </dev/null 2>&1) || exit_code=$?
  assert_failure "checkpoint without --message fails" "$exit_code"
  assert_contains "error explains --message is required" "$output" "Pass --message <msg>."
  assert_eq "bookmark unchanged" "$(get_bookmark_commit "$task_id")" "$bm_before"
  assert_eq "no commit recorded" "$(get_full_commit_id "@-")" "$wc_parent_before"
  assert_commit_message_first_line "single commit untouched" "@-" "raw one"
}


test_task_checkpoint__empty_message_cancels() {
  setup_workspace "cp-empty-message"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")
  wc_parent_before=$(get_full_commit_id "@-")

  output="" exit_code=0
  output=$(run_tt task checkpoint -m "" </dev/null 2>&1) || exit_code=$?
  assert_failure "empty message rejected" "$exit_code"
  assert_contains "reports the cancellation" "$output" "Checkpoint canceled: no message provided."
  assert_not_contains "does not ask for --message" "$output" "stdin is not a terminal"
  assert_eq "bookmark unchanged" "$(get_bookmark_commit "$task_id")" "$bm_before"
  assert_eq "no commit recorded" "$(get_full_commit_id "@-")" "$wc_parent_before"
  assert_no_pending_transaction "no transaction opened"
}


test_task_checkpoint__help() {
  setup_workspace "checkpoint-help"
  output="" exit_code=0
  output=$(run_tt task checkpoint --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task checkpoint"
  assert_required_usage_argument "argument: --message" "$output" "--message" "-m"
  assert_required_usage_argument "argument: --squash" "$output" "--squash"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


test_task_checkpoint__refuses_when_the_canonical_workspace_is_stale() {
  setup_workspace "cp-stale-canonical"
  setup_stale_canonical "checkpointed"

  assert_refuses_stale_canonical "$STALE_WORKTREE" \
    task checkpoint -m "should not be recorded"
}

run_tests "tt task checkpoint"
