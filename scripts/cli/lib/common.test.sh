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

# ---------------------------------------------------------------------------
# get_jj_op_id — stale working copy
# ---------------------------------------------------------------------------

# Regression test: get_jj_op_id must pass --ignore-working-copy to jj so that
# it succeeds when the repo's default workspace has a stale working copy.
#
# A stale WC arises in multi-workspace setups where the canonical repo's
# default workspace has no recorded path (or its WC commit was rewritten from
# another workspace) and jj cannot auto-update it.  Without
# --ignore-working-copy, `jj op log` exits non-zero on such repos, causing
# tt_commit_transaction to fall back to after_op="unknown".
#
# We simulate the stale-WC condition with a mock jj shim: the shim exits 1
# (printing the canonical stale-WC error) unless --ignore-working-copy is
# present, in which case it prints a synthetic op ID and exits 0.  This
# exercises get_jj_op_id in isolation without requiring a real stale repo.
test_get_jj_op_id__passes_ignore_working_copy() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  # Create a mock jj shim that simulates the stale-WC failure
  local fake_jj="$dir/jj"
  cat > "$fake_jj" << 'FAKE_JJ'
#!/usr/bin/env bash
# Simulate a repo whose default workspace has a stale working copy.
# Succeed (printing a synthetic op ID) only when --ignore-working-copy is present.
for arg in "$@"; do
  if [[ "$arg" == "--ignore-working-copy" ]]; then
    printf 'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890\n'
    exit 0
  fi
done
printf 'Error: The working copy is stale (not updated since operation abcdef12).\n' >&2
printf 'Hint: Run `jj workspace update-stale` to update it.\n' >&2
exit 1
FAKE_JJ
  chmod +x "$fake_jj"

  # Prepend fake jj to PATH so get_jj_op_id calls it instead of the real jj.
  # The repo path must be an existing directory (get_jj_op_id cd's into it).
  local op_id
  op_id="$(PATH="$dir:$PATH" get_jj_op_id "$dir")" || true

  assert_neq "get_jj_op_id returns non-empty result" "$op_id" ""
  assert_not_contains "get_jj_op_id does not return \"unknown\"" "$op_id" "unknown"
}

run_tests "tt lib/common (unit)"
