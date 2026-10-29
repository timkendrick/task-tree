#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for directory locks in lib/lock.sh
# ---------------------------------------------------------------------------

test__lock__acquire__free_lock_succeeds() {
  local lock="$_TEST_ROOT/free.lock"

  local exit_code=0
  _lock__acquire "$lock" 1 || exit_code=$?
  assert_success "acquire succeeds on a free lock" "$exit_code"
  assert_file_exists "lock directory exists while held" "$lock"
}

test__lock__acquire__waits_for_concurrent_release() {
  local lock="$_TEST_ROOT/contended.lock"
  mkdir "$lock"
  ( sleep 0.3; _lock__release "$lock" ) &
  local releaser=$!

  local exit_code=0
  _lock__acquire "$lock" 3 || exit_code=$?
  wait "$releaser"
  assert_success "acquire succeeds once the holder releases" "$exit_code"
  assert_file_exists "lock directory exists while held" "$lock"
}

test__lock__acquire__times_out_while_held() {
  local lock="$_TEST_ROOT/held.lock"
  mkdir "$lock"

  local out exit_code=0 started=$SECONDS
  out="$(_lock__acquire "$lock" 1 2>&1)" || exit_code=$?
  assert_failure "acquire fails while the lock is held" "$exit_code"
  assert_output_empty "acquire prints nothing on timeout" "$out"
  assert_eq "acquire waited for the timeout" "$(( SECONDS - started >= 1 ))" "1"
  assert_file_exists "held lock is left in place" "$lock"
}

test__lock__release__frees_the_lock() {
  local lock="$_TEST_ROOT/released.lock"
  _lock__acquire "$lock" 1
  _lock__release "$lock"
  assert_file_not_exists "lock directory removed" "$lock"

  local exit_code=0
  _lock__acquire "$lock" 1 || exit_code=$?
  assert_success "lock can be taken again after release" "$exit_code"
}

run_tests "tt lib/lock (unit)"
