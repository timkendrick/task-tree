---
title: "Implementation Plan"
created: 2026-04-06T20:47:21Z
updated: 2026-04-06T20:47:21Z
---
# Plan: Standardize `--help` flag across commands

## Context

**Task:** Standardize `--help` flag across commands (`task/standardize-help-flag-53aa289f`)

**Current state:** 24 command entrypoint scripts each have a `usage()` function that:
- Outputs to stderr (`cat >&2 <<EOF`)
- Calls `exit 1`
- Some use `${SCRIPT_NAME}` (filename only), others use `${COMMAND_NAME}`
- `--help` handling is inconsistent: most call `usage` (exits 1, stderr), a few pass exit code 0

**Goal:** Standardize so that:
- `usage()` → outputs to stdout, does NOT exit
- `--help` → calls `usage`, exits 0 (stdout)
- Validation failure → calls `usage >&2`, exits 1 (stderr)
- Error messages (e.g. `Error: --slug is required`) are removed from validation failure paths — only usage is shown
- Use `${COMMAND_NAME:-$SCRIPT_NAME}` in usage headers for full command path
- Add `--help` test cases to each existing test file with harness helpers

## Decision Log

1. **usage() design**: No parameters, outputs to stdout via `cat <<EOF`, does not exit. Callers handle redirection and exit codes.
2. **Error messages on validation failure**: Drop individual error messages (e.g. `Error: --slug is required`). Only show usage on stderr.
3. **COMMAND_NAME**: Use `${COMMAND_NAME:-$SCRIPT_NAME}` so usage shows full path (e.g. `tt task create`). The dispatcher already sets `COMMAND_NAME`.
4. **Test approach**: Add `--help` test cases to each existing test file, with new harness assertion helpers.
5. **Dispatcher**: Keep existing `tt --help` handling in the dispatcher; subcommands handle their own `--help`.
6. **Scope**: Update all 24 command entrypoint scripts.

## User Q&A Transcript

1. Dispatcher handling: Keep dispatcher handling `tt --help`, subcommands handle their own `--help`
2. COMMAND_NAME: Use COMMAND_NAME when set (shows full path like `tt task create`)
3. Test approach: Add `--help` test cases to each existing test file, with test harness helpers
4. Validation errors: Only show usage on stderr, drop error messages

## Implementation

### Step 1: Update `usage()` convention in all 24 command scripts

**Target files** (all in `scripts/cli/`):
```
task/create, task/checkout, task/checkin, task/checkpoint, task/complete,
task/delete, task/edit, task/move, task/parent, task/propagate, task/publish,
task/rename, task/show, task/tree, task/current, task/prompt,
task/context/add, task/context/get, task/context/list, task/context/delete,
history/undo, workspace/init, workspace/list, workspace/switch,
worktree/show, worktree/delete
```

Wait — let me count. That's 26 scripts. Let me check `task/prompt` too:

Actually from the find output, there are these non-test executable scripts:
- task/checkin, task/checkout, task/checkpoint, task/complete, task/create, task/current
- task/delete, task/edit, task/move, task/parent, task/prompt, task/propagate
- task/publish, task/rename, task/show, task/tree
- task/context/add, task/context/delete, task/context/get, task/context/list
- history/undo
- workspace/init, workspace/list, workspace/switch
- worktree/delete, worktree/show

That's 26 scripts total.

**Changes per script:**

#### 1a. Update `usage()` function

**Before** (typical pattern):
```bash
usage() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} [options...]
...
EOF
  exit 1
}
```

**After:**
```bash
usage() {
  cat <<EOF
Usage: ${COMMAND_NAME:-$SCRIPT_NAME} [options...]
...
EOF
}
```

Key changes:
- Remove `>&2` from `cat` — output goes to stdout
- Remove `exit 1` — caller handles exit
- Replace `${SCRIPT_NAME}` with `${COMMAND_NAME:-$SCRIPT_NAME}` in Usage header

#### 1b. Update `--help` handler

**Before** (various patterns):
```bash
-h|--help) usage ;;
# or
-h|--help) usage 0 ;;
```

**After:**
```bash
-h|--help)
  usage
  exit 0
  ;;
```

#### 1c. Update error-path usage calls

**Before** (typical patterns):
```bash
[[ $# -lt 2 ]] && { log "Error: --repo requires an argument"; usage; }
# or
log "Error: Unknown option: $1"
usage
# or
log "Error: <task-id> is required"
usage
```

**After:**
```bash
[[ $# -lt 2 ]] && { usage >&2; exit 1; }
# or
usage >&2; exit 1
```

All error-path calls change to: `usage >&2; exit 1` — no error message, just usage to stderr + exit 1.

This includes:
- Missing argument errors (e.g. `--repo` without value) → `usage >&2; exit 1`
- Unknown option errors → `usage >&2; exit 1`
- Unexpected argument errors → `usage >&2; exit 1`
- Missing required arguments → `usage >&2; exit 1`
- Mutual exclusivity errors → `usage >&2; exit 1`
- Invalid combination errors → `usage >&2; exit 1`

#### Special cases

**`history/undo`** — has a usage function that takes an exit code param and branches on stdout/stderr:
```bash
# Before:
usage() {
  local exit_code="${1:-1}"
  if [[ "$exit_code" -eq 0 ]]; then
    cat <<EOF ...
  else
    cat >&2 <<EOF ...
  fi
  exit "$exit_code"
}
```
**After:** Same as all others — just `cat <<EOF`, no params, no exit.

**`workspace/init`** — same pattern as history/undo:
```bash
# Before: same parameterized pattern
# After: same as all others
```

**`tt` dispatcher** — already outputs its own help differently. The `usage()` function there is for the dispatcher itself. We need to update it to output to stdout by default, but the dispatcher's `--help` path already exits 0. The dispatcher's `usage` currently takes an exit_code param; simplify to stdout-only. The dispatcher's `show_namespace_help()` outputs to stderr; update to stdout for consistency, exit 0.

### Step 2: Update the `tt` dispatcher

**File:** `scripts/cli/tt`

Changes:
1. `usage()` → output to stdout, no exit
2. `show_namespace_help()` → output to stdout, exit 0
3. `--help` handler → `usage; exit 0`
4. Error paths (no command given) → `usage >&2; exit 1`

### Step 3: Add test harness helpers

**File:** `scripts/harness/harness.sh`

Add helpers for asserting `--help` behavior and named argument documentation:

```bash
# Assert that --help flag shows usage instructions on stdout with exit code 0.
# Usage: assert_help_output LABEL OUTPUT EXIT_CODE
assert_help_output() {
  local label="$1" output="$2" exit_code="$3"
  assert_success "$label (exit code)" "$exit_code"
  assert_output_not_empty "$label (has output)" "$output"
}

# Assert that a validation failure shows usage instructions on stderr with exit code 1.
# Usage: assert_usage_error LABEL OUTPUT EXIT_CODE
assert_usage_error() {
  local label="$1" output="$2" exit_code="$3"
  assert_failure "$label (exit code)" "$exit_code"
  assert_output_not_empty "$label (has output)" "$output"
}

# Assert that usage output starts with "Usage: <command-name>".
# Checks the first line begins with "Usage: " followed by the expected command name.
# Usage: assert_usage_command_name LABEL OUTPUT EXPECTED_COMMAND
assert_usage_command_name() {
  local label="$1" output="$2" expected="$3"
  local first_line
  first_line="$(printf '%s' "$output" | head -1)"
  local expected_prefix="Usage: ${expected}"
  # Check that first line starts with "Usage: <command-name>"
  if [[ "$first_line" == "${expected_prefix}"* ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected first line to start with '$expected_prefix', got: '$first_line'"
    _record_fail "$label: expected first line to start with '$expected_prefix', got: '$first_line'"
  fi
}

# Assert that usage output documents a named argument or option.
# Performs TWO checks:
#   1. The argument appears in the Usage: line (first line), surrounded by word boundaries.
#      e.g. for "--foo": Usage: my-command [--foo] → passes
#   2. The argument appears on its own indented line with exactly 2-space indent,
#      followed by at least one space and a description.
#      e.g. "  --foo    Human-readable description" → passes
# Usage: assert_usage_argument LABEL OUTPUT ARGUMENT
assert_usage_argument() {
  local label="$1" output="$2" argument="$3"
  local first_line
  first_line="$(printf '%s' "$output" | head -1)"

  # Check 1: argument appears in Usage line with word-boundary context
  # Use grep -E with word boundaries around the argument name.
  # For flags like --foo, the word boundary is naturally handled.
  local usage_has_arg=false
  if printf '%s' "$first_line" | grep -qE "(^|[^a-zA-Z0-9-])${argument}([^a-zA-Z0-9-]|$)"; then
    usage_has_arg=true
  fi
  if [[ "$usage_has_arg" == true ]]; then
    _log_pass "$label (in Usage line)"
    _record_pass
  else
    _log_fail "$label (in Usage line): argument '$argument' not found in Usage line: '$first_line'"
    _record_fail "$label (in Usage line): argument '$argument' not found in Usage line"
  fi

  # Check 2: argument appears on its own indented description line
  # Pattern: line starts with exactly 2 spaces, then the argument, then at least one space
  local detail_has_arg=false
  if printf '%s' "$output" | grep -qE "^  ${argument} "; then
    detail_has_arg=true
  fi
  if [[ "$detail_has_arg" == true ]]; then
    _log_pass "$label (documented)"
    _record_pass
  else
    _log_fail "$label (documented): no indented description line found for '$argument'"
    _record_fail "$label (documented): no indented description line found for '$argument'"
  fi
}
```

### Step 4: Add `--help` test cases to each test file

For each of the 26 test files, add a test that asserts:
1. `--help` exits 0 with usage on stdout
2. The usage shows the correct command name
3. The usage documents key named arguments/options

Example for `task/create`:

```bash
test_task_create__help() {
  output="" exit_code=0
  output=$(run_tt task create --help 2>&1) || exit_code=$?
  assert_help_output "shows help" "$output" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task create"
  assert_usage_argument "documents --title" "$output" "--title"
  assert_usage_argument "documents --slug" "$output" "--slug"
  assert_usage_argument "documents --parent" "$output" "--parent"
  assert_usage_argument "documents --project" "$output" "--project"
  assert_usage_argument "documents --repo" "$output" "--repo"
  assert_usage_argument "documents --force" "$output" "--force"
}
```

Example for `task/checkout`:

```bash
test_task_checkout__help() {
  output="" exit_code=0
  output=$(run_tt task checkout --help 2>&1) || exit_code=$?
  assert_help_output "shows help" "$output" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task checkout"
  assert_usage_argument "documents <task-id>" "$output" "<task-id>"
  assert_usage_argument "documents --worktree" "$output" "--worktree"
  assert_usage_argument "documents --force" "$output" "--force"
  assert_usage_argument "documents --repo" "$output" "--repo"
}
```

Example for `task/current` (simpler command):

```bash
test_task_current__help() {
  output="" exit_code=0
  output=$(run_tt task current --help 2>&1) || exit_code=$?
  assert_help_output "shows help" "$output" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task current"
  assert_usage_argument "documents --repo" "$output" "--repo"
}
```

Each test asserts the command name and the key arguments that the usage documents.
For commands that require positional arguments (e.g. `checkout` needs `<task-id>`),
also test that missing required arguments shows usage on stderr with exit 1.

### Step 5: Update bash-style.mdc

Update `.agents/rules/bash-style.mdc` to clarify the `usage()` convention — that it outputs to stdout, does not exit, and callers handle redirection and exit codes. (It already describes the desired behavior, but let's verify it matches our implementation.)

### Step 6: Update DESIGN.md

Add a section documenting the `--help` convention. Add to §5 (Commands) or create a new subsection.

### Step 7: Run tests

Run the full test suite to verify all changes are correct.

## Detailed Script Changes

### Scripts and their specific patterns

For each script, the changes follow the same template but the exact text differs. Here's the full list:

1. **task/create** — usage to stdout, all error `usage` calls get `>&2; exit 1`, remove `log "Error: ..."` before usage calls
2. **task/checkout** — same
3. **task/checkin** — same
4. **task/checkpoint** — same
5. **task/complete** — same
6. **task/current** — same
7. **task/delete** — same
8. **task/edit** — same
9. **task/move** — same
10. **task/parent** — same
11. **task/prompt** — need to read this file first
12. **task/propagate** — same
13. **task/publish** — same
14. **task/rename** — same
15. **task/show** — same
16. **task/tree** — same
17. **task/context/add** — same
18. **task/context/delete** — same
19. **task/context/get** — same
20. **task/context/list** — same
21. **history/undo** — simplify parameterized usage to plain stdout
22. **workspace/init** — simplify parameterized usage to plain stdout
23. **workspace/list** — same
24. **workspace/switch** — same
25. **worktree/delete** — same
26. **worktree/show** — same

## Task Checklist

- [ ] Step 1: Create new jj change for the work
- [ ] Step 2: Update `scripts/cli/tt` dispatcher
- [ ] Step 3: Update all 26 command entrypoint scripts
  - [ ] task/create
  - [ ] task/checkout
  - [ ] task/checkin
  - [ ] task/checkpoint
  - [ ] task/complete
  - [ ] task/current
  - [ ] task/delete
  - [ ] task/edit
  - [ ] task/move
  - [ ] task/parent
  - [ ] task/prompt
  - [ ] task/propagate
  - [ ] task/publish
  - [ ] task/rename
  - [ ] task/show
  - [ ] task/tree
  - [ ] task/context/add
  - [ ] task/context/delete
  - [ ] task/context/get
  - [ ] task/context/list
  - [ ] history/undo
  - [ ] workspace/init
  - [ ] workspace/list
  - [ ] workspace/switch
  - [ ] worktree/delete
  - [ ] worktree/show
- [ ] Step 4: Add test harness helpers to `harness.sh`
- [ ] Step 5: Add `--help` tests to each test file
- [ ] Step 6: Update `.agents/rules/bash-style.mdc`
- [ ] Step 7: Update `DESIGN.md` with `--help` convention
- [ ] Step 8: Run tests and fix any failures
- [ ] Step 9: Commit
