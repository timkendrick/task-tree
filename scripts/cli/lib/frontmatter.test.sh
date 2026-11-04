#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for frontmatter helpers in lib/frontmatter.sh
# ---------------------------------------------------------------------------
# These tests operate directly on strings and temp files (not through tt
# commands) to validate the helpers in isolation.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# _frontmatter__parse_fields and friends
# ---------------------------------------------------------------------------

# Helper: content whose body contains a fenced code block documenting
# frontmatter layout. The '---', 'title:' and 'status:' lines inside the fence
# must never be mistaken for frontmatter.
_content_with_body_fence() {
  printf '%s\n' \
    '---' \
    'title: "Real title"' \
    'status: DONE' \
    'subtask: [x] task/a-1 Title A' \
    'subtask: [ ] task/b-2' \
    '---' \
    'The correct order should be:' \
    '' \
    '```markdown' \
    '---' \
    'title:' \
    'status:' \
    'subtask: [ ] task/fake-99' \
    '---' \
    '```'
}

test__frontmatter__parse_fields__ignores_body_fence() {
  local out
  out="$(_frontmatter__parse_fields "$(_content_with_body_fence)" title status)"
  assert_eq "only leading-block entries" "$out" \
    "$(printf 'title:"Real title"\nstatus:DONE')"
}

test__frontmatter__parse_fields__preserves_file_order() {
  local content out
  content="$(printf '%s\n' '---' 'status: TODO' 'title: "T"' 'label: bug' '---')"
  out="$(_frontmatter__parse_fields "$content" title status label)"
  assert_eq "fields in file order" "$out" \
    "$(printf 'status:TODO\ntitle:"T"\nlabel:bug')"
}

test__frontmatter__parse_fields__requires_leading_delimiter() {
  local content out
  content="$(printf '%s\n' 'Some prose' '---' 'title: "T"' '---')"
  out="$(_frontmatter__parse_fields "$content" title)"
  assert_eq "no frontmatter without leading delimiter" "$out" ""
}

test__frontmatter__parse_fields__empty_content() {
  local out exit_code=0
  out="$(_frontmatter__parse_fields "" title)" || exit_code=$?
  assert_success "empty content succeeds" "$exit_code"
  assert_eq "empty content yields no output" "$out" ""
}

test__frontmatter__parse_fields__ignores_prefix_collision() {
  local content out
  content="$(printf '%s\n' '---' 'titlefoo: nope' 'title: yes' '---')"
  out="$(_frontmatter__parse_fields "$content" title)"
  assert_eq "prefix-collision key not matched" "$out" "title:yes"
}

test__frontmatter__parse_field__first_occurrence_wins() {
  local content
  content="$(printf '%s\n' '---' 'title: FIRST' 'title: SECOND' '---')"
  assert_eq "first duplicate wins" "$(_frontmatter__parse_field "$content" title)" "FIRST"
}

test__frontmatter__parse_field__absent_field() {
  local content
  content="$(printf '%s\n' '---' 'title: T' '---')"
  assert_eq "absent field yields nothing" "$(_frontmatter__parse_field "$content" status)" ""
}

test__frontmatter__parse_field__preserves_quotes() {
  local content
  content="$(printf '%s\n' '---' 'title: "Quoted"' '---')"
  assert_eq "quotes preserved" "$(_frontmatter__parse_field "$content" title)" '"Quoted"'
}

test__frontmatter__parse_field__value_containing_colon() {
  local content
  content="$(printf '%s\n' '---' 'title: "A: colon"' '---')"
  assert_eq "colon in value preserved" \
    "$(_frontmatter__parse_field "$content" title)" '"A: colon"'
  assert_eq "colon in unquoted value" \
    "$(_frontmatter__parse_quoted_field "$content" title)" 'A: colon'
}

test__frontmatter__parse_quoted_field__strips_matched_pair_only() {
  local content
  content="$(printf '%s\n' '---' 'title: "Quoted"' 'status: "unmatched' '---')"
  assert_eq "matched pair stripped" \
    "$(_frontmatter__parse_quoted_field "$content" title)" "Quoted"
  assert_eq "unmatched quote left alone" \
    "$(_frontmatter__parse_quoted_field "$content" status)" '"unmatched'
}

test__frontmatter__parse_quoted_field__decodes_json_escapes() {
  local content
  content="$(printf '%s\n' '---' 'title: "line\nbreak \/ slash \\ back \"q\" \t tab \u00e9 kept \x odd"' '---')"
  assert_eq "basic escapes decoded, others kept as written" \
    "$(_frontmatter__parse_quoted_field "$content" title)" \
    $'line\nbreak / slash \\ back "q" \t tab \\u00e9 kept \\x odd'
}

test__frontmatter__parse_quoted_field__no_backslash_is_stripped_only() {
  local content
  content="$(printf '%s\n' '---' 'title: "plain title: with colon"' '---')"
  assert_eq "quotes stripped, value untouched" \
    "$(_frontmatter__parse_quoted_field "$content" title)" "plain title: with colon"
}

test__frontmatter__parse_values__argument_order_and_absent_fields() {
  local content
  content="$(printf '%s\n' '---' 'title: "T"' 'status: TODO' 'created: C' '---')"
  assert_eq "values follow argument order" \
    "$(_frontmatter__parse_values "$content" created status title)" $'C\nTODO\nT'
  assert_eq "an absent middle field prints an empty line" \
    "$(_frontmatter__parse_values "$content" title updated status)" $'T\n\nTODO'
  assert_eq "an absent last field prints an empty line" \
    "$(_frontmatter__parse_values "$content" status updated; printf x)" $'TODO\n\nx'
}

test__frontmatter__parse_values__decodes_quoted_and_keeps_unquoted() {
  local content
  content="$(printf '%s\n' '---' 'title: "a \"q\" \\ b\nc"' 'status: IN-PROGRESS' '---')"
  assert_eq "a quoted title is decoded, then line-encoded" \
    "$(_frontmatter__parse_values "$content" title)" 'a "q" \\ b\nc'
  assert_eq "the line decodes to the title" \
    "$(_frontmatter__decode "$(_frontmatter__parse_values "$content" title)")" \
    $'a "q" \\ b\nc'
  assert_eq "an unquoted status is printed unchanged" \
    "$(_frontmatter__parse_values "$content" status)" "IN-PROGRESS"
}

test__frontmatter__parse_values__quoted_newline_keeps_later_fields_aligned() {
  local content title status label_count label
  content="$(printf '%s\n' '---' 'title: "Line one\nline two"' 'status: TODO' \
    'label: bug' '---')"
  assert_eq "one line per single-valued field" \
    "$(_frontmatter__parse_values "$content" title status 'label[]')" \
    $'Line one\\nline two\nTODO\n1\nbug'
  { IFS= read -r title; IFS= read -r status; IFS= read -r label_count
    IFS= read -r label
  } <<< "$(_frontmatter__parse_values "$content" title status 'label[]')" || true
  assert_eq "the title decodes to two lines" \
    "$(_frontmatter__decode "$title")" $'Line one\nline two'
  assert_eq "the status is not shifted" "$status" 'TODO'
  assert_eq "the label count is not shifted" "$label_count" '1'
  assert_eq "the label is not shifted" "$label" 'bug'
}

test__frontmatter__parse_values__newline_and_backslash_n_stay_distinct() {
  local newline backslash_n
  newline="$(printf '%s\n' '---' 'title: "a\nb"' '---')"
  backslash_n="$(printf '%s\n' '---' 'title: "a\\nb"' '---')"
  assert_eq "a newline is encoded as \\n" \
    "$(_frontmatter__parse_values "$newline" title)" 'a\nb'
  assert_eq "a backslash before n is encoded as \\\\n" \
    "$(_frontmatter__parse_values "$backslash_n" title)" 'a\\nb'
  assert_eq "the newline decodes back" \
    "$(_frontmatter__decode "$(_frontmatter__parse_values "$newline" title)")" $'a\nb'
  assert_eq "the backslash and n decode back" \
    "$(_frontmatter__decode "$(_frontmatter__parse_values "$backslash_n" title)")" 'a\nb'
}

test__frontmatter__decode__inverts_the_line_encoding() {
  assert_eq "a line without a backslash is unchanged" \
    "$(_frontmatter__decode 'plain: "text"')" 'plain: "text"'
  assert_eq "\\\\ and \\n are decoded" \
    "$(_frontmatter__decode 'a\\b\nc\\\\n')" $'a\\b\nc\\\\n'
  assert_eq "any other backslash is kept" \
    "$(_frontmatter__decode 'a\tb\')" 'a\tb\'
}

test__frontmatter__decode__round_trips_quoted_values() {
  local value content
  for value in 'plain' 'Say "hi"' 'back\slash' 'literal \n' $'two\nlines' $'tab\there' \
    $'trailing\\\nnewline after backslash'; do
    content="$(_frontmatter__format_block title "$(_frontmatter__quote "$value")")"
    assert_eq "round trip: $value" \
      "$(_frontmatter__decode "$(_frontmatter__parse_values "$content" title)")" "$value"
  done
}

test__frontmatter__parse_values__first_occurrence_and_body_ignored() {
  local content
  content="$(printf '%s\n' '---' 'status:' 'status: DONE' 'title: "T"' '---' \
    'status: BODY' '---' 'title: body')"
  assert_eq "the first occurrence wins, even when empty; body ignored" \
    "$(_frontmatter__parse_values "$content" title status; printf x)" $'T\n\nx'
}

# Frontmatter with two subtasks (one with an empty value), one label and a
# body that mimics a subtask entry.
_content_with_lists() {
  printf '%s\n' '---' 'title: "T"' 'subtask: [x] task/a-1 Title A' 'label: l' \
    'subtask:' 'status: TODO' '---' 'subtask: [ ] task/body-9'
}

test__frontmatter__parse_values__list_entries_in_file_order() {
  assert_eq "count then raw entries, empty entry kept, body ignored" \
    "$(_frontmatter__parse_values "$(_content_with_lists)" 'subtask[]' status)" \
    $'2\n[x] task/a-1 Title A\n\nTODO'
}

test__frontmatter__parse_values__absent_list_counts_zero() {
  assert_eq "an absent list in the middle prints a zero count" \
    "$(_frontmatter__parse_values "$(_content_with_lists)" title 'context[]' status)" \
    $'T\n0\nTODO'
  assert_eq "an absent list at the end prints a zero count" \
    "$(_frontmatter__parse_values "$(_content_with_lists)" status 'context[]')" $'TODO\n0'
}

test__frontmatter__parse_values__two_lists_and_repeats() {
  assert_eq "two lists in one call" \
    "$(_frontmatter__parse_values "$(_content_with_lists)" 'label[]' 'subtask[]')" \
    $'1\nl\n2\n[x] task/a-1 Title A'
  assert_eq "a field requested twice is printed twice" \
    "$(_frontmatter__parse_values "$(_content_with_lists)" 'label[]' title 'label[]' title)" \
    $'1\nl\nT\n1\nl\nT'
}

test__frontmatter__parse_values__plain_repeatable_field_is_first_value() {
  assert_eq "a plain repeatable field gives its first value" \
    "$(_frontmatter__parse_values "$(_content_with_lists)" subtask)" '[x] task/a-1 Title A'
}

test__frontmatter__parse_values__documented_unpacking() {
  local title subtask_count subtask subtasks=() i
  { IFS= read -r title; IFS= read -r subtask_count
    for (( i = 0; i < subtask_count; i++ )); do
      IFS= read -r subtask; subtasks+=("$subtask")
    done
  } <<< "$(_frontmatter__parse_values "$(_content_with_lists)" title 'subtask[]')" || true
  assert_eq "title unpacked" "$title" "T"
  assert_eq "count unpacked" "$subtask_count" "2"
  assert_eq "a trailing empty entry survives command substitution" \
    "${#subtasks[@]}:${subtasks[0]}:${subtasks[1]}" "2:[x] task/a-1 Title A:"
}

test__frontmatter__parse_values__body_follows_the_fields() {
  local content
  content="$(printf '%s\n' '---' 'title: "T"' 'subtask: [ ] task/a-1' '---' '' \
    'Body line' '---' 'status: not a field')"
  assert_eq "fields, then the body verbatim" \
    "$(_frontmatter__parse_values "$content" title 'subtask[]' '...')" \
    $'T\n1\n[ ] task/a-1\n\nBody line\n---\nstatus: not a field'
}

test__frontmatter__parse_values__documented_body_unpacking() {
  local content title body
  content="$(printf '%s\n' '---' 'title: "T"' '---' '' '  indented' 'last')"
  { IFS= read -r title; IFS= read -r -d '' body; } \
    <<< "$(_frontmatter__parse_values "$content" title '...')" || true
  body="${body%$'\n'}"
  assert_eq "title unpacked" "$title" "T"
  assert_eq "body unpacked verbatim" "$body" $'\n  indented\nlast'
}

test__frontmatter__parse_values__body_only_and_empty_body() {
  local content
  content="$(printf '%s\n' '---' 'title: "T"' '---')"
  assert_eq "an empty body prints nothing" "$(_frontmatter__parse_values "$content" '...')" ''
  assert_eq "an empty body after a field" \
    "$(_frontmatter__parse_values "$content" title '...')" 'T'
}

test__frontmatter__parse_values__body_must_be_last() {
  local output exit_code=0
  output="$(_frontmatter__parse_values "$(_content_with_lists)" '...' title 2>/dev/null)" \
    || exit_code=$?
  assert_failure "'...' before another request is rejected" "$exit_code"
  assert_eq "nothing printed when '...' is misplaced" "$output" ''
}

test__frontmatter__format_block__writes_pairs_in_order() {
  local block
  block="$(_frontmatter__format_block title "$(_frontmatter__quote 'Say "hi"')" \
    label a label b)"
  assert_eq "one raw line per pair, repeated keys kept" "$block" \
    $'---\ntitle: "Say \\"hi\\""\nlabel: a\nlabel: b\n---'
  assert_eq "the block parses back" \
    "$(_frontmatter__parse_values "$block" title 'label[]')" $'Say "hi"\n2\na\nb'
}

test__frontmatter__parse_repeated_field__all_values_in_order() {
  local out
  out="$(_frontmatter__parse_repeated_field "$(_content_with_body_fence)" subtask)"
  assert_eq "all subtasks, body fence excluded" "$out" \
    "$(printf '[x] task/a-1 Title A\n[ ] task/b-2')"
}

test__frontmatter__parse_repeated_field__absent_key() {
  local content
  content="$(printf '%s\n' '---' 'title: T' '---')"
  assert_eq "absent repeated key yields nothing" \
    "$(_frontmatter__parse_repeated_field "$content" label)" ""
}

# ---------------------------------------------------------------------------
# _frontmatter__set_field, _frontmatter__remove_entry, _frontmatter__replace_entry
# ---------------------------------------------------------------------------

# Writes a task file with duplicate entries and a body that mimics them.
_make_entry_file() {
  printf '%s\n' '---' 'title: "T"' 'status: TODO' 'context: c/a' 'label: l' \
    'context: c/b' 'context:   c/a' 'status: DONE' '---' 'context: c/a' 'status: BODY' > "$1"
}

test__frontmatter__set_field__rewrites_first_and_drops_duplicates() {
  local file="$_TEST_ROOT/set.md"
  _make_entry_file "$file"
  _frontmatter__set_field "$file" status IN-PROGRESS
  assert_eq "first line rewritten, later one dropped, body untouched" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'status: IN-PROGRESS' 'context: c/a' 'label: l' \
      'context: c/b' 'context:   c/a' '---' 'context: c/a' 'status: BODY')"
}

test__frontmatter__set_field__appends_an_absent_field() {
  local file="$_TEST_ROOT/set-absent.md"
  _make_entry_file "$file"
  _frontmatter__set_field "$file" updated U
  assert_eq "appended before the closing delimiter" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'status: TODO' 'context: c/a' 'label: l' \
      'context: c/b' 'context:   c/a' 'status: DONE' 'updated: U' '---' 'context: c/a' 'status: BODY')"
}

test__frontmatter__remove_entry__removes_every_match() {
  local file="$_TEST_ROOT/remove.md"
  _make_entry_file "$file"
  _frontmatter__remove_entry "$file" context c/a
  assert_eq "every frontmatter match removed, body untouched" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'status: TODO' 'label: l' 'context: c/b' \
      'status: DONE' '---' 'context: c/a' 'status: BODY')"
}

test__frontmatter__replace_entry__replaces_every_match_in_place() {
  local file="$_TEST_ROOT/replace.md"
  _make_entry_file "$file"
  _frontmatter__replace_entry "$file" context c/a c/z
  assert_eq "every frontmatter match replaced in position, body untouched" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'status: TODO' 'context: c/z' 'label: l' \
      'context: c/b' 'context: c/z' 'status: DONE' '---' 'context: c/a' 'status: BODY')"
}

test__frontmatter__entry_mutators__no_match_leaves_file_unchanged() {
  local file="$_TEST_ROOT/nomatch.md" before exit_code=0
  _make_entry_file "$file"
  before="$(<"$file")"
  _frontmatter__remove_entry "$file" context c/none || exit_code=$?
  _frontmatter__replace_entry "$file" label none other || exit_code=$?
  assert_success "no match returns 0" "$exit_code"
  assert_eq "file unchanged" "$(<"$file")" "$before"
}

test__frontmatter__entry_mutators__file_without_frontmatter_unchanged() {
  local file="$_TEST_ROOT/nofm.md" before
  printf '%s\n' 'status: TODO' 'context: c/a' > "$file"
  before="$(<"$file")"
  _frontmatter__set_field "$file" status DONE
  _frontmatter__remove_entry "$file" context c/a
  _frontmatter__replace_entry "$file" status TODO DONE
  assert_eq "file unchanged" "$(<"$file")" "$before"
}

test__frontmatter__set_entries__replaces_at_the_first_position() {
  local file="$_TEST_ROOT/entries.md"
  printf '%s\n' '---' 'title: "T"' 'subtask: [ ] task/a-1' 'status: TODO' \
    'subtask: [x] task/b-2' '---' 'subtask: body' > "$file"
  _frontmatter__set_entries "$file" subtask '[x] task/b-2' '[ ] task/a-1'
  assert_eq "entries replaced in order at the first entry's position, body kept" \
    "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'subtask: [x] task/b-2' 'subtask: [ ] task/a-1' \
      'status: TODO' '---' 'subtask: body')"
}

test__frontmatter__set_entries__appends_when_absent_and_removes_when_empty() {
  local file="$_TEST_ROOT/entries-absent.md"
  printf '%s\n' '---' 'title: "T"' '---' > "$file"
  _frontmatter__set_entries "$file" label a b
  assert_eq "absent entries appended before the closing delimiter" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'label: a' 'label: b' '---')"
  _frontmatter__set_entries "$file" label
  assert_eq "no values removes every entry" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' '---')"
}

test__frontmatter__set_entries__absent_entries_go_before_the_anchor_keys() {
  local file="$_TEST_ROOT/entries-before.md"
  printf '%s\n' '---' 'title: "T"' 'subtask: [ ] task/a-1' '---' > "$file"
  _frontmatter__set_entries --before 'context subtask' "$file" label a b
  assert_eq "absent entries inserted before the first anchor key" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'label: a' 'label: b' 'subtask: [ ] task/a-1' '---')"
  _frontmatter__set_entries --before 'context subtask' "$file" label c
  assert_eq "present entries stay in place" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'label: c' 'subtask: [ ] task/a-1' '---')"
}

test__frontmatter__set_field__absent_field_goes_before_the_anchor_keys() {
  local file="$_TEST_ROOT/field-before.md"
  printf '%s\n' '---' 'title: "T"' 'updated: U' 'label: l' '---' > "$file"
  _frontmatter__set_field --before 'updated label' "$file" created C
  assert_eq "absent field inserted before the first anchor key" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'created: C' 'updated: U' 'label: l' '---')"
}

test__frontmatter__add_entry__after_the_last_entry() {
  local file="$_TEST_ROOT/add-entry.md"
  printf '%s\n' '---' 'title: "T"' 'context: c-1' 'subtask: [ ] a' 'context: c-2' \
    'subtask: [ ] b' '---' 'context: body' > "$file"
  _frontmatter__add_entry --before subtask "$file" context c-3
  assert_eq "added after the last existing entry, body ignored" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'context: c-1' 'subtask: [ ] a' 'context: c-2' \
      'context: c-3' 'subtask: [ ] b' '---' 'context: body')"
}

test__frontmatter__add_entry__absent_key_goes_before_the_anchor_keys() {
  local file="$_TEST_ROOT/add-entry-absent.md"
  printf '%s\n' '---' 'title: "T"' 'subtask: [ ] a' '---' > "$file"
  _frontmatter__add_entry --before 'context subtask' "$file" context c-1
  assert_eq "inserted before the first anchor key" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'context: c-1' 'subtask: [ ] a' '---')"
  _frontmatter__add_entry "$file" label l
  assert_eq "without anchors, inserted before the closing delimiter" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'context: c-1' 'subtask: [ ] a' 'label: l' '---')"
}

test__frontmatter__add_entry__leaves_a_file_without_frontmatter() {
  local file="$_TEST_ROOT/add-entry-plain.md"
  printf '%s\n' 'plain' > "$file"
  _frontmatter__add_entry "$file" label l
  assert_eq "no frontmatter: unchanged" "$(<"$file")" 'plain'
}

test__frontmatter__set_body__replaces_the_body() {
  local file="$_TEST_ROOT/body.md"
  printf '%s\n' '---' 'title: "T"' '---' 'old' '---' 'old too' > "$file"
  _frontmatter__set_body "$file" $'new\n\nbody'
  assert_eq "everything after the closing delimiter replaced" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' '---' 'new' '' 'body')"
  _frontmatter__set_body "$file" ''
  assert_eq "an empty body leaves nothing after the delimiter" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' '---')"
}

test__frontmatter__set_body__leaves_a_file_without_frontmatter() {
  local file="$_TEST_ROOT/no-fm.md"
  printf '%s\n' 'plain' > "$file"
  _frontmatter__set_body "$file" 'new'
  assert_eq "no frontmatter: unchanged" "$(<"$file")" 'plain'
}

run_tests "tt lib/frontmatter (unit)"
