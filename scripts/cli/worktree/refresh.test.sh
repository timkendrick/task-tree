#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Create a project and a task checked out into its own worktree, and print the
# worktree path. Leaves the canonical workspace as the invoking one.
# Usage: wt=$(_fixture_task_worktree NAME)
_fixture_task_worktree() {
  local slug="$1"
  local proj_id task_id
  proj_id="$(create_project "proj-$slug" "Project")"
  checkout_task "$proj_id"
  task_id="$(create_task "$slug" "Task $slug")"
  create_task_worktree "$task_id"
}

# ---------------------------------------------------------------------------
# Target selection
# ---------------------------------------------------------------------------

test_worktree_refresh__defaults_to_the_current_worktree() {
  setup_workspace "refresh-default-target"
  local wt
  wt="$(_fixture_task_worktree "defaulted")"
  make_worktree_stale "$wt"

  local output exit_code=0
  output="$(run_tt_in_worktree "$wt" worktree refresh 2>&1)" || exit_code=$?
  assert_failure "the current worktree is the default target" "$exit_code"
  assert_contains "the refusal names the current worktree" "$output" "$wt"
}

test_worktree_refresh__path_targets_that_worktree() {
  setup_workspace "refresh-path-target"
  local wt
  wt="$(_fixture_task_worktree "named")"
  make_worktree_stale "$wt"

  # Run from the canonical workspace, which is healthy: only the named target
  # can be the subject of the refusal.
  local output exit_code=0
  output="$(run_tt worktree refresh "$wt" 2>&1)" || exit_code=$?
  assert_failure "a named stale worktree is refused" "$exit_code"
  assert_contains "the refusal names the given worktree" "$output" "$wt"
}

test_worktree_refresh__root_targets_the_canonical_workspace() {
  setup_workspace "refresh-root-target"
  local wt
  wt="$(_fixture_task_worktree "rooted")"
  make_worktree_stale "$REPO"

  # Invoked from the healthy task worktree: --root must reach past it to the
  # canonical workspace, which is the one that is stale.
  local output exit_code=0
  output="$(run_tt_in_worktree "$wt" worktree refresh --root 2>&1)" || exit_code=$?
  assert_failure "--root targets the canonical workspace" "$exit_code"
  assert_contains "the refusal names the canonical workspace" "$output" "$REPO"
}

test_worktree_refresh__path_with_root_is_rejected() {
  setup_workspace "refresh-path-and-root"

  local output exit_code=0
  output="$(run_tt worktree refresh "$REPO" --root 2>&1)" || exit_code=$?
  assert_exit_code "a path together with --root is a usage error" "$exit_code" "1"
  assert_contains "the error explains the conflict" "$output" \
    "--root cannot be combined with a worktree path"
  assert_contains "usage is shown" "$output" "Usage:"
}

test_worktree_refresh__unknown_path_is_rejected() {
  setup_workspace "refresh-unknown-path"

  local output exit_code=0
  output="$(run_tt worktree refresh "$_TEST_ROOT" 2>&1)" || exit_code=$?
  assert_failure "a path that is not a worktree is rejected" "$exit_code"
  assert_contains "the error says so" "$output" "is not a worktree in this repository"
}

# ---------------------------------------------------------------------------
# Detection and recovery
# ---------------------------------------------------------------------------

test_worktree_refresh__healthy_worktree_is_a_silent_no_op() {
  setup_workspace "refresh-healthy"
  local before
  before="$(get_jj_op)"

  local output exit_code=0
  output="$(run_tt worktree refresh 2>&1)" || exit_code=$?
  assert_success "a healthy workspace exits 0" "$exit_code"
  assert_output_empty "a healthy workspace produces no output" "$output"
  assert_eq "the repository is untouched" "$(get_jj_op)" "$before"
}

test_worktree_refresh__stale_worktree_refuses_without_force() {
  setup_workspace "refresh-refuses"
  local wt
  wt="$(_fixture_task_worktree "refused")"
  make_worktree_stale "$wt"

  local output exit_code=0
  output="$(run_tt worktree refresh "$wt" 2>&1)" || exit_code=$?
  assert_failure "a stale workspace is refused without --force" "$exit_code"
  assert_contains "the refusal names the workspace" "$output" \
    "Error: The workspace is stale: $wt"
  assert_contains "the refusal names --force" "$output" "Use --force to recover it."
  assert_contains "the refusal states the consequence" "$output" \
    "Uncommitted changes in that workspace will be lost."

  # Refusing changed nothing: the workspace is still stale.
  local still_stale=1
  jj -R "$wt" status >/dev/null 2>&1 || still_stale=0
  assert_eq "the workspace is still stale after the refusal" "$still_stale" "0"
}

test_worktree_refresh__force_recovers_a_stale_worktree() {
  setup_workspace "refresh-force"
  local wt
  wt="$(_fixture_task_worktree "recovered")"
  make_worktree_stale "$wt"

  local output exit_code=0
  output="$(run_tt worktree refresh "$wt" --force 2>&1)" || exit_code=$?
  assert_success "--force recovers the workspace" "$exit_code"
  assert_contains "the recovery is reported" "$output" "Refreshed $wt"

  local usable=0
  jj -R "$wt" status >/dev/null 2>&1 || usable=$?
  assert_success "the workspace is usable again" "$usable"
}

test_worktree_refresh__force_on_a_healthy_worktree_is_harmless() {
  setup_workspace "refresh-force-healthy"

  local exit_code=0
  run_tt worktree refresh --force >/dev/null 2>&1 || exit_code=$?
  assert_success "--force against a healthy workspace succeeds" "$exit_code"
}

test_worktree_refresh__records_no_transaction() {
  setup_workspace "refresh-no-transaction"
  local wt
  wt="$(_fixture_task_worktree "untransacted")"
  make_worktree_stale "$wt"

  get_history_lines
  local before="${#HISTORY_LINES[@]}"

  run_tt worktree refresh "$wt" --force >/dev/null 2>&1

  assert_history_count "recovery records no transaction" "$before"
  assert_no_pending_transaction "recovery leaves no in-progress entry"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

test_worktree_refresh__alias_dispatches() {
  setup_workspace "refresh-alias"

  local output exit_code=0
  output="$(run_tt refresh --help 2>&1)" || exit_code=$?
  assert_success "tt refresh reaches the command" "$exit_code"
  assert_contains "usage names the full command" "$output" "tt worktree refresh"
}

run_tests "tt worktree refresh"
