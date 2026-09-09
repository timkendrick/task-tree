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
# _ui__check_log_level
# ---------------------------------------------------------------------------

# Usage: _check_level TT_LOG_VALUE THRESHOLD -> "yes" | "no"
_check_level() {
  if TT_LOG="$1" _ui__check_log_level "$2"; then printf 'yes'; else printf 'no'; fi
}

test__ui__check_log_level__off_activates_nothing() {
  assert_eq "off vs INFO" "$(_check_level '' "$_UI__LOG_LEVEL_INFO")" "no"
  assert_eq "off vs VERBOSE" "$(_check_level '' "$_UI__LOG_LEVEL_VERBOSE")" "no"
}

test__ui__check_log_level__info_activates_info_only() {
  assert_eq "info vs INFO" "$(_check_level info "$_UI__LOG_LEVEL_INFO")" "yes"
  assert_eq "info vs VERBOSE" "$(_check_level info "$_UI__LOG_LEVEL_VERBOSE")" "no"
}

test__ui__check_log_level__verbose_activates_both() {
  assert_eq "verbose vs INFO" "$(_check_level verbose "$_UI__LOG_LEVEL_INFO")" "yes"
  assert_eq "verbose vs VERBOSE" "$(_check_level verbose "$_UI__LOG_LEVEL_VERBOSE")" "yes"
}

test__ui__check_log_level__unrecognized_values_are_off() {
  # An unrecognized value disables tracing outright rather than half-enabling
  # it, so neither a case variant nor a boolean-looking value can silently
  # turn tracing on.
  local value
  for value in debug trace 1 0 yes true INFO Info VERBOSE; do
    assert_eq "TT_LOG=$value does not activate INFO" \
      "$(_check_level "$value" "$_UI__LOG_LEVEL_INFO")" "no"
    assert_eq "TT_LOG=$value does not activate VERBOSE" \
      "$(_check_level "$value" "$_UI__LOG_LEVEL_VERBOSE")" "no"
  done
}

test__ui__check_log_level__off_threshold_is_never_active() {
  # A caller asking "is OFF active" must always be told no, so that a level of
  # zero cannot be used to force unconditional tracing.
  assert_eq "verbose vs OFF threshold" \
    "$(_check_level verbose "$_UI__LOG_LEVEL_OFF")" "no"
}

test__ui__check_log_level__returning_false_does_not_abort_under_set_e() {
  # The predicate is called from _ui__run_command, whose callers run under
  # `set -e`; returning 1 must be an ordinary false, not a fatal error.
  local out
  out="$(TT_LOG= bash -c '
    set -euo pipefail
    . "$1"
    if _ui__check_log_level "$_UI__LOG_LEVEL_INFO"; then echo on; else echo off; fi
    echo survived
  ' _ "$_TT_LIB_DIR/ui.sh")"
  assert_eq "predicate is false and execution continues" "$out" "$(printf 'off\nsurvived')"
}

# ---------------------------------------------------------------------------
# _ui__log_command
# ---------------------------------------------------------------------------

test__ui__log_command__writes_prefixed_line_to_stderr() {
  local err_file="$_TEST_ROOT/log-command-stderr.txt"
  local out
  out="$(_ui__log_command jj -R /repo bookmark set main 2>"$err_file")"
  assert_output_empty "nothing on stdout" "$out"
  assert_eq "traced line on stderr" \
    "$(cat "$err_file")" "+ jj -R /repo bookmark set main"
}

test__ui__log_command__quotes_arguments_so_the_line_round_trips() {
  # The traced line must be re-runnable verbatim, so arguments carrying shell
  # metacharacters are quoted rather than printed raw.
  local err_file="$_TEST_ROOT/log-command-quoting.txt"
  _ui__log_command jj describe -m "it's a \$message with spaces" 2>"$err_file"
  local traced
  traced="$(cat "$err_file")"
  assert_line_count "awkward arguments stay on one line" "$traced" 1
  assert_not_contains "dollar sign is not left bare" "$traced" " \$message"
  # Re-parse the traced argv and confirm it reproduces the original arguments.
  local reparsed
  reparsed="$(eval "printf '%s\n' ${traced#+ }" | tail -n 1)"
  assert_eq "argument survives the round trip" \
    "$reparsed" "it's a \$message with spaces"
}

# ---------------------------------------------------------------------------
# _ui__run_command
# ---------------------------------------------------------------------------

test__ui__run_command__capture_stdout_is_identical_at_every_level() {
  # The central guarantee: TT_LOG is diagnostics only, so a captured stdout is
  # byte-identical whether or not the invocation is being traced.
  local off info verbose
  off="$(TT_LOG= _ui__run_command "$_UI__LOG_LEVEL_VERBOSE" "$_UI__OUTPUT_CAPTURE" \
    printf 'payload\n' 2>/dev/null)"
  info="$(TT_LOG=info _ui__run_command "$_UI__LOG_LEVEL_VERBOSE" "$_UI__OUTPUT_CAPTURE" \
    printf 'payload\n' 2>/dev/null)"
  verbose="$(TT_LOG=verbose _ui__run_command "$_UI__LOG_LEVEL_VERBOSE" "$_UI__OUTPUT_CAPTURE" \
    printf 'payload\n' 2>/dev/null)"
  assert_eq "stdout unchanged at info" "$info" "$off"
  assert_eq "stdout unchanged at verbose" "$verbose" "$off"
  assert_eq "stdout is the command's output" "$off" "payload"
}

test__ui__run_command__capture_traces_only_at_or_above_its_level() {
  local err_file="$_TEST_ROOT/run-capture-stderr.txt"
  TT_LOG= _ui__run_command "$_UI__LOG_LEVEL_VERBOSE" "$_UI__OUTPUT_CAPTURE" \
    printf 'x\n' >/dev/null 2>"$err_file"
  assert_output_empty "silent when logging is off" "$(cat "$err_file")"

  TT_LOG=info _ui__run_command "$_UI__LOG_LEVEL_VERBOSE" "$_UI__OUTPUT_CAPTURE" \
    printf 'x\n' >/dev/null 2>"$err_file"
  assert_output_empty "a verbose-level call is silent at info" "$(cat "$err_file")"

  TT_LOG=verbose _ui__run_command "$_UI__LOG_LEVEL_VERBOSE" "$_UI__OUTPUT_CAPTURE" \
    printf 'x\n' >/dev/null 2>"$err_file"
  assert_contains "traced at verbose" "$(cat "$err_file")" "+ printf"
}

test__ui__run_command__info_level_call_traces_at_info() {
  local err_file="$_TEST_ROOT/run-info-stderr.txt"
  TT_LOG=info _ui__run_command "$_UI__LOG_LEVEL_INFO" "$_UI__OUTPUT_QUIET" \
    printf 'x\n' 2>"$err_file"
  assert_contains "info-level call traced at info" "$(cat "$err_file")" "+ printf"
}

test__ui__run_command__quiet_never_leaks_stdout_to_the_caller() {
  local level
  for level in '' info verbose; do
    local out
    out="$(TT_LOG="$level" _ui__run_command "$_UI__LOG_LEVEL_INFO" "$_UI__OUTPUT_QUIET" \
      printf 'should-not-appear\n' 2>/dev/null)"
    assert_output_empty "quiet stdout suppressed at TT_LOG=${level:-off}" "$out"
  done
}

test__ui__run_command__quiet_forwards_command_output_when_tracing() {
  # At info the mutation's own reporting is the useful part, so it is forwarded
  # to stderr rather than discarded.
  local err_file="$_TEST_ROOT/run-quiet-forward.txt"
  TT_LOG=info _ui__run_command "$_UI__LOG_LEVEL_INFO" "$_UI__OUTPUT_QUIET" \
    printf 'command output\n' 2>"$err_file"
  assert_contains "command output forwarded to stderr" \
    "$(cat "$err_file")" "command output"
}

test__ui__run_command__discards_command_stderr_when_not_tracing() {
  local err_file="$_TEST_ROOT/run-discard-stderr.txt"
  TT_LOG= _ui__run_command "$_UI__LOG_LEVEL_INFO" "$_UI__OUTPUT_CAPTURE" \
    bash -c 'printf "noise\n" >&2' >/dev/null 2>"$err_file"
  assert_output_empty "command stderr discarded when quiet" "$(cat "$err_file")"
}

test__ui__run_command__preserves_exit_status_at_every_level() {
  local level
  for level in '' info verbose; do
    local code=0
    TT_LOG="$level" _ui__run_command "$_UI__LOG_LEVEL_INFO" "$_UI__OUTPUT_QUIET" \
      bash -c 'exit 42' >/dev/null 2>/dev/null || code=$?
    assert_eq "exit status preserved at TT_LOG=${level:-off}" "$code" "42"
  done
}

test__ui__run_command__runs_in_the_callers_directory() {
  # _ui__run_command deliberately takes no directory argument: a caller that
  # needs the command to run elsewhere wraps the call in its own subshell, so
  # the reason for the directory change is stated where that reason applies.
  local dir="$_TEST_ROOT/run-dir"
  mkdir -p "$dir"
  local here out
  here="$(pwd -P)"
  out="$(TT_LOG= _ui__run_command "$_UI__LOG_LEVEL_INFO" "$_UI__OUTPUT_CAPTURE" \
    pwd -P 2>/dev/null)"
  assert_eq "command ran in the caller's directory" "$out" "$here"

  out="$(cd "$dir" && TT_LOG= _ui__run_command "$_UI__LOG_LEVEL_INFO" "$_UI__OUTPUT_CAPTURE" \
    pwd -P 2>/dev/null)"
  assert_eq "a caller's own subshell relocates the command" \
    "$out" "$(cd "$dir" && pwd -P)"
  assert_eq "and leaves the caller's directory unchanged" "$(pwd -P)" "$here"
}

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
