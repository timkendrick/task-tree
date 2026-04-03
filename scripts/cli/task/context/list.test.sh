#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../harness/harness.sh"


test_context_list__list_context_ids() {
  setup_workspace "ctxlist-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  add1=$(echo "Body 1" | run_tt task context add --title "Ctx 1" --slug "ctx1" 2>&1) || true
  ctx1=$(printf '%s' "$add1" | grep '^context/' | tail -1)
  add2=$(echo "Body 2" | run_tt task context add --title "Ctx 2" --slug "ctx2" 2>&1) || true
  ctx2=$(printf '%s' "$add2" | grep '^context/' | tail -1)

  output="" exit_code=0
  output=$(run_tt task context list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "first context listed" "$output" "$ctx1"
  assert_contains "second context listed" "$output" "$ctx2"
}


test_context_list__no_contexts_empty_output() {
  setup_workspace "ctxlist-empty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task context list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_output_empty "empty output" "$output"
}


test_context_list__for_explicit_task() {
  setup_workspace "ctxlist-explicit"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "A") || true
  task_b=$(create_task "tb" "B") || true
  # Must be on task_a to add context to it
  checkout_task "$task_a" >/dev/null || true

  add_output=$(echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" 2>&1) || true
  ctx_id=$(printf '%s' "$add_output" | grep '^context/' | tail -1)

  output="" exit_code=0
  output=$(run_tt task context list "$task_a" 2>&1) || exit_code=$?
  assert_success "list explicit succeeds" "$exit_code"
  assert_contains "context listed for task A" "$output" "$ctx_id"
}


test_context_list__via_task_flag() {
  setup_workspace "ctxlist-flag"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "A") || true
  task_b=$(create_task "tb" "B") || true
  # Must be on task_a to add context to it
  checkout_task "$task_a" >/dev/null || true

  add_output=$(echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" 2>&1) || true
  ctx_id=$(printf '%s' "$add_output" | grep '^context/' | tail -1)

  output="" exit_code=0
  output=$(run_tt task context list --task "$task_a" 2>&1) || exit_code=$?
  assert_success "list via --task succeeds" "$exit_code"
  assert_contains "context listed" "$output" "$ctx_id"
}


run_tests "tt task context list"
