#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for frontmatter helpers in lib/common.sh
# ---------------------------------------------------------------------------
# These tests operate directly on temp files (not through tt commands) to
# validate the AWK helpers in isolation.
# ---------------------------------------------------------------------------

# Helper: create a temp task file with the given frontmatter lines + no body
_make_task_file() {
  local path="$1"; shift
  {
    echo '---'
    for line in "$@"; do echo "$line"; done
    echo '---'
  } > "$path"
}

# ---------------------------------------------------------------------------
# append_frontmatter_context
# ---------------------------------------------------------------------------

test_append_frontmatter_context__inserts_before_subtask() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/child-abc12345"

  append_frontmatter_context "$file" "context/research-xyz12345"

  local content
  content="$(cat "$file")"
  assert_frontmatter_order "context before subtask" "$content"

  local ctx_line sub_line
  ctx_line="$(printf '%s\n' "$content" | grep -n '^context:' | cut -d: -f1 | head -1)"
  sub_line="$(printf '%s\n' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "context line number before subtask line number" \
    "$([[ "$ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
}

test_append_frontmatter_context__inserts_before_closing_sep_when_no_subtask() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z"

  append_frontmatter_context "$file" "context/research-xyz12345"

  local content
  content="$(cat "$file")"
  assert_contains "context entry present" "$content" "context: context/research-xyz12345"
  assert_frontmatter_order "valid ordering" "$content"
}

test_append_frontmatter_context__multiple_contexts_before_subtask() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/child-abc12345"

  append_frontmatter_context "$file" "context/ctx1-aaa11111"
  append_frontmatter_context "$file" "context/ctx2-bbb22222"

  local content
  content="$(cat "$file")"
  assert_frontmatter_order "all contexts before subtask" "$content"

  local last_ctx_line sub_line
  last_ctx_line="$(printf '%s\n' "$content" | grep -n '^context:' | cut -d: -f1 | tail -1)"
  sub_line="$(printf '%s\n' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "last context line before first subtask line" \
    "$([[ "$last_ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
}

# ---------------------------------------------------------------------------
# append_frontmatter_subtask
# ---------------------------------------------------------------------------

test_append_frontmatter_subtask__inserts_after_context() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "context: context/research-xyz12345"

  append_frontmatter_subtask "$file" "task/child-abc12345"

  local content
  content="$(cat "$file")"
  assert_frontmatter_order "subtask after context" "$content"

  local ctx_line sub_line
  ctx_line="$(printf '%s\n' "$content" | grep -n '^context:' | cut -d: -f1 | head -1)"
  sub_line="$(printf '%s\n' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "context line before subtask line" \
    "$([[ "$ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
}

test_append_frontmatter_subtask__inserts_at_end_when_empty() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z"

  append_frontmatter_subtask "$file" "task/child-abc12345"

  local content
  content="$(cat "$file")"
  assert_contains "subtask entry present" "$content" "subtask: [ ] task/child-abc12345"
  assert_frontmatter_order "valid ordering" "$content"
}

# ---------------------------------------------------------------------------
# update_frontmatter_timestamp
# ---------------------------------------------------------------------------

test_update_frontmatter_timestamp__updates_in_place() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z"

  update_frontmatter_timestamp "$file" "2025-06-15T12:00:00Z"

  local content
  content="$(cat "$file")"
  assert_contains "updated timestamp changed" "$content" "updated: 2025-06-15T12:00:00Z"
  assert_not_contains "old timestamp gone" "$content" "updated: 2025-01-01T00:00:00Z"
}

# ---------------------------------------------------------------------------
# write_task_file
# ---------------------------------------------------------------------------

test_write_task_file__canonical_order() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  REWRITE_LABELS=("bug" "feature")
  REWRITE_CONTEXTS=("context/ctx1-aaa11111" "context/ctx2-bbb22222")
  REWRITE_SUBTASKS=("[ ] task/child-abc12345" "[x] task/child-def67890")

  write_task_file "$file" "My Task" "IN-PROGRESS" "Task body here." "2025-01-01T00:00:00Z" "2025-06-01T12:00:00Z"

  local content
  content="$(cat "$file")"
  assert_frontmatter_order "full rewrite canonical order" "$content"
  assert_contains "label bug" "$content" "label: bug"
  assert_contains "label feature" "$content" "label: feature"
  assert_contains "context 1" "$content" "context: context/ctx1-aaa11111"
  assert_contains "context 2" "$content" "context: context/ctx2-bbb22222"
  assert_contains "subtask 1" "$content" "subtask: [ ] task/child-abc12345"
  assert_contains "subtask 2" "$content" "subtask: [x] task/child-def67890"
  assert_contains "body preserved" "$content" "Task body here."

  unset REWRITE_LABELS REWRITE_CONTEXTS REWRITE_SUBTASKS
}

test_write_task_file__atomic_write() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  # Write an initial file
  _make_task_file "$file" "title: \"Old\""

  REWRITE_LABELS=()
  REWRITE_CONTEXTS=()
  REWRITE_SUBTASKS=()

  write_task_file "$file" "New Title" "TODO" "" "2025-01-01T00:00:00Z" "2025-06-01T12:00:00Z"

  local content
  content="$(cat "$file")"
  assert_contains "title updated" "$content" 'title: "New Title"'

  unset REWRITE_LABELS REWRITE_CONTEXTS REWRITE_SUBTASKS
}

test_write_task_file__label_before_context_before_subtask() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  REWRITE_LABELS=("enhancement")
  REWRITE_CONTEXTS=("context/plan-abc12345")
  REWRITE_SUBTASKS=("[ ] task/child-def67890")

  write_task_file "$file" "Task" "TODO" "" "2025-01-01T00:00:00Z" "2025-06-01T12:00:00Z"

  local content
  content="$(cat "$file")"
  assert_frontmatter_order "label before context before subtask" "$content"

  local lbl_line ctx_line sub_line
  lbl_line="$(printf '%s\n' "$content" | grep -n '^label:' | cut -d: -f1 | head -1)"
  ctx_line="$(printf '%s\n' "$content" | grep -n '^context:' | cut -d: -f1 | head -1)"
  sub_line="$(printf '%s\n' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "label before context" \
    "$([[ "$lbl_line" -lt "$ctx_line" ]] && echo yes || echo no)" "yes"
  assert_eq "context before subtask" \
    "$([[ "$ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"

  unset REWRITE_LABELS REWRITE_CONTEXTS REWRITE_SUBTASKS
}

test_write_task_file__omits_status_when_empty() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  REWRITE_LABELS=()
  REWRITE_CONTEXTS=()
  REWRITE_SUBTASKS=()

  write_task_file "$file" "No Status" "" "" "2025-01-01T00:00:00Z" "2025-06-01T12:00:00Z"

  local content
  content="$(cat "$file")"
  assert_not_contains "no status line" "$content" "^status:"
  assert_contains "title present" "$content" 'title: "No Status"'

  unset REWRITE_LABELS REWRITE_CONTEXTS REWRITE_SUBTASKS
}

# ---------------------------------------------------------------------------
# write_context_file
# ---------------------------------------------------------------------------

test_write_context_file__fields() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/context.md"

  write_context_file "$file" "My Context" "Context body." "2025-01-01T00:00:00Z" "2025-06-01T12:00:00Z"

  local content
  content="$(cat "$file")"
  assert_contains "title" "$content" 'title: "My Context"'
  assert_contains "created" "$content" 'created: 2025-01-01T00:00:00Z'
  assert_contains "updated" "$content" 'updated: 2025-06-01T12:00:00Z'
  assert_contains "body" "$content" 'Context body.'
  assert_not_contains "no status" "$content" '^status:'
  assert_not_contains "no label" "$content" '^label:'
  assert_not_contains "no context ref" "$content" '^context:'
  assert_not_contains "no subtask" "$content" '^subtask:'
}

# ---------------------------------------------------------------------------
# write_task_stub (via task/create)
# ---------------------------------------------------------------------------

test_write_task_stub__has_placeholder_title() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  local suffix="my-stub-abc12345"
  write_task_stub "$dir" "$suffix" 2>/dev/null

  local file="$dir/.tt/task/$suffix/TASK.md"
  local content
  content="$(cat "$file")"
  assert_contains "placeholder title line" "$content" 'title: ""'
  assert_contains "status TODO" "$content" 'status: TODO'
}

# ---------------------------------------------------------------------------
# parse_frontmatter_fields and friends
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

test_parse_frontmatter_fields__ignores_body_fence() {
  local out
  out="$(parse_frontmatter_fields "$(_content_with_body_fence)" title status)"
  assert_eq "only leading-block entries" "$out" \
    "$(printf 'title:"Real title"\nstatus:DONE')"
}

test_parse_frontmatter_fields__preserves_file_order() {
  local content out
  content="$(printf '%s\n' '---' 'status: TODO' 'title: "T"' 'label: bug' '---')"
  out="$(parse_frontmatter_fields "$content" title status label)"
  assert_eq "fields in file order" "$out" \
    "$(printf 'status:TODO\ntitle:"T"\nlabel:bug')"
}

test_parse_frontmatter_fields__requires_leading_delimiter() {
  local content out
  content="$(printf '%s\n' 'Some prose' '---' 'title: "T"' '---')"
  out="$(parse_frontmatter_fields "$content" title)"
  assert_eq "no frontmatter without leading delimiter" "$out" ""
}

test_parse_frontmatter_fields__empty_content() {
  local out exit_code=0
  out="$(parse_frontmatter_fields "" title)" || exit_code=$?
  assert_success "empty content succeeds" "$exit_code"
  assert_eq "empty content yields no output" "$out" ""
}

test_parse_frontmatter_fields__ignores_prefix_collision() {
  local content out
  content="$(printf '%s\n' '---' 'titlefoo: nope' 'title: yes' '---')"
  out="$(parse_frontmatter_fields "$content" title)"
  assert_eq "prefix-collision key not matched" "$out" "title:yes"
}

test_parse_frontmatter_field__first_occurrence_wins() {
  local content
  content="$(printf '%s\n' '---' 'title: FIRST' 'title: SECOND' '---')"
  assert_eq "first duplicate wins" "$(parse_frontmatter_field "$content" title)" "FIRST"
}

test_parse_frontmatter_field__absent_field() {
  local content
  content="$(printf '%s\n' '---' 'title: T' '---')"
  assert_eq "absent field yields nothing" "$(parse_frontmatter_field "$content" status)" ""
}

test_parse_frontmatter_field__preserves_quotes() {
  local content
  content="$(printf '%s\n' '---' 'title: "Quoted"' '---')"
  assert_eq "quotes preserved" "$(parse_frontmatter_field "$content" title)" '"Quoted"'
}

test_parse_frontmatter_field__value_containing_colon() {
  local content
  content="$(printf '%s\n' '---' 'title: "A: colon"' '---')"
  assert_eq "colon in value preserved" \
    "$(parse_frontmatter_field "$content" title)" '"A: colon"'
  assert_eq "colon in unquoted value" \
    "$(parse_quoted_frontmatter_field "$content" title)" 'A: colon'
}

test_parse_quoted_frontmatter_field__strips_matched_pair_only() {
  local content
  content="$(printf '%s\n' '---' 'title: "Quoted"' 'status: "unmatched' '---')"
  assert_eq "matched pair stripped" \
    "$(parse_quoted_frontmatter_field "$content" title)" "Quoted"
  assert_eq "unmatched quote left alone" \
    "$(parse_quoted_frontmatter_field "$content" status)" '"unmatched'
}

test_parse_repeated_frontmatter_field__all_values_in_order() {
  local out
  out="$(parse_repeated_frontmatter_field "$(_content_with_body_fence)" subtask)"
  assert_eq "all subtasks, body fence excluded" "$out" \
    "$(printf '[x] task/a-1 Title A\n[ ] task/b-2')"
}

test_parse_repeated_frontmatter_field__absent_key() {
  local content
  content="$(printf '%s\n' '---' 'title: T' '---')"
  assert_eq "absent repeated key yields nothing" \
    "$(parse_repeated_frontmatter_field "$content" label)" ""
}

test_parse_task_frontmatter__ignores_body_fence() {
  local content
  content="$(printf '%s\n' \
    '---' \
    'title: "Real title"' \
    'status: DONE' \
    'label: bug' \
    'context: context/notes-abc12345' \
    'subtask: [x] task/a-1 Title A' \
    '---' \
    'Body:' \
    '' \
    '```markdown' \
    '---' \
    'label: fake' \
    'context: context/fake-99' \
    'subtask: [ ] task/fake-99' \
    '---' \
    '```')"

  parse_task_frontmatter "$content"

  assert_eq "title" "$PARSED_TITLE" "Real title"
  assert_eq "status" "$PARSED_STATUS" "DONE"
  assert_eq "label count" "${#PARSED_LABELS[@]}" "1"
  assert_eq "label" "${PARSED_LABELS[0]}" "bug"
  assert_eq "context count" "${#PARSED_CONTEXTS[@]}" "1"
  assert_eq "context" "${PARSED_CONTEXTS[0]}" "context/notes-abc12345"
  assert_eq "subtask count" "${#PARSED_SUBTASKS[@]}" "1"
  assert_eq "subtask" "${PARSED_SUBTASKS[0]}" "[x] task/a-1 Title A"
}

# ---------------------------------------------------------------------------
# select_value
# ---------------------------------------------------------------------------

test_select_value__custom_picker_selects_option() {
  local out exit_code=0
  out="$(printf 'task/foo\ntask/bar\ntask/baz\n' | TT_SELECT='head -n 2 | tail -n 1' select_value)" || exit_code=$?
  assert_success "select succeeds" "$exit_code"
  assert_eq "selected option" "$out" "task/bar"
}

test_select_value__custom_picker_receives_options_on_stdin() {
  local capture out
  capture="$(mktemp)"
  trap 'rm -f "$capture"' RETURN

  out="$(printf 'task/foo\ntask/bar\n' | TT_SELECT="cat > '$capture'; head -n 1 '$capture'" select_value)"
  assert_eq "selected option" "$out" "task/foo"
  assert_eq "picker stdin" "$(cat "$capture")" "$(printf 'task/foo\ntask/bar')"
}

test_select_value__rejects_output_not_in_options() {
  local out exit_code=0
  out="$(printf 'task/foo\ntask/bar\n' | TT_SELECT='echo task/nope' select_value 2>&1)" || exit_code=$?
  assert_failure "non-matching output fails" "$exit_code"
  assert_contains "error message" "$out" "invalid selection: task/nope"
}

test_select_value__rejects_partial_match() {
  local exit_code=0
  printf 'task/foobar\n' | TT_SELECT='echo task/foo' select_value >/dev/null 2>&1 || exit_code=$?
  assert_failure "prefix of an option is not a match" "$exit_code"
}

test_select_value__empty_input_fails() {
  local out exit_code=0
  out="$(printf '' | TT_SELECT='cat' select_value 2>&1)" || exit_code=$?
  assert_failure "empty input fails" "$exit_code"
  assert_contains "error message" "$out" "no options provided"
}

test_select_value__failing_picker_command_fails() {
  local out exit_code=0
  out="$(printf 'task/foo\n' | TT_SELECT='exit 3' select_value 2>&1)" || exit_code=$?
  assert_failure "failing picker fails" "$exit_code"
  assert_contains "error message" "$out" "picker command failed"
}

# Note: the built-in picker (_select_value) is not unit-tested. It reads from
# /dev/tty, and there is no portable way to run a test with the controlling
# terminal detached (macOS has no setsid), so any such test would pass headless
# and fail when the suite is run from a real terminal.

run_tests "tt lib/common (unit)"
