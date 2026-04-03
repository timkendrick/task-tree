#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_show__show_current_task() {
  setup_workspace "show-current"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "My Task" "Task description") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "task ID in output" "$output" "task/t-"
  assert_contains "title in output" "$output" "My Task"
  assert_contains "body in output" "$output" "Task description"
}


test_task_show__explicit_task_id() {
  setup_workspace "show-explicit"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show "$task_a" 2>&1) || exit_code=$?
  assert_success "show explicit succeeds" "$exit_code"
  assert_contains "shows Task A" "$output" "Task A"
  assert_not_contains "does not show Task B title" "$output" "Task B"
}


test_task_show__task_with_subtasks() {
  setup_workspace "show-subs"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child Task") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show "$proj_id" 2>&1) || exit_code=$?
  assert_success "show with subtasks" "$exit_code"
  assert_contains "subtask listed" "$output" "child"
}


test_task_show__task_with_no_subtasks() {
  setup_workspace "show-nosub"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "no subtasks message" "$output" "No subtasks"
}


test_task_show__task_with_no_body() {
  setup_workspace "show-nobody"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T" "") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "no description message" "$output" "No description"
}


test_task_show__task_with_context() {
  setup_workspace "show-ctx"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "Context body" | run_tt task context add --title "My Ctx" --slug "ctx" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show with context" "$exit_code"
  assert_contains "context in output" "$output" "context/ctx-"
}


test_task_show__expand_context_shows_content() {
  setup_workspace "show-expand"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "Expanded body text" | run_tt task context add --title "Ctx" --slug "ctx" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task show --expand-context 2>&1) || exit_code=$?
  assert_success "expand-context succeeds" "$exit_code"
  assert_contains "context body expanded" "$output" "Expanded body text"
}


test_task_show__not_on_task_branch_fails() {
  setup_workspace "show-notask"
  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_failure "show on non-task fails" "$exit_code"
}


test_task_show__shows_parent() {
  setup_workspace "show-parent"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "parent shown" "$output" "project/proj-"
}


test_task_show__shows_labels() {
  setup_workspace "show-labels"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(run_tt task create --slug "t" --title "T" --label "bug" --label "urgent" <<< "" | tail -1) || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "bug label shown" "$output" "bug"
  assert_contains "urgent label shown" "$output" "urgent"
}


run_tests "tt task show"
