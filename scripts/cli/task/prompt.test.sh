#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_task_prompt__basic_prompt_output() {
  setup_workspace "prompt-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "My Task" "Task body text") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task prompt 2>&1) || exit_code=$?
  assert_success "prompt succeeds" "$exit_code"
  assert_eq "starts with frontmatter" "$(printf '%s\n' "$output" | head -1)" "---"
  assert_not_contains "no summary line" "$output" "Implement task:"
  assert_eq "ends with separator" "$(printf '%s\n' "$output" | tail -1)" "---"
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
  assert_eq "separator before message" "$(printf '%s\n' "$output" | tail -3 | head -1)" "---"
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


test_task_prompt__explicit_task_id_not_checked_in() {
  setup_workspace "prompt-explicit-ongoing"
  proj_id=$(create_project "proj" "Project Title" "Project body") || true
  checkout_task "$proj_id" >/dev/null || true
  child_id=$(create_task "c" "Child Title" "Child body") || true

  output="" exit_code=0
  output=$(run_tt task prompt "$child_id" 2>&1) || exit_code=$?
  assert_success "prompt succeeds" "$exit_code"
  assert_contains "task header is child ID" "$output" "task: $child_id"
  assert_contains "child title" "$output" 'title: "Child Title"'
  assert_contains "child body" "$output" "Child body"
  assert_not_contains "no project title" "$output" "Project Title"
}


test_task_prompt__explicit_task_id_checked_in() {
  setup_workspace "prompt-explicit-checked-in"
  proj_id=$(create_project "proj" "Project Title" "Project body") || true
  checkout_task "$proj_id" >/dev/null || true
  child_id=$(create_task "c" "Child Title" "Child body") || true
  checkout_task "$child_id" >/dev/null || true
  edit_file "c.txt" "c"
  checkpoint_task "child work" >/dev/null || true
  checkin_task "$child_id" --complete >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task prompt "$child_id" 2>&1) || exit_code=$?
  assert_success "prompt succeeds" "$exit_code"
  assert_contains "task header is child ID" "$output" "task: $child_id"
  assert_not_contains "task header is not project ID" "$output" "task: $proj_id"
  assert_contains "child title" "$output" 'title: "Child Title"'
  assert_contains "child body" "$output" "Child body"
  assert_not_contains "no project title" "$output" "Project Title"
  assert_not_contains "no project body" "$output" "Project body"
}


test_task_prompt__explicit_task_id_checked_in_context() {
  setup_workspace "prompt-explicit-checked-in-ctx"
  proj_id=$(create_project "proj" "Project Title") || true
  checkout_task "$proj_id" >/dev/null || true
  echo "Project context body" | run_tt task context add --title "Project Ctx" --slug "pctx" >/dev/null 2>&1 || true
  child_id=$(create_task "c" "Child Title") || true
  checkout_task "$child_id" >/dev/null || true
  echo "Child context body" | run_tt task context add --title "Child Ctx" --slug "cctx" >/dev/null 2>&1 || true
  checkin_task "$child_id" --complete >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task prompt "$child_id" 2>&1) || exit_code=$?
  assert_success "prompt succeeds" "$exit_code"
  assert_contains "child context title" "$output" 'title: "Child Ctx"'
  assert_contains "child context body" "$output" "Child context body"
  assert_not_contains "no project context title" "$output" "Project Ctx"
  assert_not_contains "no project context body" "$output" "Project context body"
}


test_task_prompt__task_title_is_quoted() {
  setup_workspace "prompt-title-quoted"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" 'Say "hi"') || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task prompt 2>&1) || exit_code=$?
  assert_success "prompt succeeds" "$exit_code"
  assert_contains "the task title is a quoted frontmatter string" "$output" \
    $'---\ntask: '"$task_id"$'\ntitle: "Say \\"hi\\""\n---'
}

test_task_prompt__context_title_is_quoted() {
  setup_workspace "prompt-ctx-quoted"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "Body" | run_tt task context add --title 'Say "hi"' --slug "ctx" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task prompt 2>&1) || exit_code=$?
  assert_success "prompt succeeds" "$exit_code"
  assert_contains "the context title is escaped" "$output" 'title: "Say \"hi\""'
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
