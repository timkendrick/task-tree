#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_workspace_root__prints_virtual_dir() {
  setup_workspace "ws-root-basic"
  local expected
  expected="$(cd "$VIRTUAL" && pwd -P)"
  output="" exit_code=0
  output=$(run_tt workspace root 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "prints virtual dir" "$output" "$expected"
}

test_workspace_root__alias_tt_root() {
  setup_workspace "ws-root-alias"
  local expected
  expected="$(cd "$VIRTUAL" && pwd -P)"
  output="" exit_code=0
  output=$(run_tt root 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "alias resolves to virtual dir" "$output" "$expected"
}

test_workspace_root__repo_flag() {
  setup_workspace "ws-root-repo-flag"
  local expected
  expected="$(cd "$VIRTUAL" && pwd -P)"
  output="" exit_code=0
  output=$(run_tt workspace root --repo "$REPO" 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_eq "output with --repo flag" "$output" "$expected"
}

test_workspace_root__no_workspace_configured() {
  setup_workspace "ws-root-no-ws"
  # Remove the .tt/workspace symlink to simulate an uninitialised state
  rm -f "$REPO/.tt/workspace"
  output="" exit_code=0
  output=$(run_tt workspace root 2>&1) || exit_code=$?
  assert_failure "exits with error when not configured" "$exit_code"
  assert_contains "error mentions workspace init" "$output" "tt workspace init"
}

test_workspace_root__rejects_unknown_flags() {
  setup_workspace "ws-root-unknown-flag"
  output="" exit_code=0
  output=$(run_tt workspace root --unknown 2>&1) || exit_code=$?
  assert_failure "unknown flag rejected" "$exit_code"
}

test_workspace_root__rejects_positional_args() {
  setup_workspace "ws-root-pos-arg"
  output="" exit_code=0
  output=$(run_tt workspace root somearg 2>&1) || exit_code=$?
  assert_failure "positional argument rejected" "$exit_code"
}

test_workspace_root__help() {
  setup_workspace "ws-root-help"
  output="" exit_code=0
  output=$(run_tt workspace root --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt workspace root"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt workspace root"
