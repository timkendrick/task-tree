#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../harness/harness.sh"


test_context_get__get_all_context_files() {
  setup_workspace "ctxget-all"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  echo "Body one" | run_tt task context add --title "Ctx 1" --slug "ctx1" >/dev/null 2>&1 || true
  echo "Body two" | run_tt task context add --title "Ctx 2" --slug "ctx2" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task context get 2>&1) || exit_code=$?
  assert_success "get all succeeds" "$exit_code"
  assert_contains "first context body" "$output" "Body one"
  assert_contains "second context body" "$output" "Body two"
}


test_context_get__get_specific_context_id() {
  setup_workspace "ctxget-specific"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  add_output=$(echo "Ctx A body" | run_tt task context add --title "Ctx A" --slug "ctxa" 2>&1) || true
  ctx_a=$(printf '%s' "$add_output" | grep '^context/' | tail -1)
  echo "Ctx B body" | run_tt task context add --title "Ctx B" --slug "ctxb" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task context get "$ctx_a" 2>&1) || exit_code=$?
  assert_success "get specific succeeds" "$exit_code"
  assert_contains "Ctx A body present" "$output" "Ctx A body"
}


test_context_get__non_existent_context_id_fails() {
  setup_workspace "ctxget-noexist"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task context get "context/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent context rejected" "$exit_code"
}


test_context_get__task_with_no_context_fails() {
  setup_workspace "ctxget-none"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task context get 2>&1) || exit_code=$?
  assert_failure "no context files" "$exit_code"
}


test_context_get__from_explicit_task_via_task() {
  setup_workspace "ctxget-task"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "A") || true
  # Must be on task_a to add context to it (no dedicated worktree)
  checkout_task "$task_a" >/dev/null || true
  echo "Body A" | run_tt task context add --title "Ctx" --slug "ctx" >/dev/null 2>&1 || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "tb" "B") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task context get --task "$task_a" 2>&1) || exit_code=$?
  assert_success "get from explicit task" "$exit_code"
  assert_contains "body A present" "$output" "Body A"
}


test_context_get__output_includes_frontmatter() {
  setup_workspace "ctxget-fm"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  echo "Context body" | run_tt task context add --title "My Ctx" --slug "ctx" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task context get 2>&1) || exit_code=$?
  assert_success "get succeeds" "$exit_code"
  assert_contains "title in frontmatter" "$output" "My Ctx"
  assert_contains "body present" "$output" "Context body"
}


run_tests "tt task context get"
