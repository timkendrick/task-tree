#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../harness/harness.sh"


test_context_add__add_context_from_stdin() {
  setup_workspace "ctxadd-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(echo "Context body text" | run_tt task context add --title "My Context" --slug "my-ctx" 2>&1) || exit_code=$?
  assert_success "context add succeeds" "$exit_code"
  assert_matches "context ID format" "$output" "context/my-ctx-"

  # Extract context ID from output
  ctx_id=$(printf '%s' "$output" | grep '^context/' | tail -1)

  assert_context_entry "task has context entry" "$task_id" "$ctx_id"
  assert_context_file_exists "context file exists" "$task_id" "$ctx_id"
}


test_context_add__add_to_explicit_task_id() {
  setup_workspace "ctxadd-explicit"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "A") || true
  task_b=$(create_task "tb" "B") || true
  checkout_task "$task_a" >/dev/null || true

  output="" exit_code=0
  output=$(echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" "$task_a" 2>&1) || exit_code=$?
  assert_success "context add to explicit task" "$exit_code"

  ctx_id=$(printf '%s' "$output" | grep '^context/' | tail -1)
  assert_context_entry "context on task A" "$task_a" "$ctx_id"
}


test_context_add__add_to_non_checked_out_task() {
  setup_workspace "ctxadd-nocheckout"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "A") || true
  task_b=$(create_task "tb" "B") || true
  # task_b is never checked out; work continues on task_a
  checkout_task "$task_a" >/dev/null || true

  output="" exit_code=0
  output=$(echo "Body for B" | run_tt task context add --title "Ctx B" --slug "ctx-b" "$task_b" 2>&1) || exit_code=$?
  assert_success "context add to non-checked-out task" "$exit_code"

  ctx_id=$(printf '%s' "$output" | grep '^context/' | tail -1)
  assert_context_entry "context on task B" "$task_b" "$ctx_id"
  assert_context_file_exists "context file on task B" "$task_b" "$ctx_id"
  assert_no_context_entry "task A untouched" "$task_a" "$ctx_id"
  assert_current_task "still checked out on task A" "$task_a"
  assert_tt_workspace_integrity "workspace integrity after cross-branch context add"
}


test_context_add__empty_body_rejected() {
  setup_workspace "ctxadd-empty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(echo "" | run_tt task context add --title "Ctx" --slug "ctx" 2>&1) || exit_code=$?
  assert_failure "empty body rejected" "$exit_code"
}


test_context_add__dirty_wc_rejected() {
  setup_workspace "ctxadd-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  edit_file "dirty.txt" "dirty"

  output="" exit_code=0
  output=$(echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
}


test_context_add__multiple_contexts_on_same_task() {
  setup_workspace "ctxadd-multi"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  echo "Body 1" | run_tt task context add --title "Ctx 1" --slug "ctx1" >/dev/null 2>&1 || true
  echo "Body 2" | run_tt task context add --title "Ctx 2" --slug "ctx2" >/dev/null 2>&1 || true

  assert_context_count "two contexts" "$task_id" "2"
}


test_context_add__records_transaction() {
  setup_workspace "ctxadd-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after context add"
}


test_task_context_add__help() {
  setup_workspace "ctx-add-help"
  output="" exit_code=0
  output=$(run_tt task context add --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task context add"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_required_usage_argument "argument: --title" "$output" "--title"
  assert_required_usage_argument "argument: --slug" "$output" "--slug"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
}


test_context_add__context_inserted_before_subtask() {
  setup_workspace "ctxadd-order"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  # Create a child so the parent task has a subtask: entry
  create_task_under "$task_id" "child" "Child" >/dev/null || true
  checkout_task "$task_id" >/dev/null || true

  # Add context — must appear before the subtask entry
  echo "Body" | run_tt task context add --title "Research" --slug "research" >/dev/null 2>&1 || true

  content="$(read_task_file "$task_id")"
  assert_frontmatter_order "valid order after context add on task with subtask" "$content"
}

run_tests "tt task context add"
