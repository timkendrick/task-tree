#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_prompt__basic_prompt_output() {
  setup_workspace "prompt-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "My Task" "Task body text") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task prompt 2>&1) || exit_code=$?
  assert_success "prompt succeeds" "$exit_code"
  assert_contains "starts with Implement task" "$output" "Implement task: My Task"
  assert_contains "task ID in frontmatter" "$output" "task:"
  assert_contains "body present" "$output" "Task body text"
  assert_contains "commands section" "$output" "tt task tree --focus"
  assert_contains "current command" "$output" "tt task current"
  assert_contains "parent command" "$output" "tt task parent"
}


test_task_prompt__message() {
  setup_workspace "prompt-msg"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task prompt --message "Extra instructions here" 2>&1) || exit_code=$?
  assert_success "prompt with message succeeds" "$exit_code"
  assert_contains "extra message present" "$output" "Extra instructions here"
}


test_task_prompt__explicit_task_id() {
  setup_workspace "prompt-explicit"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "tb" "Task B" "Body B") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task prompt "$task_b" 2>&1) || exit_code=$?
  assert_success "prompt explicit succeeds" "$exit_code"
  assert_contains "shows Task B" "$output" "Task B"
  assert_contains "body B" "$output" "Body B"
}


test_task_prompt__no_context() {
  setup_workspace "prompt-noctx"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task prompt 2>&1) || exit_code=$?
  assert_success "prompt succeeds" "$exit_code"
  assert_contains "commands section" "$output" "tt task current"
}


test_task_prompt__not_on_task_branch_fails() {
  setup_workspace "prompt-notask"
  output="" exit_code=0
  output=$(run_tt task prompt 2>&1) || exit_code=$?
  assert_failure "prompt on non-task fails" "$exit_code"
}


test_task_prompt__help() {
  setup_workspace "prompt-help"
  output="" exit_code=0
  output=$(run_tt task prompt --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task prompt"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
  assert_required_usage_argument "argument: --message" "$output" "--message"
}


run_tests "tt task prompt"
