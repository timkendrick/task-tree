#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"

# Usage: parent_ids REV
# Prints REV's parent commit IDs, space-separated, in parent order.
parent_ids() {
  jj -R "$REPO" log -r "$1" --no-graph -T 'parents.map(|c| c.commit_id()).join(" ")' 2>/dev/null
}

# Usage: install_hook NAME BODY
# Writes an executable hook into the working copy; callers commit it.
install_hook() {
  mkdir -p "$REPO/.tt/hooks"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$REPO/.tt/hooks/$1"
  chmod +x "$REPO/.tt/hooks/$1"
}

setup_checkpoint_task() {
  setup_workspace "$1"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
}

test_task_checkpoint__basic_with_message() {
  setup_checkpoint_task "cp-basic"

  output="" exit_code=0
  output=$(checkpoint_task "Test cp") || exit_code=$?
  assert_success "checkpoint succeeds" "$exit_code"
  assert_commit_message_first_line "commit message" "@-" "[tt:task:$task_id:checkpoint] Test cp"
  assert_wc_clean "WC clean after checkpoint"
}


test_task_checkpoint__merges_commits_after_the_bookmark() {
  setup_checkpoint_task "cp-merge"
  bm_before=$(get_bookmark_commit "$task_id")

  edit_file "one.txt" "one"
  jj_commit "raw one"
  edit_file "two.txt" "two"
  jj_commit "raw two"
  head=$(get_full_commit_id "@-")

  output="" exit_code=0
  output=$(run_tt task checkpoint -m "Add files" 2>&1) || exit_code=$?
  assert_success "checkpoint succeeds" "$exit_code"

  checkpoint=$(get_full_commit_id "$task_id")
  assert_commit_message_first_line "branch tip is the checkpoint" "$task_id" \
    "[tt:task:$task_id:checkpoint] Add files"
  merge=$(parent_ids "$checkpoint")
  assert_commit_message_first_line "checkpoint sits on the merge, described by the task title" \
    "$merge" "[tt:task:$task_id:merge] T"
  assert_eq "merge lists the old bookmark first and the merged work second" \
    "$(parent_ids "$merge")" "$(get_full_commit_id "$bm_before") $head"
  assert_revset_count "the checkpoint changes no files" "$checkpoint & empty()" "1"
  assert_revset_count "the merge changes no files" "$merge & empty()" "1"
  assert_file_on_branch "first commit's file on the branch" "$task_id" "one.txt"
  assert_file_on_branch "second commit's file on the branch" "$task_id" "two.txt"
  assert_eq "working copy sits on the checkpoint" "$(get_full_commit_id "@-")" "$checkpoint"
  assert_wc_clean "WC clean after checkpoint"
}


test_task_checkpoint__nothing_to_merge_records_a_single_commit() {
  setup_checkpoint_task "cp-empty"
  bm_before=$(get_bookmark_commit "$task_id")

  output="" exit_code=0
  output=$(run_tt task checkpoint -m "Milestone" 2>&1) || exit_code=$?
  assert_success "checkpoint succeeds" "$exit_code"
  assert_commit_message_first_line "branch tip is the checkpoint" "$task_id" \
    "[tt:task:$task_id:checkpoint] Milestone"
  assert_eq "checkpoint sits directly on the old bookmark" \
    "$(parent_ids "$task_id")" "$(get_full_commit_id "$bm_before")"
  assert_revset_count "no merge commit recorded" \
    "${bm_before}::${task_id} & description(substring:':merge]')" "0"
  assert_eq "working copy sits on the checkpoint" \
    "$(get_full_commit_id "@-")" "$(get_full_commit_id "$task_id")"
}


test_task_checkpoint__refuses_uncommitted_changes() {
  setup_checkpoint_task "cp-dirty"
  edit_file "$REPO/work.txt" "work"

  assert_refuses_without_writing "uncommitted work" "has uncommitted changes" \
    task checkpoint -m "work"
  assert_file_exists "the uncommitted work is kept" "$REPO/work.txt"
}


test_task_checkpoint__refuses_commits_that_change_task_metadata() {
  setup_checkpoint_task "cp-metadata-commit"
  edit_task_file "$task_id"
  edit_file "$REPO/src.txt" "project work"
  jj_commit "mixed work"

  assert_refuses_without_writing "task file edited in a commit" \
    "change task metadata" \
    task checkpoint -m "work"
  output=$(run_tt task checkpoint -m "work" 2>&1) || true
  assert_contains "names the offending path" "$output" ".tt/task/${task_id#*/}/TASK.md"
}


test_task_checkpoint__refuses_a_conflicting_merge() {
  setup_checkpoint_task "cp-conflict"
  edit_file "$REPO/shared.txt" "base"
  checkpoint_task "Base" >/dev/null || true

  edit_file "$REPO/shared.txt" "side"
  jj_commit "side change"
  side=$(get_full_commit_id "@-")

  # Advance the bookmark past a conflicting change of its own.
  jj -R "$REPO" new "$task_id" >/dev/null 2>&1
  edit_file "$REPO/shared.txt" "main"
  jj_commit "main change"
  jj -R "$REPO" bookmark set "$task_id" -r '@-' >/dev/null 2>&1
  jj -R "$REPO" new "$side" >/dev/null 2>&1
  bm_before=$(get_bookmark_commit "$task_id")

  output="" exit_code=0
  output=$(run_tt task checkpoint -m "Conflicted" 2>&1) || exit_code=$?
  assert_failure "conflicting merge refused" "$exit_code"
  assert_contains "reports the conflict" "$output" "produces conflicts"
  assert_eq "bookmark unchanged" "$(get_bookmark_commit "$task_id")" "$bm_before"
  assert_no_pending_transaction "transaction rolled back"
}


test_task_checkpoint__explicit_task_records_an_empty_checkpoint() {
  setup_checkpoint_task "cp-explicit"
  bm_before=$(get_bookmark_commit "$task_id")
  edit_file "$REPO/work.txt" "uncommitted"

  output="" exit_code=0
  output=$(run_tt task checkpoint --task "$task_id" -m "Milestone" 2>&1) || exit_code=$?
  assert_success "explicit checkpoint succeeds with a dirty working copy" "$exit_code"
  assert_commit_message_first_line "branch tip is the checkpoint" "$task_id" \
    "[tt:task:$task_id:checkpoint] Milestone"
  assert_eq "checkpoint sits directly on the old bookmark" \
    "$(parent_ids "$task_id")" "$(get_full_commit_id "$bm_before")"
  assert_revset_count "the checkpoint changes no files" "$task_id & empty()" "1"
  assert_eq "working copy carried onto the checkpoint" \
    "$(get_full_commit_id "@-")" "$(get_full_commit_id "$task_id")"
  assert_eq "uncommitted work kept in the working copy" "$(cat "$REPO/work.txt")" "uncommitted"
}


test_task_checkpoint__explicit_task_writes_a_branch_not_checked_out() {
  setup_workspace "cp-explicit-other"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  proj_before=$(get_bookmark_commit "$proj_id")
  wc_parent_before=$(get_full_commit_id "@-")

  output="" exit_code=0
  output=$(run_tt task checkpoint --task "$task_id" -m "Elsewhere" 2>&1) || exit_code=$?
  assert_success "checkpoint succeeds" "$exit_code"
  assert_commit_message_first_line "task branch tip is the checkpoint" "$task_id" \
    "[tt:task:$task_id:checkpoint] Elsewhere"
  assert_eq "project bookmark unchanged" "$(get_bookmark_commit "$proj_id")" "$proj_before"
  assert_eq "working copy not moved" "$(get_full_commit_id "@-")" "$wc_parent_before"
}


test_task_checkpoint__explicit_task_must_exist() {
  setup_checkpoint_task "cp-explicit-missing"
  output="" exit_code=0
  output=$(run_tt task checkpoint --task "task/missing-0a1b2c3d" -m "Nope" 2>&1) || exit_code=$?
  assert_failure "unknown task refused" "$exit_code"
  assert_contains "names the missing bookmark" "$output" "task/missing-0a1b2c3d"
}


test_task_checkpoint__not_on_task_branch_fails() {
  setup_workspace "cp-notask"
  output="" exit_code=0
  output=$(checkpoint_task "Should fail") || exit_code=$?
  assert_failure "checkpoint on non-task fails" "$exit_code"
}


test_task_checkpoint__multiple_sequential() {
  setup_checkpoint_task "cp-multi"
  get_history_lines; hc_before="${#HISTORY_LINES[@]}"

  run_tt task checkpoint -m "First" >/dev/null 2>&1 || true
  run_tt task checkpoint -m "Second" >/dev/null 2>&1 || true

  get_history_lines
  assert_eq "two new entries" "$((${#HISTORY_LINES[@]} - hc_before))" "2"
  assert_history_integrity "history after 2 checkpoints"
}


test_task_checkpoint__runs_merge_hooks_before_checkpoint_hooks() {
  setup_checkpoint_task "cp-hooks"
  local log="$_TEST_ROOT/cp-hooks.log"
  local name
  for name in pre-merge post-merge pre-checkpoint post-checkpoint; do
    install_hook "$name" "printf '%s %s\\n' '$name' \"\${TT_COMMIT:-}\" >> '$log'"
  done
  jj_commit "Install hooks"
  head=$(get_full_commit_id "@-")

  output="" exit_code=0
  output=$(run_tt task checkpoint -m "Hooked" 2>&1) || exit_code=$?
  assert_success "checkpoint succeeds" "$exit_code"
  merge=$(parent_ids "$task_id")
  assert_eq "hooks run merge first, then checkpoint" "$(cut -d' ' -f1 "$log" | tr '\n' ' ')" \
    "pre-merge post-merge pre-checkpoint post-checkpoint "
  assert_contains "post-merge receives the merge commit" "$(cat "$log")" "post-merge $merge"
  assert_contains "post-checkpoint receives the checkpoint commit" "$(cat "$log")" \
    "post-checkpoint $(get_full_commit_id "$task_id")"
}


test_task_checkpoint__failing_post_merge_hook_rolls_back() {
  setup_checkpoint_task "cp-post-merge-fails"
  install_hook "post-merge" "exit 1"
  jj_commit "Install hook"
  bm_before=$(get_bookmark_commit "$task_id")

  output="" exit_code=0
  output=$(run_tt task checkpoint -m "Blocked" 2>&1) || exit_code=$?
  assert_failure "checkpoint refused by post-merge" "$exit_code"
  assert_eq "bookmark unchanged" "$(get_bookmark_commit "$task_id")" "$bm_before"
  assert_no_pending_transaction "transaction rolled back"
}


test_task_checkpoint__no_merge_hooks_without_commits_to_merge() {
  setup_checkpoint_task "cp-no-merge-hooks"
  local log="$_TEST_ROOT/cp-no-merge-hooks.log"
  local name
  for name in pre-merge post-merge pre-checkpoint; do
    install_hook "$name" "printf '%s\\n' '$name' >> '$log'"
  done
  jj_commit "Install hooks"
  checkpoint_task "With hooks" >/dev/null || true
  : > "$log"

  output="" exit_code=0
  output=$(run_tt task checkpoint -m "Nothing to merge" 2>&1) || exit_code=$?
  assert_success "checkpoint succeeds" "$exit_code"
  assert_eq "only the checkpoint hook ran" "$(cat "$log")" "pre-checkpoint"
}


test_task_checkpoint__refuses_bookmark_on_working_copy() {
  setup_workspace "cp-bm-refusal"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  sibling_id=$(create_task "s" "S") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")

  # Clean working copy carrying the task's own bookmark.
  jj -R "$REPO" bookmark set "$task_id" -r '@' >/dev/null 2>&1
  output="" exit_code=0
  output=$(run_tt task checkpoint -m "On the tip" 2>&1) || exit_code=$?
  assert_failure "own bookmark on @ refused" "$exit_code"
  assert_contains "error names the bookmark" "$output" "tip of bookmark"

  # A bookmark for a different branch, parked on the working-copy commit: the
  # refusal covers any bookmark on @, not only the task's own.
  jj -R "$REPO" bookmark set "$task_id" -r "$bm_before" --allow-backwards >/dev/null 2>&1
  jj -R "$REPO" bookmark set "$sibling_id" -r '@' --allow-backwards >/dev/null 2>&1
  exit_code=0
  output=$(run_tt task checkpoint -m "Sibling bookmark" 2>&1) || exit_code=$?
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
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


test_task_checkpoint__refuses_when_the_canonical_workspace_is_stale() {
  setup_workspace "cp-stale-canonical"
  setup_stale_canonical "checkpointed"

  assert_refuses_stale_canonical "$STALE_WORKTREE" \
    task checkpoint -m "should not be recorded"
}


# ---------------------------------------------------------------------------
# Working-copy guards
# ---------------------------------------------------------------------------

test_task_checkpoint__refuses_uncommitted_task_metadata_edits() {
  setup_workspace "checkpoint-guard-meta"
  setup_working_copy_guard_fixture
  edit_task_file "$GUARD_TASK_ID"
  edit_file "$REPO/src.txt" "project work"

  assert_refuses_without_writing "task file edited by hand" \
    "has uncommitted changes to task metadata" \
    task checkpoint -m "work"
  assert_file_exists "the uncommitted work is kept" "$REPO/src.txt"
}

test_task_checkpoint__records_configuration_edits() {
  setup_workspace "checkpoint-guard-config"
  setup_working_copy_guard_fixture
  append_file "$REPO/.tt/config.toml" "# tweak"
  jj_commit "Tweak config"

  local exit_code=0
  run_tt task checkpoint -m "Tweak config" >/dev/null 2>&1 || exit_code=$?
  assert_success "configuration edits are not task metadata" "$exit_code"
  assert_contains "the edit was merged into the branch" \
    "$(read_file_at_rev "$GUARD_TASK_ID" .tt/config.toml)" "# tweak"
}

run_tests "tt task checkpoint"
