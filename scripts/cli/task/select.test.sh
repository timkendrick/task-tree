#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"

# ---------------------------------------------------------------------------
# tt task select
#
# The picker UI is supplied by $TT_SELECT (run via `sh -c`, options on stdin,
# selection on stdout), which lets these tests drive the command end-to-end
# without an interactive terminal.
# ---------------------------------------------------------------------------

# Capture the option list that tt task select hands to the picker, and select
# the first option. Usage: capture_options_and_pick_first CAPTURE_FILE
capture_options_and_pick_first() {
  printf "cat > '%s'; head -n 1 '%s'" "$1" "$1"
}


test_task_select__custom_picker_returns_selection() {
  setup_workspace "select-custom-picker"
  proj_id=$(create_project "proj" "Project")

  output="" exit_code=0
  output=$(TT_SELECT='grep -x "'"$proj_id"'"' run_tt task select 2>/dev/null) || exit_code=$?
  assert_success "select succeeds" "$exit_code"
  assert_eq "selected project id" "$output" "$proj_id"
}


test_task_select__lists_projects_and_tasks_sorted() {
  setup_workspace "select-sorted"
  proj_id=$(create_project "proj" "Project")
  checkout_task "$proj_id"
  task_z=$(create_task "zzz" "Task Z")
  checkout_task "$proj_id"
  task_a=$(create_task "aaa" "Task A")
  checkout_task "$proj_id"

  capture="$(mktemp)"
  output=$(TT_SELECT="$(capture_options_and_pick_first "$capture")" run_tt task select 2>/dev/null)

  options="$(cat "$capture")"
  assert_contains "includes project" "$options" "$proj_id"
  assert_contains "includes task zzz" "$options" "$task_z"
  assert_contains "includes task aaa" "$options" "$task_a"
  assert_eq "options are sorted" "$options" "$(printf '%s\n' "$options" | sort)"
  assert_eq "first option selected" "$output" "$(printf '%s\n' "$options" | head -n 1)"
}


test_task_select__done_tasks_excluded() {
  setup_workspace "select-done"
  proj_id=$(create_project "proj" "Project")
  checkout_task "$proj_id"

  done_task=$(create_task "done-task" "Done Task")
  checkout_task "$done_task"
  run_tt task complete >/dev/null 2>&1

  checkout_task "$proj_id"
  active_task=$(create_task "active" "Active Task")
  checkout_task "$proj_id"

  capture="$(mktemp)"
  TT_SELECT="$(capture_options_and_pick_first "$capture")" run_tt task select >/dev/null 2>&1

  options="$(cat "$capture")"
  assert_contains "active task listed" "$options" "$active_task"
  assert_not_contains "done task not listed" "$options" "$done_task"
}


test_task_select__invalid_picker_output_fails() {
  setup_workspace "select-invalid"
  create_project "proj" "Project" >/dev/null

  output="" exit_code=0
  output=$(TT_SELECT='echo task/not-a-real-task' run_tt task select 2>&1) || exit_code=$?
  assert_failure "invalid selection fails" "$exit_code"
  assert_contains "error message" "$output" "invalid selection"
}


test_task_select__no_active_tasks_fails() {
  setup_workspace "select-empty"
  proj_id=$(create_project "proj" "Project")
  checkout_task "$proj_id"
  run_tt task complete >/dev/null 2>&1

  output="" exit_code=0
  output=$(TT_SELECT='head -n 1' run_tt task select 2>&1) || exit_code=$?
  assert_failure "no active items fails" "$exit_code"
  assert_contains "error message" "$output" "No active tasks or projects found"
}


test_task_select__help() {
  setup_workspace "select-help"
  output="" exit_code=0
  output=$(run_tt task select --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task select"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
  assert_contains "documents TT_SELECT" "$output" "TT_SELECT"
}


run_tests "tt task select"
