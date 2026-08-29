#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../harness/harness.sh"

test_context_delete__basic_delete() {
  setup_workspace "ctxdel-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  add_output=$(echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" 2>&1) || true
  ctx_id=$(printf '%s' "$add_output" | grep '^context/' | tail -1)

  assert_matches "context ID format" "$ctx_id" "context/ctx-"
  assert_context_entry "task has context entry" "$task_id" "$ctx_id"
  assert_context_file_exists "context file exists" "$task_id" "$ctx_id"

  output="" exit_code=0
  output=$(run_tt task context delete "$ctx_id" 2>&1) || exit_code=$?
  assert_success "delete succeeds" "$exit_code"
  assert_commit_message "commit message" "@-" "[tt:task:$task_id:context:delete] Ctx"
  assert_no_context_entry "context entry removed" "$task_id" "$ctx_id"
  assert_context_file_not_exists "context file gone" "$task_id" "$ctx_id"
}


test_context_delete__delete_from_non_checked_out_task() {
  setup_workspace "ctxdel-nocheckout"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "A") || true
  task_b=$(create_task "tb" "B") || true
  # task_b is never checked out; work continues on task_a
  checkout_task "$task_a" >/dev/null || true

  add_output=$(echo "Body for B" | run_tt task context add --title "Ctx B" --slug "ctx-b" "$task_b" 2>&1) || true
  ctx_id=$(printf '%s' "$add_output" | grep '^context/' | tail -1)
  assert_context_entry "context on task B" "$task_b" "$ctx_id"

  output="" exit_code=0
  output=$(run_tt task context delete "$ctx_id" --task "$task_b" 2>&1) || exit_code=$?
  assert_success "delete from non-checked-out task" "$exit_code"
  assert_commit_message "commit message" "$task_b" "[tt:task:$task_b:context:delete] Ctx B"
  assert_no_context_entry "context entry removed" "$task_b" "$ctx_id"
  assert_context_file_not_exists "context file gone" "$task_b" "$ctx_id"
  assert_current_task "still checked out on task A" "$task_a"
  assert_tt_workspace_integrity "workspace integrity after cross-branch context delete"
}


test_context_delete__non_existent_context_fails() {
  setup_workspace "ctxdel-noexist"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task context delete "context/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent context rejected" "$exit_code"
}


test_context_delete__missing_context_prefix() {
  setup_workspace "ctxdel-prefix"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task context delete "not-a-context-id" 2>&1) || exit_code=$?
  assert_failure "missing context/ prefix" "$exit_code"
}


test_context_delete__dirty_wc_preserved_not_absorbed() {
  setup_workspace "ctxdel-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  add_output=$(echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" 2>&1) || true
  ctx_id=$(printf '%s' "$add_output" | grep '^context/' | tail -1)
  edit_file "dirty.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt task context delete "$ctx_id" 2>&1) || exit_code=$?
  assert_success "context delete succeeds with dirty WC" "$exit_code"
  assert_no_context_entry "context entry removed" "$task_id" "$ctx_id"
  assert_file_exists "dirty file still on disk" "$REPO/dirty.txt"
  assert_wc_dirty "WC still dirty"
  modified=$(get_modified_files "$task_id")
  assert_not_contains "dirty file not in delete commit" "$modified" "dirty.txt"
  assert_file_not_on_branch "dirty file not on branch" "$task_id" "dirty.txt"
}


test_context_delete__refuses_bookmark_on_working_copy() {
  setup_workspace "ctxdel-bm-refusal"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  add_output=$(echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" 2>&1) || true
  ctx_id=$(printf '%s' "$add_output" | grep '^context/' | tail -1)

  # Clean working copy carrying the task's own bookmark
  jj -R "$REPO" bookmark set "$task_id" -r '@' >/dev/null 2>&1
  output="" exit_code=0
  output=$(run_tt task context delete "$ctx_id" 2>&1) || exit_code=$?
  assert_failure "own bookmark on @ refused" "$exit_code"
  assert_contains "error names the bookmark" "$output" "tip of bookmark"
  assert_context_entry "context entry still present" "$task_id" "$ctx_id"

  # Bookmark unrelated to the target task (explicit task-id, so the
  # working-copy guard itself is what refuses)
  jj -R "$REPO" bookmark set "$task_id" -r '@-' --allow-backwards >/dev/null 2>&1
  jj -R "$REPO" bookmark set unrelated -r '@' >/dev/null 2>&1
  exit_code=0
  output=$(run_tt task context delete "$ctx_id" --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "unrelated bookmark on @ refused" "$exit_code"
  assert_contains "error names the unrelated bookmark" "$output" "unrelated"
  assert_context_entry "context entry still present after second refusal" "$task_id" "$ctx_id"
}


test_context_delete__working_copy_commit_stays_put() {
  setup_workspace "ctxdel-wc-stays"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "A") || true
  task_b=$(create_task "tb" "B") || true
  checkout_task "$task_a" >/dev/null || true

  add_a=$(echo "Body A" | run_tt task context add --title "Ctx A" --slug "ctx-a" 2>&1) || true
  ctx_a=$(printf '%s' "$add_a" | grep '^context/' | tail -1)
  add_b=$(echo "Body B" | run_tt task context add --title "Ctx B" --slug "ctx-b" "$task_b" 2>&1) || true
  ctx_b=$(printf '%s' "$add_b" | grep '^context/' | tail -1)

  # Same-branch context delete: @ keeps its change ID and sits on the new branch tip
  change_before=$(get_wc_change_id)
  run_tt task context delete "$ctx_a" >/dev/null 2>&1 || true
  change_after=$(get_wc_change_id)
  assert_eq "same WC change after same-branch context delete" "$change_after" "$change_before"
  assert_no_context_entry "ctx A removed" "$task_a" "$ctx_a"
  parent_commit=$(jj -R "$REPO" log -r '@-' --no-graph -T 'commit_id.short(8)' 2>/dev/null)
  assert_eq "@ parent is new branch tip" "$parent_commit" "$(get_bookmark_commit "$task_a")"

  # Explicit task-id for a branch not checked out anywhere: @ entirely untouched
  wc_before=$(get_wc_commit)
  run_tt task context delete "$ctx_b" --task "$task_b" >/dev/null 2>&1 || true
  wc_after=$(get_wc_commit)
  assert_eq "@ commit unchanged after cross-branch context delete" "$wc_after" "$wc_before"
  assert_no_context_entry "ctx B removed" "$task_b" "$ctx_b"
}


test_context_delete__records_transaction() {
  setup_workspace "ctxdel-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  add_output=$(echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" 2>&1) || true
  ctx_id=$(printf '%s' "$add_output" | grep '^context/' | tail -1)

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task context delete "$ctx_id" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new history entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after context delete"
}


test_task_context_delete__help() {
  setup_workspace "ctx-delete-help"
  output="" exit_code=0
  output=$(run_tt task context delete --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task context delete"
  assert_required_usage_argument "argument: <context-id>" "$output" "<context-id>"
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


test_context_delete__preserves_other_context_entries() {
  setup_workspace "ctxdel-preserve"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  add_output1=$(echo "Body1" | run_tt task context add --title "Ctx1" --slug "ctx1" 2>&1) || true
  ctx_id1=$(printf '%s' "$add_output1" | grep '^context/' | tail -1)

  add_output2=$(echo "Body2" | run_tt task context add --title "Ctx2" --slug "ctx2" 2>&1) || true
  ctx_id2=$(printf '%s' "$add_output2" | grep '^context/' | tail -1)

  assert_matches "ctx1 ID format" "$ctx_id1" "context/ctx1-"
  assert_matches "ctx2 ID format" "$ctx_id2" "context/ctx2-"
  assert_context_entry "task has ctx1 entry" "$task_id" "$ctx_id1"
  assert_context_entry "task has ctx2 entry" "$task_id" "$ctx_id2"

  output="" exit_code=0
  output=$(run_tt task context delete "$ctx_id1" 2>&1) || exit_code=$?
  assert_success "delete ctx1 succeeds" "$exit_code"

  assert_no_context_entry "ctx1 entry removed" "$task_id" "$ctx_id1"
  assert_context_entry "ctx2 entry still present with prefix" "$task_id" "$ctx_id2"
  assert_context_file_not_exists "ctx1 file gone" "$task_id" "$ctx_id1"
  assert_context_file_exists "ctx2 file still exists" "$task_id" "$ctx_id2"
}


run_tests "tt task context delete"
