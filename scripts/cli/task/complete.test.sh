#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"

test_task_complete__complete_current_task() {
  setup_workspace "done-current"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(complete_task) || exit_code=$?
  assert_success "complete succeeds" "$exit_code"
  assert_task_status "DONE" "$task_id" "DONE"
  assert_commit_message "commit message" "@-" "[tt:task:$task_id:complete] T"
  assert_wc_clean "WC clean"
}


test_task_complete__body_fence_subtask_not_a_precondition() {
  setup_workspace "done-body-fence"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  # An incomplete-looking subtask entry inside a body code fence must not block
  # completion: the task genuinely has no subtasks.
  body=$(printf '%s\n' \
    'Subtask entries look like:' \
    '' \
    '```markdown' \
    '---' \
    'subtask: [ ] task/fake-99999999 Fake' \
    '---' \
    '```')
  task_id=$(create_task "t" "T" "$body") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(complete_task) || exit_code=$?
  assert_success "complete succeeds without --force" "$exit_code"
  assert_task_status "DONE" "$task_id" "DONE"
}


test_task_complete__explicit_task_id_cross_branch() {
  setup_workspace "done-cross"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task complete "$task_id" 2>&1) || exit_code=$?
  assert_success "cross-branch complete" "$exit_code"
  assert_task_status "DONE on branch" "$task_id" "DONE"
  assert_current_task "WC on parent" "$proj_id"
}


test_task_complete__already_done_is_no_op() {
  setup_workspace "done-already"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")

  output="" exit_code=0
  output=$(complete_task) || exit_code=$?
  assert_success "second complete succeeds" "$exit_code"
  assert_contains "already DONE" "$output" "DONE"
  bm_after=$(get_bookmark_commit "$task_id")
  assert_eq "bookmark unchanged" "$bm_before" "$bm_after"
}


test_task_complete__incomplete_subtasks_fails_without_force() {
  setup_workspace "done-subtasks"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  parent=$(create_task "parent" "P") || true
  checkout_task "$parent" >/dev/null || true
  child_a=$(create_task "ca" "CA") || true
  child_b=$(create_task "cb" "CB") || true
  run_tt task complete "$child_a" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task complete "$parent" 2>&1) || exit_code=$?
  assert_failure "incomplete subtasks rejected" "$exit_code"

  exit_code=0
  output=$(run_tt task complete "$parent" --force 2>&1) || exit_code=$?
  assert_success "--force succeeds" "$exit_code"
  assert_task_status "parent DONE" "$parent" "DONE"
}


test_task_complete__records_transaction() {
  setup_workspace "done-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  complete_task >/dev/null || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after complete"
}


test_task_complete__refuses_bookmark_on_working_copy() {
  setup_workspace "done-bm-refusal"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  # Clean working copy carrying the task's own bookmark
  jj -R "$REPO" bookmark set "$task_id" -r '@' >/dev/null 2>&1
  output="" exit_code=0
  output=$(complete_task) || exit_code=$?
  assert_failure "own bookmark on @ refused" "$exit_code"
  assert_contains "error names the bookmark" "$output" "tip of bookmark"
  status=$(get_frontmatter_field "$(read_task_file "$task_id")" "status")
  assert_neq "status not DONE" "$status" "DONE"

  # Bookmark unrelated to the completion target (explicit task-id, so the
  # working-copy guard itself is what refuses)
  jj -R "$REPO" bookmark set "$task_id" -r '@-' --allow-backwards >/dev/null 2>&1
  jj -R "$REPO" bookmark set unrelated -r '@' >/dev/null 2>&1
  exit_code=0
  output=$(complete_task "$task_id") || exit_code=$?
  assert_failure "unrelated bookmark on @ refused" "$exit_code"
  assert_contains "error names the unrelated bookmark" "$output" "unrelated"
  status=$(get_frontmatter_field "$(read_task_file "$task_id")" "status")
  assert_neq "status still not DONE" "$status" "DONE"
}


test_task_complete__dirty_wc_preserved_not_absorbed() {
  setup_workspace "done-dirty-keep"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  edit_file "scratch.txt" "uncommitted scratch"

  output="" exit_code=0
  output=$(complete_task) || exit_code=$?
  assert_success "complete succeeds with dirty WC" "$exit_code"
  assert_task_status "DONE" "$task_id" "DONE"
  assert_file_exists "dirty file still on disk" "$REPO/scratch.txt"
  assert_wc_dirty "WC still dirty"
  modified=$(get_modified_files "$task_id")
  assert_not_contains "dirty file not in complete commit" "$modified" "scratch.txt"
  assert_file_not_on_branch "dirty file not on branch" "$task_id" "scratch.txt"
}


test_task_complete__working_copy_commit_stays_put() {
  setup_workspace "done-wc-stays"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "A") || true
  task_b=$(create_task "tb" "B") || true
  checkout_task "$task_a" >/dev/null || true

  # Same-branch complete: @ keeps its change ID and sits on the new branch tip
  change_before=$(get_wc_change_id)
  complete_task >/dev/null 2>&1 || true
  change_after=$(get_wc_change_id)
  assert_eq "same WC change after same-branch complete" "$change_after" "$change_before"
  assert_task_status "task A DONE" "$task_a" "DONE"
  parent_commit=$(jj -R "$REPO" log -r '@-' --no-graph -T 'commit_id.short(8)' 2>/dev/null)
  assert_eq "@ parent is new branch tip" "$parent_commit" "$(get_bookmark_commit "$task_a")"

  # Explicit task-id for a branch not checked out anywhere: @ entirely untouched
  wc_before=$(get_wc_commit)
  run_tt task complete "$task_b" >/dev/null 2>&1 || true
  wc_after=$(get_wc_commit)
  assert_eq "@ commit unchanged after cross-branch complete" "$wc_after" "$wc_before"
  assert_task_status "task B DONE" "$task_b" "DONE"
}


test_task_complete__help() {
  setup_workspace "complete-help"
  output="" exit_code=0
  output=$(run_tt task complete --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task complete"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_required_usage_argument "argument: --force" "$output" "--force"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


test_task_complete__refuses_when_the_canonical_workspace_is_stale() {
  setup_workspace "complete-stale-canonical"
  setup_stale_canonical "completed"

  assert_refuses_stale_canonical "$STALE_WORKTREE" \
    task complete "$STALE_TASK_ID"
}

run_tests "tt task complete"
