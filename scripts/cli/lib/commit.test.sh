#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for commit message helpers in lib/commit.sh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _commit__format_message
# ---------------------------------------------------------------------------

test__commit__format_message__with_entity_id() {
  assert_eq "entity id included in tag" \
    "$(_commit__format_message task create 'task/foo-ab123456' 'My title')" \
    "[tt:task:task/foo-ab123456:create] My title"
}

test__commit__format_message__without_entity_id() {
  assert_eq "tag omits entity id when empty" \
    "$(_commit__format_message workspace init '' 'Initialized workspace')" \
    "[tt:workspace:init] Initialized workspace"
}

# ---------------------------------------------------------------------------
# _commit__parse_message
# ---------------------------------------------------------------------------

test__commit__parse_message__round_trip() {
  local message record
  message="$(_commit__format_message task checkpoint 'task/foo-ab123456' 'Did some work')"
  record="$(_commit__parse_message "$message")"
  assert_eq "round trip preserves all fields" "$record" \
    "$(printf 'task\ttask/foo-ab123456\tcheckpoint\tDid some work')"
}

test__commit__parse_message__no_entity_form() {
  local record
  record="$(_commit__parse_message '[tt:workspace:init] Initialized workspace')"
  assert_eq "entity id field empty" "$record" \
    "$(printf 'workspace\t\tinit\tInitialized workspace')"
}

test__commit__parse_message__operation_containing_colon() {
  local record
  record="$(_commit__parse_message '[tt:task:task/foo-ab123456:context:add] Added context')"
  assert_eq "colon retained within operation" "$record" \
    "$(printf 'task\ttask/foo-ab123456\tcontext:add\tAdded context')"
}

test__commit__parse_message__rejects_plain_message() {
  local out exit_code=0
  out="$(_commit__parse_message 'Fix a bug')" || exit_code=$?
  assert_failure "plain message rejected" "$exit_code"
  assert_output_empty "nothing printed" "$out"
}

test__commit__parse_message__rejects_tag_without_operation() {
  local out exit_code=0
  out="$(_commit__parse_message '[tt:task] No operation')" || exit_code=$?
  assert_failure "tag without operation rejected" "$exit_code"
  assert_output_empty "nothing printed" "$out"
}

test__commit__parse_message__rejects_unclosed_tag() {
  local out exit_code=0
  out="$(_commit__parse_message '[tt:task:create unclosed')" || exit_code=$?
  assert_failure "unclosed tag rejected" "$exit_code"
  assert_output_empty "nothing printed" "$out"
}

run_tests "tt lib/commit (unit)"
