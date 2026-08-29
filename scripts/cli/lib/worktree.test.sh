#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for worktree management in lib/worktree.sh
# ---------------------------------------------------------------------------

test__worktree__parse_list_line__normal_line() {
  local parsed
  parsed="$(_worktree__parse_list_line 'default: /some/absolute/path')"
  assert_eq "workspace name parsed" "$(printf '%s' "$parsed" | sed -n '1p')" "default"
  assert_eq "workspace path parsed" "$(printf '%s' "$parsed" | sed -n '2p')" "/some/absolute/path"
}

test__worktree__parse_list_line__error_path_line() {
  local parsed
  parsed="$(_worktree__parse_list_line 'wt1: <Error: Workspace has no recorded path: wt1>')"
  assert_eq "workspace name parsed from error line" \
    "$(printf '%s' "$parsed" | sed -n '1p')" "wt1"
  assert_output_empty "error path becomes empty string" \
    "$(printf '%s' "$parsed" | sed -n '2p')"
}

test__worktree__list_entries__lists_default_workspace() {
  setup_workspace "worktree-list-entries"

  local entries
  entries="$(_worktree__list_entries "$REPO")"
  assert_line_count "exactly one workspace" "$entries" 1
  assert_contains "default workspace record" "$entries" "$(printf 'default\t%s' "$REPO")"
}

test__worktree__resolve_name_path__round_trip() {
  setup_workspace "worktree-name-path"

  local name
  name="$(_worktree__resolve_name "$REPO" "$REPO")"
  assert_eq "repo path resolves to the default workspace name" "$name" "default"

  local path
  path="$(_worktree__resolve_path "$REPO" "$name")"
  assert_eq "workspace name resolves back to the repo path" "$path" "$REPO"
}

test__worktree__resolve_name__unknown_path_fails() {
  setup_workspace "worktree-unknown-path"

  local exit_code=0
  _worktree__resolve_name "$REPO" "/no/such/worktree" >/dev/null || exit_code=$?
  assert_failure "unknown worktree path" "$exit_code"
}

test__worktree__find_for_branch__finds_workspace_on_branch() {
  setup_workspace "worktree-find-branch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  local task_prefix project_prefix
  task_prefix="$(_workspace__get_task_prefix "$REPO")"
  project_prefix="$(_workspace__get_project_prefix "$REPO")"

  local found
  found="$(_worktree__find_for_branch "$REPO" "$proj_id" "$task_prefix" "$project_prefix")"
  assert_contains "repo workspace is on the project branch" "$found" "$REPO"

  found="$(_worktree__find_for_branch "$REPO" "main" "$task_prefix" "$project_prefix")"
  assert_output_empty "no workspace is on main" "$found"
}

run_tests "tt lib/worktree (unit)"
