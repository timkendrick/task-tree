#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for string/slug/ID/timestamp helpers in lib/string.sh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _string__first_line
# ---------------------------------------------------------------------------

test__string__first_line__takes_the_first_of_many() {
  assert_eq "first of several lines" \
    "$(_string__first_line "$(printf 'one\ntwo\nthree')")" "one"
  assert_eq "a trailing newline is not a second line" \
    "$(_string__first_line "$(printf 'only\n')")" "only"
  assert_eq "a single line is itself" "$(_string__first_line 'only')" "only"
  assert_output_empty "empty input yields nothing" "$(_string__first_line '')"
  assert_output_empty "a leading newline yields an empty first line" \
    "$(_string__first_line "$(printf '\nsecond')")"
}

# ---------------------------------------------------------------------------
# _string__to_slug
# ---------------------------------------------------------------------------

test__string__to_slug__lowercases_and_hyphenates() {
  assert_eq "spaces become hyphens, lowercased" \
    "$(_string__to_slug 'My Great Task')" "my-great-task"
}

test__string__to_slug__collapses_and_trims_hyphens() {
  assert_eq "punctuation collapsed, edges trimmed" \
    "$(_string__to_slug '  Fix: the (weird)   bug!  ')" "fix-the-weird-bug"
}

test__string__to_slug__preserves_digits() {
  assert_eq "digits preserved" "$(_string__to_slug 'Phase 2 cleanup')" "phase-2-cleanup"
}

# ---------------------------------------------------------------------------
# _string__validate_slug
# ---------------------------------------------------------------------------

test__string__validate_slug__accepts_valid_slug() {
  local exit_code=0
  _string__validate_slug "my-task-2" 2>/dev/null || exit_code=$?
  assert_success "valid slug accepted" "$exit_code"
}

test__string__validate_slug__rejects_empty() {
  local out exit_code=0
  out="$(_string__validate_slug "" 2>&1)" || exit_code=$?
  assert_failure "empty slug rejected" "$exit_code"
  assert_contains "error message" "$out" "Slug cannot be empty"
}

test__string__validate_slug__rejects_uppercase() {
  local out exit_code=0
  out="$(_string__validate_slug "My-Task" 2>&1)" || exit_code=$?
  assert_failure "uppercase slug rejected" "$exit_code"
  assert_contains "error message" "$out" "Slug must be lowercase"
}

test__string__validate_slug__rejects_leading_hyphen() {
  local exit_code=0
  _string__validate_slug "-task" 2>/dev/null || exit_code=$?
  assert_failure "leading hyphen rejected" "$exit_code"
}

test__string__validate_slug__rejects_consecutive_hyphens() {
  local exit_code=0
  _string__validate_slug "my--task" 2>/dev/null || exit_code=$?
  assert_failure "consecutive hyphens rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _string__generate_hex
# ---------------------------------------------------------------------------

test__string__generate_hex__eight_hex_chars() {
  local hex
  hex="$(_string__generate_hex)"
  assert_matches "8 lowercase hex chars" "$hex" '^[0-9a-f]{8}$'
}

# ---------------------------------------------------------------------------
# _string__generate_timestamp
# ---------------------------------------------------------------------------

test__string__generate_timestamp__iso8601_utc() {
  local ts
  ts="$(_string__generate_timestamp)"
  assert_matches "ISO 8601 UTC format" "$ts" \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
}

run_tests "tt lib/string (unit)"
