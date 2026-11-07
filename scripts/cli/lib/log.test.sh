#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for history graph rendering in lib/log.sh
# ---------------------------------------------------------------------------

# Usage: _event_line MESSAGE [FILES [LOCAL_BOOKMARKS [REMOTE_BOOKMARKS [LOCAL_TAGS [REMOTE_TAGS]]]]]
# Prints one event line in the _repo__show_log format, with graph prefix "| ",
# placeholder node, and change ID "ab" + "cdefgh".
_event_line() {
  printf '| \001  \036ab\037cdefgh\037%s\037%s\037%s\037%s\037%s\037%s\n' \
    "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "$1"
}

# Usage: _plain_line TEXT [LOCAL_BOOKMARKS [REMOTE_BOOKMARKS [LOCAL_TAGS [REMOTE_TAGS]]]]
_plain_line() {
  printf '|  %s\035%s\037%s\037%s\037%s\n' "$1" "${2:-}" "${3:-}" "${4:-}" "${5:-}"
}

_render_unicode() { _log__render unicode false; }

# ---------------------------------------------------------------------------
# Event lines
# ---------------------------------------------------------------------------

test__log__render__event_glyphs_unicode() {
  local operation escaped output
  while IFS=' ' read -r operation escaped; do
    output="$(_event_line "[tt:task:task/t-1:$operation] T" | _render_unicode)"
    # shellcheck disable=SC2059
    assert_eq "$operation glyph" "${output%%cdefgh*}" "| $(printf "$escaped")  ab"
  done <<'EOF'
new \342\230\205
create +
fork \342\221\202
edit \342\234\216
checkout \342\226\266
checkpoint \342\232\221
complete \342\234\223
handoff \342\206\227
checkin \342\212\225
propagate \342\207\243
publish \342\207\252
delete \342\234\227
reorder \342\207\205
context:add \302\247
context:delete \302\247
move \342\207\204
remove \342\210\222
rename \342\234\220
EOF
}

test__log__render__event_glyphs_nerd() {
  assert_eq "checkin uses the Nerd Font merge icon" \
    "$(_event_line "[tt:task:task/t-0a1b2c3d:checkin] T" | _log__render nerd false)" \
    $'| \357\220\231  abcdefgh  t'
  assert_eq "workspace init uses the home icon" \
    "$(_event_line "[tt:workspace:init] Create workspace" | _log__render nerd false)" \
    $'| \357\200\225  abcdefgh'
}

test__log__render__workspace_init_unicode() {
  assert_eq "workspace init glyph without a label" \
    "$(_event_line "[tt:workspace:init] Create workspace" | _render_unicode)" \
    $'| \342\227\216  abcdefgh'
}

test__log__render__unknown_operation() {
  assert_eq "unknown operation falls back to a question mark" \
    "$(_event_line "[tt:task:task/t-1:frobnicate] T" | _render_unicode)" \
    '| ?  abcdefgh'
}

test__log__render__task_name_labels() {
  local operation
  for operation in create delete fork checkin move remove rename; do
    assert_eq "$operation shows the task name" \
      "$(_event_line "[tt:task:task/my-task-0a1b2c3d:$operation] My task" | _render_unicode | cut -d' ' -f4-)" \
      'abcdefgh  my-task'
  done
}

test__log__render__glyph_only_events() {
  local operation
  for operation in new edit checkout complete handoff propagate publish reorder; do
    assert_eq "$operation shows no label" \
      "$(_event_line "[tt:task:task/my-task-0a1b2c3d:$operation] My task" | _render_unicode | cut -d' ' -f4-)" \
      'abcdefgh'
  done
}

test__log__render__checkpoint_message() {
  assert_eq "checkpoint shows the message" \
    "$(_event_line "[tt:task:task/t-0a1b2c3d:checkpoint] Finish the parser" | _render_unicode | cut -d' ' -f4-)" \
    'abcdefgh  Finish the parser'
}

test__log__render__context_name() {
  assert_eq "context event shows the context name" \
    "$(_event_line "[tt:task:task/t-0a1b2c3d:context:add] Notes" \
        ".tt/task/t-0a1b2c3d/context/implementation-notes-9f8e7d6c.md" | _render_unicode | cut -d' ' -f4-)" \
    'abcdefgh  implementation-notes'
}

test__log__render__event_refs() {
  assert_eq "bookmarks and tags follow the label" \
    "$(_event_line "[tt:task:task/t-0a1b2c3d:fork] T" '' 'task/t-0a1b2c3d*' 'task/t-0a1b2c3d@origin' 'v1' 'v1@git' \
        | _render_unicode | cut -d' ' -f4-)" \
    $'abcdefgh  t  \342\232\220 task/t-0a1b2c3d*  \342\232\220 task/t-0a1b2c3d@origin  \342\214\226 v1  \342\214\226 v1@git'
}

# ---------------------------------------------------------------------------
# Plain lines
# ---------------------------------------------------------------------------

test__log__render__plain_refs() {
  assert_eq "refs follow the description" \
    "$(_plain_line 'Fix the parser' 'main other' 'main@origin' 'v2' | _render_unicode)" \
    $'|  Fix the parser  \342\232\220 main  \342\232\220 other  \342\232\220 main@origin  \342\214\226 v2'
  assert_eq "no refs leaves the description alone" \
    "$(_plain_line 'Fix the parser' | _render_unicode)" \
    '|  Fix the parser'
}

test__log__render__conflicted_refs() {
  assert_eq "conflicted refs use the warning icon" \
    "$(_plain_line 'Fix' 'main??' '' 'v1??' | _render_unicode)" \
    $'|  Fix  \342\232\240 main??  \342\232\240 v1??'
}

test__log__render__other_lines_unchanged() {
  local input=$'@  abcdefgh user 2026-01-01 12345678\n|\n~  (elided revisions)'
  assert_eq "graph and header lines pass through" "$(printf '%s\n' "$input" | _render_unicode)" "$input"
}

# ---------------------------------------------------------------------------
# Color
# ---------------------------------------------------------------------------

test__log__render__no_color_has_no_escapes() {
  local output
  output="$( { _event_line "[tt:task:task/t-1:fork] T" '' 'b' 'b@origin' 't'; _plain_line 'Fix' 'main??'; } \
    | _log__render nerd false)"
  assert_not_contains "no escape sequences" "$output" $'\033'
}

test__log__render__color_styles_change_id_and_refs() {
  local output
  output="$( { _event_line "[tt:task:task/t-1:fork] T" '' 'b' 'b@origin'; _plain_line 'Fix' 'main??'; } \
    | _log__render unicode true)"
  assert_contains "glyph colored" "$output" $'\033[1;36m\342\221\202\033[0m'
  assert_contains "change ID prefix bold and dim" "$output" $'\033[1;2;90mab\033[0;2;90mcdefgh\033[0m'
  assert_contains "local bookmark bold" "$output" $'\033[1;35m\342\232\220 \033[0;1;35mb\033[0m'
  assert_contains "remote bookmark dim" "$output" $'\033[2;35m\342\232\220 \033[0;2;35mb@origin\033[0m'
  assert_contains "conflict icon red" "$output" $'\033[1;31m\342\232\240 \033[0;1;35mmain??\033[0m'
}

test__log__render__color_ignores_escapes_in_fields() {
  local line
  line="$(_plain_line $'Fix\033[39m' $'\033[38;5;2m' '' '' $'\033[0m')"
  assert_eq "escape-only fields render no refs" \
    "$(printf '%s\n' "$line" | _log__render unicode true)" \
    $'|  Fix\033[39m\033[0m'
}

run_tests "tt lib/log (unit)"
