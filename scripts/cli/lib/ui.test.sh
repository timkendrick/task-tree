#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for user interaction helpers in lib/ui.sh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _ui__select
# ---------------------------------------------------------------------------

test__ui__select__custom_picker_selects_option() {
  local out exit_code=0
  out="$(printf 'task/foo\ntask/bar\ntask/baz\n' | TT_SELECT='head -n 2 | tail -n 1' _ui__select)" || exit_code=$?
  assert_success "select succeeds" "$exit_code"
  assert_eq "selected option" "$out" "task/bar"
}

test__ui__select__custom_picker_receives_options_on_stdin() {
  local capture out
  capture="$(mktemp)"
  trap 'rm -f "$capture"' RETURN

  out="$(printf 'task/foo\ntask/bar\n' | TT_SELECT="cat > '$capture'; head -n 1 '$capture'" _ui__select)"
  assert_eq "selected option" "$out" "task/foo"
  assert_eq "picker stdin" "$(cat "$capture")" "$(printf 'task/foo\ntask/bar')"
}

test__ui__select__rejects_output_not_in_options() {
  local out exit_code=0
  out="$(printf 'task/foo\ntask/bar\n' | TT_SELECT='echo task/nope' _ui__select 2>&1)" || exit_code=$?
  assert_failure "non-matching output fails" "$exit_code"
  assert_contains "error message" "$out" "invalid selection: task/nope"
}

test__ui__select__rejects_partial_match() {
  local exit_code=0
  printf 'task/foobar\n' | TT_SELECT='echo task/foo' _ui__select >/dev/null 2>&1 || exit_code=$?
  assert_failure "prefix of an option is not a match" "$exit_code"
}

test__ui__select__empty_input_fails() {
  local out exit_code=0
  out="$(printf '' | TT_SELECT='cat' _ui__select 2>&1)" || exit_code=$?
  assert_failure "empty input fails" "$exit_code"
  assert_contains "error message" "$out" "no options provided"
}

test__ui__select__failing_picker_command_fails() {
  local out exit_code=0
  out="$(printf 'task/foo\n' | TT_SELECT='exit 3' _ui__select 2>&1)" || exit_code=$?
  assert_failure "failing picker fails" "$exit_code"
  assert_contains "error message" "$out" "picker command failed"
}

# Note: the built-in picker (_ui__select_raw) is not unit-tested. It reads from
# /dev/tty, and there is no portable way to run a test with the controlling
# terminal detached (macOS has no setsid), so any such test would pass headless
# and fail when the suite is run from a real terminal.

run_tests "tt lib/ui (unit)"
