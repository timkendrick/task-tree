#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


# Usage: table_row MARKER ID TYPE STATUS TITLE
# Prints one row of the table for a workspace whose IDs are all 21 characters
# wide or less, and whose statuses are all 11 characters wide or less.
table_row() {
  printf '%-2s%-21s  %-7s  %-11s  %s\n' "$1" "$2" "$3" "$4" "$5"
}


test_task_list__table_sorted_with_current_task_marked() {
  setup_workspace "list-table"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_z=$(create_task "zzz" "Task Z") || true
  task_a=$(create_task "aaa" "Task A") || true

  output="" exit_code=0
  output=$(run_tt task list 2>/dev/null) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_eq "table sorted by ID with the current task marked" "$output" "$(
    table_row '' ID TYPE STATUS TITLE
    table_row '*' "$proj_id" project IN-PROGRESS Project
    table_row '' "$task_a" task TODO 'Task A'
    table_row '' "$task_z" task TODO 'Task Z'
  )"
}


test_task_list__no_marker_without_current_task() {
  setup_workspace "list-no-current"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt task list 2>/dev/null) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "project listed" "$output" "$proj_id"
  assert_not_matches "no row is marked" "$output" '^\*'
}


test_task_list__quiet_prints_sorted_ids() {
  setup_workspace "list-quiet"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_z=$(create_task "zzz" "Task Z") || true
  task_a=$(create_task "aaa" "Task A") || true

  output="" exit_code=0
  output=$(run_tt task list --quiet 2>/dev/null) || exit_code=$?
  assert_success "list --quiet succeeds" "$exit_code"
  assert_eq "IDs sorted, one per line" "$output" \
    "$(printf '%s\n' "$proj_id" "$task_a" "$task_z")"
}


test_task_list__no_tasks_prints_header_only() {
  setup_workspace "list-empty"

  output="" exit_code=0
  output=$(run_tt task list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_eq "header alone" "$output" "  ID  TYPE  STATUS  TITLE"

  exit_code=0
  output=$(run_tt task list --quiet 2>&1) || exit_code=$?
  assert_success "list --quiet succeeds" "$exit_code"
  assert_output_empty "nothing printed with --quiet" "$output"
}


test_task_list__no_match_prints_header_only() {
  setup_workspace "list-no-match"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt task list --status done 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_eq "header alone" "$output" "  ID  TYPE  STATUS  TITLE"

  exit_code=0
  output=$(run_tt task list --status done --quiet 2>&1) || exit_code=$?
  assert_success "list --quiet succeeds" "$exit_code"
  assert_output_empty "nothing printed with --quiet" "$output"
}


test_task_list__type_filter() {
  setup_workspace "list-type"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Task") || true

  output=""
  output=$(run_tt task list --type project --quiet 2>/dev/null) || true
  assert_eq "--type project lists projects only" "$output" "$proj_id"

  output=$(run_tt task list --type task --quiet 2>/dev/null) || true
  assert_eq "--type task lists tasks only" "$output" "$task_id"

  output=$(run_tt task list --type task --type project --quiet 2>/dev/null) || true
  assert_eq "repeated --type lists either type" "$output" \
    "$(printf '%s\n' "$proj_id" "$task_id")"
}


test_task_list__status_filter() {
  setup_workspace "list-status"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  done_task=$(create_task "done-task" "Done Task") || true
  checkout_task "$done_task" || true
  complete_task >/dev/null || true
  checkout_task "$proj_id" || true
  todo_task=$(create_task "todo-task" "Todo Task") || true

  output=""
  output=$(run_tt task list --status DONE --quiet 2>/dev/null) || true
  assert_eq "--status DONE lists completed tasks" "$output" "$done_task"

  output=$(run_tt task list --status todo --quiet 2>/dev/null) || true
  assert_eq "lowercase status matches" "$output" "$todo_task"

  output=$(run_tt task list --status inprogress --quiet 2>/dev/null) || true
  assert_eq "status without hyphen matches" "$output" "$proj_id"

  output=$(run_tt task list --status In-Progress --quiet 2>/dev/null) || true
  assert_eq "mixed-case status with hyphen matches" "$output" "$proj_id"

  output=$(run_tt task list --status todo --status in-progress --quiet 2>/dev/null) || true
  assert_eq "repeated --status lists either status" "$output" \
    "$(printf '%s\n' "$proj_id" "$todo_task" | LC_ALL=C sort)"
}


test_task_list__combined_filters() {
  setup_workspace "list-combined"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Task") || true

  output=""
  output=$(run_tt task list --type task --status in-progress --quiet 2>/dev/null) || true
  assert_output_empty "no task matches both filters" "$output"

  output=$(run_tt task list --type project --status in-progress --quiet 2>/dev/null) || true
  assert_eq "the project matches both filters" "$output" "$proj_id"

  output=$(run_tt task list --type task --status todo --quiet 2>/dev/null) || true
  assert_eq "the task matches both filters" "$output" "$task_id"
}


test_task_list__checked_in_task_without_bookmark_listed() {
  setup_workspace "list-no-bookmark"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Task") || true
  checkout_task "$task_id" || true
  checkin_task --complete >/dev/null || true
  checkout_task "$proj_id" || true
  jj -R "$REPO" bookmark delete "$task_id" >/dev/null 2>&1

  output=""
  output=$(run_tt task list --status done --quiet 2>/dev/null) || true
  assert_eq "completed task listed from the parent's copy" "$output" "$task_id"
}


test_task_list__unreadable_task_listed_without_status() {
  setup_workspace "list-unreadable"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Task") || true
  jj -R "$REPO" bookmark delete "$task_id" >/dev/null 2>&1

  local err="$_TEST_ROOT/list-err.txt" output="" exit_code=0
  output=$(run_tt task list 2>"$err") || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_matches "unreadable task listed without status" "$output" \
    "^  $task_id +task +\\(none\\)\$"
  assert_contains "warning names the task" "$(cat "$err")" \
    "Warning: Cannot read the task file of '$task_id'."

  output=$(run_tt task list --status '' --quiet 2>/dev/null) || true
  assert_eq "--status '' selects the unreadable task" "$output" "$task_id"
}


test_task_list__invalid_arguments_rejected() {
  setup_workspace "list-invalid"
  output="" exit_code=0

  output=$(run_tt task list --type other 2>&1) || exit_code=$?
  assert_exit_code "--type other rejected" "$exit_code" 1
  assert_contains "error names the accepted types" "$output" \
    "Error: Invalid type 'other'. Expected one of: project, task."

  exit_code=0
  output=$(run_tt task list --type Project 2>&1) || exit_code=$?
  assert_exit_code "--type is case-sensitive" "$exit_code" 1

  exit_code=0
  output=$(run_tt task list --status blocked 2>&1) || exit_code=$?
  assert_exit_code "unknown status rejected" "$exit_code" 1
  assert_contains "error names the accepted statuses" "$output" \
    "Error: Invalid status 'blocked'. Expected one of: TODO, IN-PROGRESS, DONE, ''."

  exit_code=0
  output=$(run_tt task list --status 2>&1) || exit_code=$?
  assert_exit_code "--status without a value rejected" "$exit_code" 1

  exit_code=0
  output=$(run_tt task list --all 2>&1) || exit_code=$?
  assert_exit_code "--all rejected" "$exit_code" 1
}


test_task_list__alias() {
  setup_workspace "list-alias"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt list --quiet 2>/dev/null) || exit_code=$?
  assert_success "alias succeeds" "$exit_code"
  assert_eq "alias lists the project" "$output" "$proj_id"
}


test_task_list__help() {
  setup_workspace "list-help"
  output="" exit_code=0
  output=$(run_tt task list --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task list"
  assert_optional_usage_argument "argument: --type" "$output" "--type"
  assert_optional_usage_argument "argument: --status" "$output" "--status"
  assert_optional_usage_argument "argument: --quiet" "$output" "--quiet"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
}



test_task_list__warns_about_malformed_subtask_entries() {
  setup_workspace "task_list-malformed"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child Task") || true
  local file="$REPO/.tt/task/${proj_id#project/}/TASK.md"
  awk '/^subtask: / { print "subtask: not-an-entry" } { print }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  jj -R "$REPO" commit -m "malformed entry" >/dev/null 2>&1
  jj -R "$REPO" bookmark set "$proj_id" -r '@-' >/dev/null 2>&1

  local err="$_TEST_ROOT/task_list-err.txt" output="" exit_code=0
  output=$(run_tt task list 2>"$err") || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "well-formed subtask listed" "$output" "$child"
  assert_eq "warning names the entry and the task" "$(cat "$err")" \
    "Warning: Ignoring a malformed subtask entry 'not-an-entry' in the task file of '$proj_id'."
}

run_tests "tt task list"
