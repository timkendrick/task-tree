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
  assert_commit_message "commit has Delete context" "@-" "Delete context"
  assert_no_context_entry "context entry removed" "$task_id" "$ctx_id"
  assert_context_file_not_exists "context file gone" "$task_id" "$ctx_id"
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


test_context_delete__dirty_wc_rejected() {
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
  assert_failure "dirty WC rejected" "$exit_code"
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
