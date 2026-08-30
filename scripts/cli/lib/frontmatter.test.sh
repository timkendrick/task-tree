#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for frontmatter helpers in lib/frontmatter.sh
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
# _frontmatter__append_context
# ---------------------------------------------------------------------------

test__frontmatter__append_context__inserts_before_subtask() {
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

  _frontmatter__append_context "$file" "context/research-xyz12345"

  local content
  content="$(cat "$file")"
  assert_frontmatter_order "context before subtask" "$content"

  local ctx_line sub_line
  ctx_line="$(printf '%s\n' "$content" | grep -n '^context:' | cut -d: -f1 | head -1)"
  sub_line="$(printf '%s\n' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "context line number before subtask line number" \
    "$([[ "$ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
}

test__frontmatter__append_context__inserts_before_closing_sep_when_no_subtask() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z"

  _frontmatter__append_context "$file" "context/research-xyz12345"

  local content
  content="$(cat "$file")"
  assert_contains "context entry present" "$content" "context: context/research-xyz12345"
  assert_frontmatter_order "valid ordering" "$content"
}

test__frontmatter__append_context__multiple_contexts_before_subtask() {
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

  _frontmatter__append_context "$file" "context/ctx1-aaa11111"
  _frontmatter__append_context "$file" "context/ctx2-bbb22222"

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
# _frontmatter__append_subtask
# ---------------------------------------------------------------------------

test__frontmatter__append_subtask__inserts_after_context() {
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

  _frontmatter__append_subtask "$file" "task/child-abc12345"

  local content
  content="$(cat "$file")"
  assert_frontmatter_order "subtask after context" "$content"

  local ctx_line sub_line
  ctx_line="$(printf '%s\n' "$content" | grep -n '^context:' | cut -d: -f1 | head -1)"
  sub_line="$(printf '%s\n' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "context line before subtask line" \
    "$([[ "$ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
}

test__frontmatter__append_subtask__inserts_at_end_when_empty() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z"

  _frontmatter__append_subtask "$file" "task/child-abc12345"

  local content
  content="$(cat "$file")"
  assert_contains "subtask entry present" "$content" "subtask: [ ] task/child-abc12345"
  assert_frontmatter_order "valid ordering" "$content"
}

# ---------------------------------------------------------------------------
# _frontmatter__update_timestamp
# ---------------------------------------------------------------------------

test__frontmatter__update_timestamp__updates_in_place() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z"

  _frontmatter__update_timestamp "$file" "2025-06-15T12:00:00Z"

  local content
  content="$(cat "$file")"
  assert_contains "updated timestamp changed" "$content" "updated: 2025-06-15T12:00:00Z"
  assert_not_contains "old timestamp gone" "$content" "updated: 2025-01-01T00:00:00Z"
}

# ---------------------------------------------------------------------------
# _frontmatter__write_task_file
# ---------------------------------------------------------------------------

test__frontmatter__write_task_file__canonical_order() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  REWRITE_LABELS=("bug" "feature")
  REWRITE_CONTEXTS=("context/ctx1-aaa11111" "context/ctx2-bbb22222")
  REWRITE_SUBTASKS=("[ ] task/child-abc12345" "[x] task/child-def67890")

  _frontmatter__write_task_file "$file" "My Task" "IN-PROGRESS" "Task body here." "2025-01-01T00:00:00Z" "2025-06-01T12:00:00Z"

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

test__frontmatter__write_task_file__atomic_write() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  # Write an initial file
  _make_task_file "$file" "title: \"Old\""

  REWRITE_LABELS=()
  REWRITE_CONTEXTS=()
  REWRITE_SUBTASKS=()

  _frontmatter__write_task_file "$file" "New Title" "TODO" "" "2025-01-01T00:00:00Z" "2025-06-01T12:00:00Z"

  local content
  content="$(cat "$file")"
  assert_contains "title updated" "$content" 'title: "New Title"'

  unset REWRITE_LABELS REWRITE_CONTEXTS REWRITE_SUBTASKS
}

test__frontmatter__write_task_file__label_before_context_before_subtask() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  REWRITE_LABELS=("enhancement")
  REWRITE_CONTEXTS=("context/plan-abc12345")
  REWRITE_SUBTASKS=("[ ] task/child-def67890")

  _frontmatter__write_task_file "$file" "Task" "TODO" "" "2025-01-01T00:00:00Z" "2025-06-01T12:00:00Z"

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

test__frontmatter__write_task_file__omits_status_when_empty() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  REWRITE_LABELS=()
  REWRITE_CONTEXTS=()
  REWRITE_SUBTASKS=()

  _frontmatter__write_task_file "$file" "No Status" "" "" "2025-01-01T00:00:00Z" "2025-06-01T12:00:00Z"

  local content
  content="$(cat "$file")"
  assert_not_contains "no status line" "$content" "^status:"
  assert_contains "title present" "$content" 'title: "No Status"'

  unset REWRITE_LABELS REWRITE_CONTEXTS REWRITE_SUBTASKS
}

# ---------------------------------------------------------------------------
# _frontmatter__write_context_file
# ---------------------------------------------------------------------------

test__frontmatter__write_context_file__fields() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/context.md"

  _frontmatter__write_context_file "$file" "My Context" "Context body." "2025-01-01T00:00:00Z" "2025-06-01T12:00:00Z"

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

test__frontmatter__parse_task__ignores_body_fence() {
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

  _frontmatter__parse_task "$content"

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
# _frontmatter__remove_subtask
# ---------------------------------------------------------------------------

test__frontmatter__remove_subtask__removes_any_checkbox_state() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/unchecked-aaa11111" \
    "subtask: [x] task/checked-bbb22222 Checked title" \
    "subtask: [-] task/skipped-ccc33333"

  _frontmatter__remove_subtask "$file" "task/unchecked-aaa11111"
  local content
  content="$(cat "$file")"
  assert_not_contains "unchecked entry removed" "$content" "task/unchecked-aaa11111"
  assert_contains "checked entry intact" "$content" \
    "subtask: [x] task/checked-bbb22222 Checked title"
  assert_contains "skipped entry intact" "$content" \
    "subtask: [-] task/skipped-ccc33333"

  _frontmatter__remove_subtask "$file" "task/checked-bbb22222"
  content="$(cat "$file")"
  assert_not_contains "checked entry with trailing title removed" \
    "$content" "task/checked-bbb22222"
  assert_contains "skipped entry still intact" "$content" \
    "subtask: [-] task/skipped-ccc33333"

  _frontmatter__remove_subtask "$file" "task/skipped-ccc33333"
  content="$(cat "$file")"
  assert_not_contains "skipped entry removed" "$content" "task/skipped-ccc33333"
  assert_not_contains "no subtask lines left" "$content" "subtask:"
  assert_contains "other frontmatter intact" "$content" 'title: "Test"'
}

test__frontmatter__remove_subtask__ignores_body_fence() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  # The body's fenced block repeats the exact frontmatter entry; only the
  # frontmatter occurrence may be removed.
  printf '%s\n' \
    '---' \
    'title: "Test"' \
    'subtask: [ ] task/real-abc12345' \
    '---' \
    'The frontmatter looked like:' \
    '' \
    '```markdown' \
    '---' \
    'subtask: [ ] task/real-abc12345' \
    '---' \
    '```' \
    > "$file"

  _frontmatter__remove_subtask "$file" "task/real-abc12345"

  local content
  content="$(cat "$file")"
  assert_output_empty "frontmatter has no subtask entries left" \
    "$(_frontmatter__parse_repeated_field "$content" subtask)"
  assert_eq "body occurrence survives" \
    "$(printf '%s\n' "$content" | grep -c 'subtask: \[ \] task/real-abc12345' || true)" \
    "1"
  assert_contains "body prose intact" "$content" "The frontmatter looked like:"
}

test__frontmatter__remove_subtask__nonexistent_entry_is_noop() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/present-aaa11111"

  local before
  before="$(cat "$file")"
  local exit_code=0
  _frontmatter__remove_subtask "$file" "task/absent-zzz99999" || exit_code=$?
  assert_success "removing a nonexistent entry returns 0" "$exit_code"
  assert_eq "file unchanged" "$(cat "$file")" "$before"
}

# ---------------------------------------------------------------------------
# _frontmatter__rename_subtask
# ---------------------------------------------------------------------------

test__frontmatter__rename_subtask__preserves_checkbox_title_and_order() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/first-aaa11111" \
    "subtask: [x] task/second-bbb22222 Second title" \
    "subtask: [-] task/third-ccc33333"

  _frontmatter__rename_subtask "$file" "task/second-bbb22222" "task/renamed-bbb22222"
  local content
  content="$(cat "$file")"
  assert_contains "entry repointed, checkbox and title kept" "$content" \
    "subtask: [x] task/renamed-bbb22222 Second title"
  assert_not_contains "old ID gone" "$content" "task/second-bbb22222"
  assert_eq "list order preserved" \
    "$(_frontmatter__parse_repeated_field "$content" subtask)" \
    "$(printf '[ ] task/first-aaa11111\n[x] task/renamed-bbb22222 Second title\n[-] task/third-ccc33333')"

  _frontmatter__rename_subtask "$file" "task/third-ccc33333" "task/last-ccc33333"
  content="$(cat "$file")"
  assert_contains "skipped-state entry repointed" "$content" \
    "subtask: [-] task/last-ccc33333"
  assert_contains "other frontmatter intact" "$content" 'title: "Test"'
}

test__frontmatter__rename_subtask__ignores_body_fence() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  # The body's fenced block repeats the exact frontmatter entry; only the
  # frontmatter occurrence may be rewritten.
  printf '%s\n' \
    '---' \
    'title: "Test"' \
    'subtask: [ ] task/real-abc12345' \
    '---' \
    'The frontmatter looked like:' \
    '' \
    '```markdown' \
    '---' \
    'subtask: [ ] task/real-abc12345' \
    '---' \
    '```' \
    > "$file"

  _frontmatter__rename_subtask "$file" "task/real-abc12345" "task/renamed-abc12345"

  local content
  content="$(cat "$file")"
  assert_eq "frontmatter entry repointed" \
    "$(_frontmatter__parse_repeated_field "$content" subtask)" \
    "[ ] task/renamed-abc12345"
  assert_eq "body occurrence survives" \
    "$(printf '%s\n' "$content" | grep -c 'subtask: \[ \] task/real-abc12345' || true)" \
    "1"
}

test__frontmatter__rename_subtask__nonexistent_entry_is_noop() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/present-aaa11111"

  local before
  before="$(cat "$file")"
  local exit_code=0
  _frontmatter__rename_subtask "$file" "task/absent-zzz99999" "task/other-zzz99999" \
    || exit_code=$?
  assert_success "renaming a nonexistent entry returns 0" "$exit_code"
  assert_eq "file unchanged" "$(cat "$file")" "$before"
}

run_tests "tt lib/frontmatter (unit)"
