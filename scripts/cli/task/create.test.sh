#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_create__create_project() {
  setup_workspace "create-project"
  proj_id=$(create_project "myproj" "My Project") || true
  assert_success "create project succeeds" "$?"
  assert_matches "project ID format" "$proj_id" "project/%myproj%"
  assert_bookmark_exists "project bookmark exists" "$proj_id"
  assert_task_status "project status is TODO" "$proj_id" "TODO"
  assert_task_title "project title" "$proj_id" "My Project"
}


test_task_create__create_task_under_project() {
  setup_workspace "create-under-project"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_id=$(create_task "child" "Child Task" "Task body") || true
  assert_success "create task succeeds" "$?"
  assert_matches "task ID format" "$task_id" "task/%child%"
  assert_bookmark_exists "child bookmark exists" "$task_id"
  assert_task_status "child status TODO" "$task_id" "TODO"
  assert_task_title "child title" "$task_id" "Child Task"
  assert_task_body_contains "child body" "$task_id" "Task body"

  assert_subtask_entry "parent has subtask entry" "$proj_id" "$task_id" "[ ]"
  assert_is_ancestor "child descends from parent" "$proj_id" "$task_id"
  assert_current_task "WC on parent" "$proj_id"
}


test_task_create__create_with_checkout() {
  setup_workspace "create-checkout"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_id=$(run_tt task create --slug "mytask" --title "My Task" --checkout <<< "" | tail -1) || true
  assert_success "create with --checkout succeeds" "$?"
  assert_matches "task ID format" "$task_id" "task/%mytask%"
  assert_current_task_matches "WC on new task" "task/%mytask%"
  assert_task_status "status is IN-PROGRESS" "$task_id" "IN-PROGRESS"
}


test_task_create__create_with_labels() {
  setup_workspace "create-labels"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_id=$(run_tt task create --slug "lbl" --title "Labeled" --label "bug" --label "urgent" <<< "" | tail -1) || true
  assert_task_label "has bug label" "$task_id" "bug"
  assert_task_label "has urgent label" "$task_id" "urgent"
}


test_task_create__completed_parent_rejected() {
  setup_workspace "create-completed-parent"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  complete_task >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task create --slug "child" --title "Child" <<< "" 2>&1) || exit_code=$?
  assert_failure "create under DONE parent rejected" "$exit_code"
}


test_task_create__invalid_slug_rejected() {
  setup_workspace "create-invalid-slug"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task create --slug "UPPERCASE" --title "Bad" <<< "" 2>&1) || exit_code=$?
  assert_failure "UPPERCASE slug rejected" "$exit_code"
}


test_task_create__project_with_parent_rejected() {
  setup_workspace "create-exclusive"
  output="" exit_code=0
  output=$(run_tt task create --project --parent "task/x-00000000" --slug "x" --title "X" <<< "" 2>&1) || exit_code=$?
  assert_failure "--project + --parent rejected" "$exit_code"
}


test_task_create__wc_position_preserved_without_checkout() {
  setup_workspace "create-wc-preserve"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_id=$(create_task "child" "Child") || true
  assert_current_task "WC still on parent" "$proj_id"
}


test_task_create__single_transaction_recorded() {
  setup_workspace "create-txn"
  get_history_lines
  hc_before="${#HISTORY_LINES[@]}"

  proj_id=$(create_project "proj" "Project") || true

  get_history_lines
  hc_after="${#HISTORY_LINES[@]}"
  assert_eq "one new history entry" "$((hc_after - hc_before))" "1"
  assert_history_integrity "history integrity after create"
}


test_task_create__project_with_target() {
  setup_workspace "create-project-target"
  proj_id=$(run_tt task create --project --slug "proj" --title "Proj" --target "main" <<< "" | tail -1) || true
  assert_success "project with --target succeeds" "$?"
  assert_is_ancestor "main is ancestor of project" "main" "$proj_id"
}


test_task_create__propagate() {
  setup_workspace "create-propagate"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child_a=$(create_task "child-a" "Child A") || true
  checkout_task "$proj_id" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true
  child_b=$(run_tt task create --slug "child-b" --title "Child B" --propagate <<< "" | tail -1) || true
  assert_matches "child B created" "$child_b" "task/%child-b%"
  assert_is_ancestor "child A descends from parent" "$proj_id" "$child_a"
  assert_is_ancestor "child B descends from parent" "$proj_id" "$child_b"
}


test_task_create__help() {
  setup_workspace "create-help"
  output="" exit_code=0
  output=$(run_tt task create --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task create"
  assert_optional_usage_argument "argument: --title" "$output" "--title"
  assert_optional_usage_argument "argument: --slug" "$output" "--slug"
  assert_optional_usage_argument "argument: --parent" "$output" "--parent"
  assert_optional_usage_argument "argument: --project" "$output" "--project"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
  assert_optional_usage_argument "argument: --force" "$output" "--force"
}


test_task_create__subtask_after_existing_context() {
  setup_workspace "create-subtask-order"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "parent" "Parent") || true
  checkout_task "$task_id" >/dev/null || true

  # Add a context to the parent first
  echo "Body" | run_tt task context add --title "Research" --slug "research" >/dev/null 2>&1 || true

  # Now create a child — the subtask entry must appear after the context entry
  create_task_under "$task_id" "child" "Child" >/dev/null || true

  content="$(read_task_file "$task_id")"
  assert_frontmatter_order "canonical order after subtask added to parent with context" "$content"
}

run_tests "tt task create"
