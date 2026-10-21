#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for display formatting helpers in lib/format.sh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _format__status_checkbox
# ---------------------------------------------------------------------------

test__format__status_checkbox__todo() {
  assert_eq "TODO maps to unchecked" "$(_format__status_checkbox "TODO")" "[ ]"
}

test__format__status_checkbox__in_progress() {
  assert_eq "IN-PROGRESS maps to dash" "$(_format__status_checkbox "IN-PROGRESS")" "[-]"
}

test__format__status_checkbox__done() {
  assert_eq "DONE maps to checked" "$(_format__status_checkbox "DONE")" "[x]"
  assert_eq "Done maps to checked" "$(_format__status_checkbox "Done")" "[x]"
}

test__format__status_checkbox__unknown() {
  assert_eq "unknown status maps to question mark" "$(_format__status_checkbox "BOGUS")" "[?]"
  assert_eq "empty status maps to question mark" "$(_format__status_checkbox "")" "[?]"
}

test__format__aligned_block__aligns_values_past_the_longest_key() {
  assert_eq "values share a column one space past the longest key" \
    "$(_format__aligned_block task "task/t-1" parent "project/p-2" title 'Say "hi"')" \
    $'---\ntask:   task/t-1\nparent: project/p-2\ntitle:  Say "hi"\n---'
}

test__format__aligned_block__empty_block() {
  assert_eq "no pairs gives just the delimiters" "$(_format__aligned_block)" $'---\n---'
}

run_tests "tt lib/format (unit)"
