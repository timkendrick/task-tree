#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

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

run_tests "tt lib/format (unit)"
