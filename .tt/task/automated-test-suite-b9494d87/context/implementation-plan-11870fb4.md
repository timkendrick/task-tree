---
title: "Implementation plan"
created: 2026-03-29T16:12:46Z
updated: 2026-03-29T16:12:46Z
---
# Plan: Automated Test Suite

## Summary

Implement a reusable test harness (`scripts/test/harness.sh`) and comprehensive test suites for every command in the bootstrap CLI. A thin top-level runner (`scripts/test.sh`) will execute all test suites. Update `DESIGN.md` with a testing section.

## File Structure

```
scripts/
├── test.sh                           # Top-level runner (discovers and runs all *.test.sh)
├── test/
│   └── harness.sh                    # Reusable test harness (sourced by each test file)
├── cli/
│   ├── workspace/
│   │   ├── init.test.sh              # NEW: test suite for workspace init
│   │   ├── switch.test.sh            # NEW: test suite for workspace switch
│   │   ├── branch.test.sh            # NEW: test suite for workspace branch
│   │   └── worktree.test.sh          # NEW: test suite for workspace worktree
│   ├── task/
│   │   ├── create.test.sh            # NEW: test suite for task create
│   │   ├── checkout.test.sh          # NEW: test suite for task checkout
│   │   ├── checkpoint.test.sh        # NEW: test suite for task checkpoint
│   │   ├── complete.test.sh          # NEW: test suite for task complete
│   │   ├── checkin.test.sh           # NEW: test suite for task checkin
│   │   ├── edit.test.sh              # NEW: test suite for task edit
│   │   ├── delete.test.sh            # NEW: test suite for task delete
│   │   ├── rename.test.sh            # NEW: test suite for task rename
│   │   ├── move.test.sh              # NEW: test suite for task move
│   │   ├── propagate.test.sh         # NEW: test suite for task propagate
│   │   ├── publish.test.sh           # NEW: test suite for task publish
│   │   ├── tree.test.sh              # NEW: test suite for task tree
│   │   ├── show.test.sh              # NEW: test suite for task show
│   │   ├── current.test.sh           # NEW: test suite for task current
│   │   ├── parent.test.sh            # NEW: test suite for task parent
│   │   ├── prompt.test.sh            # NEW: test suite for task prompt
│   │   └── context/
│   │       ├── add.test.sh           # NEW: test suite for context add
│   │       ├── get.test.sh           # NEW: test suite for context get
│   │       ├── list.test.sh          # NEW: test suite for context list
│   │       └── delete.test.sh        # NEW: test suite for context delete
│   └── history/
│       └── undo.test.sh              # NEW: test suite for history undo
```

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Test location | `scripts/cli/<path>.test.sh` alongside command | Co-location with test subject for easy discovery |
| Harness location | `scripts/test/harness.sh` | Separate from CLI code, single file |
| Test structure | Flat scripts sourcing harness | Simple, no framework overhead |
| Runner | `scripts/test.sh` thin entrypoint | `find` for `*.test.sh`, non-zero exit on any failure |
| Scope | Harness + all command suites | Full coverage from the start |
| Existing tests | Follow-up migration tasks | Keeps this task focused |

## Questionnaire Transcript

- **Location:** Harness in `scripts/test`, test suites as `scripts/cli/*.test.sh` alongside corresponding test subject
- **Harness approach:** Single `harness.sh` sourced by each test file
- **Runner model:** Flat scripts that source harness.sh, run tests inline, call `harness_summary`
- **Top-level runner:** `scripts/test.sh` — thin entrypoint that executes all `*.test.sh` files
- **Scope:** Harness + all command suites
- **Existing tests:** Create follow-up tasks for migration
- **Assertion style:** Generic + VCS-specific + tt-specific assertions

---

## 1. Test Harness (`scripts/test/harness.sh`)

A single sourceable file providing:

### 1.1 Core Infrastructure

```bash
#!/usr/bin/env bash
# Test harness for tt bootstrap CLI
# Source this file from test scripts; do not execute directly.

# Guard against direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Error: harness.sh must be sourced, not executed directly." >&2
  exit 1
fi

# Resolve paths
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
TT="$REPO_ROOT/scripts/cli/tt"

# Global counters
_PASS_COUNT=0
_FAIL_COUNT=0
_SKIP_COUNT=0
declare -a _FAILURES=()

# Colors (respect NO_COLOR)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
  _RED='\033[0;31m'
  _GREEN='\033[0;32m'
  _YELLOW='\033[0;33m'
  _CYAN='\033[0;36m'
  _BOLD='\033[1m'
  _RESET='\033[0m'
else
  _RED='' _GREEN='' _YELLOW='' _CYAN='' _BOLD='' _RESET=''
fi
```

### 1.2 Test Lifecycle

```bash
# Per-test temp directory; cleaned up after each test
_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$_TEST_ROOT"' EXIT

# Per-test workspace vars (set by setup_workspace)
REPO=""
VIRTUAL=""

# Create a fresh jj repo + tt workspace for a test.
# Sets REPO, VIRTUAL, and TT_REPO (exported), changes CWD to REPO.
# TT_REPO is picked up by run_tt so tests need not pass --repo explicitly.
#
# Also writes workspace_dir into .tt/config.toml so that commands
# which call get_workspace_dir() (checkout --worktree, delete, switch, etc.)
# can resolve the virtual directory automatically.
#
# Usage: setup_workspace [name]
setup_workspace() {
  local name="${1:-test-$$-$RANDOM}"
  REPO="$_TEST_ROOT/$name/repo"
  VIRTUAL="$_TEST_ROOT/$name/virtual"
  mkdir -p "$REPO"

  jj git init "$REPO" >/dev/null 2>&1
  cd "$REPO"

  echo "initial" > README.md
  jj -R "$REPO" commit -m "Initial commit" >/dev/null 2>&1
  jj -R "$REPO" bookmark set main >/dev/null 2>&1

  "$TT" workspace init "$REPO" "$VIRTUAL" >/dev/null 2>&1

  # Append workspace_dir to config.toml so get_workspace_dir() works.
  # workspace init does NOT write this; we add it so tests for
  # --worktree, workspace switch, delete cleanup, etc. can function.
  printf '\n# Virtual project directory\nworkspace_dir = "%s"\n' "$VIRTUAL" \
    >> "$REPO/.tt/config.toml"

  # Commit the config update so it's tracked
  jj -R "$REPO" commit -m "Configure workspace_dir" >/dev/null 2>&1
  jj -R "$REPO" bookmark set main >/dev/null 2>&1

  # Export so run_tt forwards it as --repo to all tt commands
  export TT_REPO="$REPO"
}

# Create a secondary isolated workspace (for multi-workspace tests).
# Usage: setup_workspace_secondary NAME
# Sets REPO2, VIRTUAL2, exports TT_REPO2.
setup_workspace_secondary() {
  local name="${1:-secondary-$$-$RANDOM}"
  REPO2="$_TEST_ROOT/$name/repo"
  VIRTUAL2="$_TEST_ROOT/$name/virtual"
  mkdir -p "$REPO2"

  jj git init "$REPO2" >/dev/null 2>&1
  cd "$REPO2"

  echo "initial" > README.md
  jj -R "$REPO2" commit -m "Initial commit" >/dev/null 2>&1
  jj -R "$REPO2" bookmark set main >/dev/null 2>&1

  "$TT" workspace init "$REPO2" "$VIRTUAL2" >/dev/null 2>&1

  printf '\n# Virtual project directory\nworkspace_dir = "%s"\n' "$VIRTUAL2" \
    >> "$REPO2/.tt/config.toml"

  jj -R "$REPO2" commit -m "Configure workspace_dir" >/dev/null 2>&1
  jj -R "$REPO2" bookmark set main >/dev/null 2>&1

  export TT_REPO2="$REPO2"
  cd "$REPO"  # Return to primary workspace
}
```

### 1.3 tt Command Helper

```bash
# Run a tt command, with stdout and stderr captured separately.
# The TT_REPO env var (set by setup_workspace) is used as the implicit --repo flag.
# Callers can capture stdout and stderr independently:
#
#   local stdout stderr exit_code=0
#   stdout=$(run_tt task checkpoint -m "msg" 2>/tmp/stderr.txt) || exit_code=$?
#   stderr=$(cat /tmp/stderr.txt)
#
# For convenience, a simpler pattern captures both in one go:
#   local output
#   output=$(run_tt task checkpoint -m "msg" 2>&1) || true
#
# Usage: run_tt [args...]
run_tt() {
  TT_REPO="${TT_REPO:-${REPO:-}}" "$TT" "$@"
}

# Edit a working copy file (creates or overwrites), used to set up dirty WC state.
# Usage: edit_file PATH CONTENT
edit_file() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
}

# Append to a working copy file, used to create incremental changes.
# Usage: append_file PATH CONTENT
append_file() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >> "$path"
}
```

The `TT_REPO` environment variable is already supported by all commands via `resolve_repo()` in `scripts/cli/lib/common.sh`. The priority order is: `--repo` flag > `TT_REPO` env var > CWD walk-up. No dispatcher changes are needed. Setting `export TT_REPO="$REPO"` in `setup_workspace` is sufficient.

### 1.4 Workflow Convenience Helpers

Higher-level helpers that combine multiple tt commands for common setup patterns.
These return the created task/project ID on stdout, which callers capture.

```bash
# Create a project and return its ID on stdout.
# Usage: id=$(create_project SLUG TITLE [BODY])
create_project() {
  local slug="$1" title="$2" body="${3:-}"
  run_tt task create --project --slug "$slug" --title "$title" <<< "$body"
}

# Create a child task under the current branch and return its ID on stdout.
# Usage: id=$(create_task SLUG TITLE [BODY])
create_task() {
  local slug="$1" title="$2" body="${3:-}"
  run_tt task create --slug "$slug" --title "$title" <<< "$body"
}

# Create a child task under a specific parent and return its ID on stdout.
# Usage: id=$(create_task_under PARENT_ID SLUG TITLE [BODY])
create_task_under() {
  local parent="$1" slug="$2" title="$3" body="${4:-}"
  run_tt task create --parent "$parent" --slug "$slug" --title "$title" <<< "$body"
}

# Checkout a task (switches WC to it, sets status to IN-PROGRESS if TODO).
# Usage: checkout_task TASK_ID
checkout_task() {
  run_tt task checkout "$1" 2>&1
}

# Checkpoint the current task with a message.
# Usage: checkpoint_task MESSAGE
checkpoint_task() {
  run_tt task checkpoint -m "$1" 2>&1
}

# Complete the current task (or a specific task).
# Usage: complete_task [TASK_ID]
complete_task() {
  if [[ $# -gt 0 ]]; then
    run_tt task complete "$1" 2>&1
  else
    run_tt task complete 2>&1
  fi
}

# Checkin the current task (or a specific task) to its parent.
# Usage: checkin_task [TASK_ID] [EXTRA_ARGS...]
checkin_task() {
  run_tt task checkin "$@" 2>&1
}

# Capture the task ID from the last line of stdout (tt task create prints it).
# Usage: TASK_ID=$(last_line "$output")
last_line() {
  printf '%s' "$1" | tail -1
}
```

### 1.5 VCS Introspection Helpers

```bash
# Get the current jj operation ID.
get_jj_op() {
  jj -R "$REPO" op log --no-graph -T id -n 1 2>/dev/null
}

# Get the current working-copy revision's change ID.
# Using change_id (not commit_id) because change IDs survive rebases.
get_wc_change_id() {
  jj -R "$REPO" log -r '@' --no-graph -T 'change_id.short(8)' 2>/dev/null
}

# Get the current working-copy revision's commit ID (short).
get_wc_commit() {
  jj -R "$REPO" log -r '@' --no-graph -T 'commit_id.short(8)' 2>/dev/null
}

# Get the commit that a bookmark points to (short commit ID).
# Usage: get_bookmark_commit BOOKMARK
get_bookmark_commit() {
  jj -R "$REPO" log -r "$1" --no-graph -T 'commit_id.short(8)' 2>/dev/null
}

# Get the full commit ID for a revision.
# Usage: get_full_commit_id REV
get_full_commit_id() {
  jj -R "$REPO" log -r "$1" --no-graph -T 'commit_id' 2>/dev/null
}

# Get the commit message for a revision.
# Usage: get_commit_message REV
get_commit_message() {
  jj -R "$REPO" log -r "$1" --no-graph -T 'description' 2>/dev/null
}

# Get the first line of the commit message for a revision.
# Usage: get_commit_message_first_line REV
get_commit_message_first_line() {
  jj -R "$REPO" log -r "$1" --no-graph -T 'description.first_line()' 2>/dev/null
}

# Get the list of files modified in a commit.
# Usage: get_modified_files REV
get_modified_files() {
  jj -R "$REPO" diff -r "$1" --name-only 2>/dev/null
}

# List all files tracked at a revision.
# Usage: get_file_list REV
get_file_list() {
  jj -R "$REPO" file list -r "$1" 2>/dev/null
}

# Check if working copy is clean (empty diff, no pending changes).
is_wc_clean() {
  local result
  result="$(jj -R "$REPO" log -r '@' --no-graph -T 'empty' 2>/dev/null)"
  [[ "$result" == "true" ]]
}

# Check if a given revision has an empty diff (no file changes), regardless of description.
# Usage: is_diff_empty REV
is_diff_empty() {
  local rev="$1"
  local diff_output
  diff_output="$(jj -R "$REPO" diff -r "$rev" --name-only 2>/dev/null)"
  [[ -z "$diff_output" ]]
}

# Read a file from a specific revision.
# Usage: read_file_at_rev REV PATH
read_file_at_rev() {
  jj -R "$REPO" file show -r "$1" -- "$2" 2>/dev/null
}

# Check if a bookmark exists.
# Usage: bookmark_exists BOOKMARK
bookmark_exists() {
  jj -R "$REPO" log -r "$1" --no-graph -T '' >/dev/null 2>&1
}

# Check if ANCESTOR is an ancestor of DESCENDANT in the VCS DAG.
# Usage: is_vcs_ancestor ANCESTOR DESCENDANT
is_vcs_ancestor() {
  local ancestor="$1" descendant="$2"
  jj -R "$REPO" log -r "${ancestor}::${descendant}" --no-graph -T '' >/dev/null 2>&1
}

# Get the list of bookmarks at a given revision.
# Usage: get_bookmarks_at REV
get_bookmarks_at() {
  jj -R "$REPO" log -r "$1" --no-graph \
    -T 'bookmarks.map(|b| b.name()).join("\n")' 2>/dev/null
}

# Get all task/project bookmarks in the repo.
# Usage: get_all_task_bookmarks
get_all_task_bookmarks() {
  jj -R "$REPO" log -r 'bookmarks()' \
    -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' \
    --no-graph 2>/dev/null | grep -E '^(task|project)/' | sort -u
}

# Count the number of commits in a revset.
# Usage: count_commits REVSET
count_commits() {
  jj -R "$REPO" log -r "$1" --no-graph -T '"x\n"' 2>/dev/null | wc -l | tr -d ' '
}

# Check if a revset contains any conflicts.
# Usage: has_conflicts REVSET
has_conflicts() {
  local result
  result="$(jj -R "$REPO" log -r "$1" --no-graph \
    -T 'if(conflict, "yes\n")' 2>/dev/null)" || true
  [[ -n "$result" ]]
}

# Check if a file exists at a specific revision.
# Usage: file_exists_at_rev REV PATH
file_exists_at_rev() {
  jj -R "$REPO" file show -r "$1" -- "$2" >/dev/null 2>&1
}

# Check if a symlink exists in the working copy and where it points.
# Usage: get_symlink_target PATH
get_symlink_target() {
  readlink "$1" 2>/dev/null
}
```

### 1.6 Generic Assertion Helpers

All assertions take a LABEL as the first argument for diagnostic output:

```bash
# Log helpers
_log_pass() { printf '%b  ✓ %s%b\n' "$_GREEN" "$1" "$_RESET" >&2; }
_log_fail() { printf '%b  ✗ %s%b\n' "$_RED" "$1" "$_RESET" >&2; }
_log_skip() { printf '%b  ⊘ %s%b\n' "$_YELLOW" "$1" "$_RESET" >&2; }
_log_section() {
  printf '\n%b── %s%b\n' "$_BOLD" "$1" "$_RESET" >&2
}

# assert_eq LABEL ACTUAL EXPECTED
assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: expected '$expected', got '$actual'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: expected '$expected', got '$actual'")
  fi
}

# assert_neq LABEL ACTUAL UNEXPECTED
assert_neq() {
  local label="$1" actual="$2" unexpected="$3"
  if [[ "$actual" != "$unexpected" ]]; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: expected value to differ from '$unexpected'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: expected value to differ from '$unexpected'")
  fi
}

# assert_contains LABEL HAYSTACK NEEDLE
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: expected to contain '$needle'"
    printf '    Actual: %s\n' "$haystack" >&2
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: expected to contain '$needle'")
  fi
}

# assert_not_contains LABEL HAYSTACK NEEDLE
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! printf '%s' "$haystack" | grep -qF "$needle"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: expected NOT to contain '$needle'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: expected NOT to contain '$needle'")
  fi
}

# assert_matches LABEL STRING PATTERN
# PATTERN is an extended regex (ERE) passed directly to grep -E.
# Special syntax for common tt patterns:
#   %TASK_SLUG%   matches a task ID with given slug and any 8-hex suffix:
#                 e.g. %my-task% matches "task/my-task-abc12345"
#   %PROJ_SLUG%   same but for projects:
#                 e.g. %my-proj% matches "project/my-proj-abc12345"
# These are expanded to ERE patterns before matching.
# Examples:
#   assert_matches "task created" "$output" "task/%my-task%"
#   assert_matches "project created" "$output" "project/%my-proj%"
#   assert_matches "checkpoint msg" "$msg" "Checkpoint: .+ \(task/"
assert_matches() {
  local label="$1" string="$2" pattern="$3"
  # Expand shorthand patterns
  local ere_pattern
  ere_pattern="$(printf '%s' "$pattern" | sed 's/%[^%]*%/[a-z0-9-]+-[0-9a-f]{8}/g')"
  if printf '%s' "$string" | grep -qE "$ere_pattern"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: expected to match pattern '$pattern' (ERE: '$ere_pattern')"
    printf '    Actual: %s\n' "$string" >&2
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: expected to match '$pattern'")
  fi
}

# assert_not_matches LABEL STRING PATTERN
# Like assert_matches but asserts the pattern does NOT match.
assert_not_matches() {
  local label="$1" string="$2" pattern="$3"
  local ere_pattern
  ere_pattern="$(printf '%s' "$pattern" | sed 's/%[^%]*%/[a-z0-9-]+-[0-9a-f]{8}/g')"
  if ! printf '%s' "$string" | grep -qE "$ere_pattern"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: expected NOT to match pattern '$pattern'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: expected NOT to match '$pattern'")
  fi
}

# assert_file_exists LABEL PATH
assert_file_exists() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: file not found: $path"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: file not found: $path")
  fi
}

# assert_file_not_exists LABEL PATH
assert_file_not_exists() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: file should not exist: $path"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: file should not exist: $path")
  fi
}

# assert_symlink LABEL PATH EXPECTED_TARGET
# Asserts that PATH is a symlink pointing to EXPECTED_TARGET.
assert_symlink() {
  local label="$1" path="$2" expected="$3"
  if [[ -L "$path" ]]; then
    local actual
    actual="$(readlink "$path")"
    assert_eq "$label" "$actual" "$expected"
  else
    _log_fail "$label: not a symlink: $path"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: not a symlink: $path")
  fi
}

# assert_exit_code LABEL EXPECTED ACTUAL
assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  assert_eq "$label (exit code)" "$actual" "$expected"
}

# assert_success LABEL EXIT_CODE
# Asserts that EXIT_CODE is 0.
assert_success() {
  local label="$1" exit_code="$2"
  assert_eq "$label (should succeed)" "$exit_code" "0"
}

# assert_failure LABEL EXIT_CODE
# Asserts that EXIT_CODE is non-zero.
assert_failure() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" != "0" ]]; then
    _log_pass "$label (exit code $exit_code)"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: expected non-zero exit code, got 0"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: expected non-zero exit code, got 0")
  fi
}

# assert_output_empty LABEL OUTPUT
assert_output_empty() {
  local label="$1" output="$2"
  if [[ -z "$output" ]]; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: expected empty output, got: $output"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: expected empty output")
  fi
}

# assert_output_not_empty LABEL OUTPUT
assert_output_not_empty() {
  local label="$1" output="$2"
  if [[ -n "$output" ]]; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: expected non-empty output"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: expected non-empty output")
  fi
}

# assert_line_count LABEL OUTPUT EXPECTED_COUNT
# Asserts that OUTPUT has exactly EXPECTED_COUNT non-empty lines.
assert_line_count() {
  local label="$1" output="$2" expected="$3"
  local actual
  actual="$(printf '%s' "$output" | grep -c . 2>/dev/null || true)"
  assert_eq "$label (line count)" "$actual" "$expected"
}
```

### 1.7 VCS-Specific Assertion Helpers

```bash
# assert_commit_empty LABEL REV
# Asserts that a commit has an empty diff (no file changes).
assert_commit_empty() {
  local label="$1" rev="$2"
  if is_diff_empty "$rev"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: commit '$rev' is not empty (has file changes)"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: commit '$rev' is not empty")
  fi
}

# assert_commit_not_empty LABEL REV
assert_commit_not_empty() {
  local label="$1" rev="$2"
  if ! is_diff_empty "$rev"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: commit '$rev' should not be empty"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: commit '$rev' should be non-empty")
  fi
}

# assert_bookmark_exists LABEL BOOKMARK
assert_bookmark_exists() {
  local label="$1" bookmark="$2"
  if bookmark_exists "$bookmark"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: bookmark '$bookmark' does not exist"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: bookmark '$bookmark' does not exist")
  fi
}

# assert_bookmark_not_exists LABEL BOOKMARK
assert_bookmark_not_exists() {
  local label="$1" bookmark="$2"
  if ! bookmark_exists "$bookmark"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: bookmark '$bookmark' should not exist"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: bookmark '$bookmark' should not exist")
  fi
}

# assert_wc_clean LABEL
assert_wc_clean() {
  local label="$1"
  if is_wc_clean; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: working copy is not clean"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: working copy is not clean")
  fi
}

# assert_wc_dirty LABEL
assert_wc_dirty() {
  local label="$1"
  if ! is_wc_clean; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: working copy should be dirty"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: working copy should be dirty")
  fi
}

# assert_commit_message LABEL REV EXPECTED_SUBSTRING
assert_commit_message() {
  local label="$1" rev="$2" expected="$3"
  local msg
  msg="$(get_commit_message "$rev")"
  assert_contains "$label" "$msg" "$expected"
}

# assert_commit_message_first_line LABEL REV EXPECTED
# Exact match on the first line of a commit message.
assert_commit_message_first_line() {
  local label="$1" rev="$2" expected="$3"
  local actual
  actual="$(get_commit_message_first_line "$rev")"
  assert_eq "$label" "$actual" "$expected"
}

# assert_file_on_branch LABEL BRANCH PATH
# Verifies that a file exists on the given branch/revision.
assert_file_on_branch() {
  local label="$1" branch="$2" path="$3"
  if file_exists_at_rev "$branch" "$path"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: file '$path' not found on branch '$branch'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: file '$path' not found on branch '$branch'")
  fi
}

# assert_file_not_on_branch LABEL BRANCH PATH
assert_file_not_on_branch() {
  local label="$1" branch="$2" path="$3"
  if ! file_exists_at_rev "$branch" "$path"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: file '$path' should not exist on branch '$branch'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: file '$path' should not exist on branch '$branch'")
  fi
}

# assert_file_content_at_rev LABEL REV PATH EXPECTED_CONTENT
# Asserts that the file at REV:PATH contains EXPECTED_CONTENT (substring match).
assert_file_content_at_rev() {
  local label="$1" rev="$2" path="$3" expected="$4"
  local actual
  actual="$(read_file_at_rev "$rev" "$path")" || {
    _log_fail "$label: could not read $path at $rev"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read $path at $rev")
    return
  }
  assert_contains "$label" "$actual" "$expected"
}

# assert_no_conflicts LABEL [REVSET]
# Asserts that no commits in the given revset (default: all commits reachable
# from any bookmark) have conflicts.
assert_no_conflicts() {
  local label="$1" revset="${2:-bookmarks()}"
  local conflicted
  conflicted="$(jj -R "$REPO" log -r "$revset" --no-graph \
    -T 'if(conflict, commit_id.short(8) ++ " " ++ description.first_line() ++ "\n")' \
    2>/dev/null)" || true
  if [[ -z "$conflicted" ]]; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: conflicting commits found:"
    printf '%s\n' "$conflicted" | while IFS= read -r line; do
      printf '    %s\n' "$line" >&2
    done
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: conflicting commits found")
  fi
}

# assert_is_ancestor LABEL ANCESTOR_REV DESCENDANT_REV
# Asserts that ANCESTOR_REV is an ancestor of (or equal to) DESCENDANT_REV.
assert_is_ancestor() {
  local label="$1" ancestor="$2" descendant="$3"
  if is_vcs_ancestor "$ancestor" "$descendant"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: '$ancestor' is not an ancestor of '$descendant'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: '$ancestor' is not an ancestor of '$descendant'")
  fi
}

# assert_not_ancestor LABEL ANCESTOR_REV DESCENDANT_REV
assert_not_ancestor() {
  local label="$1" ancestor="$2" descendant="$3"
  if ! is_vcs_ancestor "$ancestor" "$descendant"; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: '$ancestor' should not be an ancestor of '$descendant'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: '$ancestor' should not be an ancestor of '$descendant'")
  fi
}

# assert_revset_count LABEL REVSET EXPECTED_COUNT
# Asserts that the number of commits matching REVSET is EXPECTED_COUNT.
assert_revset_count() {
  local label="$1" revset="$2" expected="$3"
  local actual
  actual="$(count_commits "$revset")"
  assert_eq "$label" "$actual" "$expected"
}
```

### 1.8 tt-Specific Assertion Helpers

#### Task file helpers

```bash
# read_task_file TASK_ID [REV]
# Read the TASK.md for a given task ID from its branch (default) or from REV.
# Outputs the raw file content.
# Usage:
#   content=$(read_task_file "task/my-task-abc12345")
#   content=$(read_task_file "task/my-task-abc12345" "project/my-proj-abc12345")
read_task_file() {
  local task_id="$1" rev="${2:-$1}"
  local suffix="${task_id#*/}"
  jj -R "$REPO" file show -r "$rev" -- ".tt/task/$suffix/TASK.md" 2>/dev/null
}

# get_frontmatter_field CONTENT FIELD
# Extract a single-value frontmatter field (e.g. title, status).
# Returns the field value (without the "field: " prefix).
get_frontmatter_field() {
  local content="$1" field="$2"
  printf '%s' "$content" | sed -n "s/^${field}: *//p" | head -1
}

# get_frontmatter_field_all CONTENT FIELD
# Extract all values for a repeatable frontmatter field (e.g. label, subtask, context).
# Each value is output on a separate line.
get_frontmatter_field_all() {
  local content="$1" field="$2"
  printf '%s' "$content" | sed -n "s/^${field}: *//p"
}

# get_task_body CONTENT
# Extract the body (everything after the second ---).
get_task_body() {
  local content="$1"
  printf '%s' "$content" | awk '/^---$/{n++; if(n==2){found=1; next}} found{print}'
}
```

#### Status / frontmatter assertions

```bash
# assert_task_status LABEL TASK_ID EXPECTED_STATUS [REV]
# Reads the task file from the task's own branch (or REV) and checks the status field.
assert_task_status() {
  local label="$1" task_id="$2" expected="$3" rev="${4:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for '$task_id'")
    return
  }
  actual="$(get_frontmatter_field "$content" "status")"
  assert_eq "$label" "$actual" "$expected"
}

# assert_task_title LABEL TASK_ID EXPECTED_TITLE [REV]
# Reads the task file from the task's branch (or REV) and checks the title field.
assert_task_title() {
  local label="$1" task_id="$2" expected="$3" rev="${4:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for '$task_id'")
    return
  }
  # Title may be quoted: strip surrounding double-quotes if present
  actual="$(get_frontmatter_field "$content" "title" | sed 's/^"//;s/"$//')"
  assert_eq "$label" "$actual" "$expected"
}

# assert_task_label LABEL TASK_ID EXPECTED_LABEL [REV]
# Checks that the task file contains at least one label: entry with EXPECTED_LABEL.
assert_task_label() {
  local label="$1" task_id="$2" expected="$3" rev="${4:-$task_id}"
  local content labels
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for '$task_id'")
    return
  }
  labels="$(get_frontmatter_field_all "$content" "label")"
  assert_contains "$label" "$labels" "$expected"
}

# assert_task_no_label LABEL TASK_ID UNEXPECTED_LABEL [REV]
# Checks that the task file does NOT contain a label: entry with UNEXPECTED_LABEL.
assert_task_no_label() {
  local label="$1" task_id="$2" unexpected="$3" rev="${4:-$task_id}"
  local content labels
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for '$task_id'")
    return
  }
  labels="$(get_frontmatter_field_all "$content" "label")"
  assert_not_contains "$label" "$labels" "$unexpected"
}

# assert_task_body_contains LABEL TASK_ID NEEDLE [REV]
# Checks that the task body contains NEEDLE.
assert_task_body_contains() {
  local label="$1" task_id="$2" needle="$3" rev="${4:-$task_id}"
  local content body
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for '$task_id'")
    return
  }
  body="$(get_task_body "$content")"
  assert_contains "$label" "$body" "$needle"
}

# assert_frontmatter_field LABEL TASK_ID FIELD EXPECTED_VALUE [REV]
# Generic: asserts that the given frontmatter FIELD equals EXPECTED_VALUE.
assert_frontmatter_field() {
  local label="$1" task_id="$2" field="$3" expected="$4" rev="${5:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for '$task_id'")
    return
  }
  actual="$(get_frontmatter_field "$content" "$field")"
  assert_eq "$label" "$actual" "$expected"
}

# assert_frontmatter_field_count LABEL TASK_ID FIELD EXPECTED_COUNT [REV]
# Asserts the number of occurrences of a repeatable frontmatter field.
assert_frontmatter_field_count() {
  local label="$1" task_id="$2" field="$3" expected="$4" rev="${5:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for '$task_id'")
    return
  }
  actual="$(get_frontmatter_field_all "$content" "$field" | grep -c . 2>/dev/null || true)"
  assert_eq "$label" "$actual" "$expected"
}
```

#### Subtask entry assertions

```bash
# assert_subtask_entry LABEL PARENT_ID CHILD_ID EXPECTED_CHECKBOX [REV]
# Checks that the parent's task file contains a subtask entry for the child
# with the expected checkbox state: "[ ]", "[-]", or "[x]".
assert_subtask_entry() {
  local label="$1" parent_id="$2" child_id="$3" expected_checkbox="$4" rev="${5:-$parent_id}"
  local content
  content="$(read_task_file "$parent_id" "$rev")" || {
    _log_fail "$label: could not read task file for parent '$parent_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for parent '$parent_id'")
    return
  }
  local expected_line="subtask: ${expected_checkbox} ${child_id}"
  assert_contains "$label" "$content" "$expected_line"
}

# assert_no_subtask_entry LABEL PARENT_ID CHILD_ID [REV]
# Asserts that the parent's task file does NOT contain any subtask entry for CHILD_ID.
assert_no_subtask_entry() {
  local label="$1" parent_id="$2" child_id="$3" rev="${4:-$parent_id}"
  local content
  content="$(read_task_file "$parent_id" "$rev")" || {
    _log_fail "$label: could not read task file for parent '$parent_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for parent '$parent_id'")
    return
  }
  # Check that no subtask: line references CHILD_ID
  if printf '%s' "$content" | grep -qF "subtask: " && \
     printf '%s' "$content" | grep "subtask: " | grep -qF "$child_id"; then
    _log_fail "$label: parent '$parent_id' still has a subtask entry for '$child_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: parent still has subtask entry for '$child_id'")
  else
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  fi
}

# assert_subtask_count LABEL PARENT_ID EXPECTED_COUNT [REV]
# Asserts the number of subtask entries in a task's frontmatter.
assert_subtask_count() {
  local label="$1" parent_id="$2" expected="$3" rev="${4:-$parent_id}"
  assert_frontmatter_field_count "$label" "$parent_id" "subtask" "$expected" "$rev"
}
```

#### Context assertions

```bash
# assert_context_entry LABEL TASK_ID CTX_ID [REV]
# Asserts that the task's frontmatter has a context: entry for CTX_ID.
assert_context_entry() {
  local label="$1" task_id="$2" ctx_id="$3" rev="${4:-$task_id}"
  local content
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for '$task_id'")
    return
  }
  assert_contains "$label" "$content" "context: $ctx_id"
}

# assert_no_context_entry LABEL TASK_ID CTX_ID [REV]
assert_no_context_entry() {
  local label="$1" task_id="$2" ctx_id="$3" rev="${4:-$task_id}"
  local content
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: could not read task file for '$task_id'")
    return
  }
  assert_not_contains "$label" "$content" "context: $ctx_id"
}

# assert_context_file_exists LABEL TASK_ID CTX_ID [REV]
# Asserts that the context file exists at the expected path on the branch.
assert_context_file_exists() {
  local label="$1" task_id="$2" ctx_id="$3" rev="${4:-$task_id}"
  local suffix="${task_id#*/}"
  local ctx_path=".tt/task/$suffix/${ctx_id}.md"
  assert_file_on_branch "$label" "$rev" "$ctx_path"
}

# assert_context_file_not_exists LABEL TASK_ID CTX_ID [REV]
assert_context_file_not_exists() {
  local label="$1" task_id="$2" ctx_id="$3" rev="${4:-$task_id}"
  local suffix="${task_id#*/}"
  local ctx_path=".tt/task/$suffix/${ctx_id}.md"
  assert_file_not_on_branch "$label" "$rev" "$ctx_path"
}

# assert_context_count LABEL TASK_ID EXPECTED_COUNT [REV]
# Asserts the number of context entries in a task's frontmatter.
assert_context_count() {
  local label="$1" task_id="$2" expected="$3" rev="${4:-$task_id}"
  assert_frontmatter_field_count "$label" "$task_id" "context" "$expected" "$rev"
}
```

#### Current task / misc assertions

```bash
# assert_current_task LABEL EXPECTED_TASK_ID
# Checks the current WC branch is the expected task ID by reading the jj branch
# directly (not by invoking tt task current).
assert_current_task() {
  local label="$1" expected="$2"
  local actual
  actual="$(jj -R "$REPO" log -r 'heads(ancestors(@) & bookmarks())' -n 1 --no-graph \
    -T 'local_bookmarks.map(|b| b.name()).join(",")' 2>/dev/null)" || true
  # Take first if comma-separated
  actual="${actual%%,*}"
  assert_eq "$label" "$actual" "$expected"
}

# assert_current_task_matches LABEL EXPECTED_ERE_PATTERN
# Like assert_current_task but accepts an ERE pattern (supports %SLUG%).
assert_current_task_matches() {
  local label="$1" pattern="$2"
  local actual
  actual="$(jj -R "$REPO" log -r 'heads(ancestors(@) & bookmarks())' -n 1 --no-graph \
    -T 'local_bookmarks.map(|b| b.name()).join(",")' 2>/dev/null)" || true
  actual="${actual%%,*}"
  assert_matches "$label" "$actual" "$pattern"
}

# assert_on_main LABEL
# Asserts that the current WC is on the 'main' branch (or a descendant of it
# with main as the closest ancestor bookmark).
assert_on_main() {
  local label="$1"
  local actual
  actual="$(jj -R "$REPO" log -r 'heads(ancestors(@) & bookmarks())' -n 1 --no-graph \
    -T 'local_bookmarks.map(|b| b.name()).join(",")' 2>/dev/null)" || true
  actual="${actual%%,*}"
  assert_eq "$label" "$actual" "main"
}
```

#### Transaction history assertions

```bash
# get_history_lines
# Read all lines from .tt/history into the HISTORY_LINES array.
get_history_lines() {
  HISTORY_LINES=()
  local hf="$REPO/.tt/history"
  if [[ -f "$hf" && -s "$hf" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && HISTORY_LINES+=("$line")
    done < "$hf"
  fi
}

# history_before_op LINE  — extract the before-op-id from a history line
history_before_op() { printf '%s' "${1%%:*}"; }

# history_after_op LINE   — extract the after-op-id from a history line
history_after_op()  { printf '%s' "${1#*:}"; }

# assert_history_count LABEL EXPECTED_COUNT
assert_history_count() {
  local label="$1" expected="$2"
  get_history_lines
  assert_eq "$label" "${#HISTORY_LINES[@]}" "$expected"
}

# assert_history_integrity LABEL
# Asserts:
#   1. No in-progress entry (every after-op-id is non-empty).
#   2. History chain is unbroken: entry[i].after == entry[i+1].before for all i.
#   3. The last after-op-id matches the current jj operation ID.
assert_history_integrity() {
  local label="$1"
  get_history_lines
  local count="${#HISTORY_LINES[@]}"

  if [[ $count -eq 0 ]]; then
    _log_pass "$label (empty history)"
    ((_PASS_COUNT++)) || true
    return
  fi

  # Check for in-progress entry
  local i
  for ((i=0; i<count; i++)); do
    local after
    after="$(history_after_op "${HISTORY_LINES[$i]}")"
    if [[ -z "$after" ]]; then
      _log_fail "$label: in-progress transaction at entry $i (empty after-op)"
      ((_FAIL_COUNT++)) || true
      _FAILURES+=("$label: in-progress transaction at entry $i")
      return
    fi
  done

  # Check chain continuity
  for ((i=0; i<count-1; i++)); do
    local this_after next_before
    this_after="$(history_after_op "${HISTORY_LINES[$i]}")"
    next_before="$(history_before_op "${HISTORY_LINES[$((i+1))]}")"
    if [[ "$this_after" != "$next_before" ]]; then
      _log_fail "$label: history chain broken at entry $i: after ($this_after) != next before ($next_before)"
      ((_FAIL_COUNT++)) || true
      _FAILURES+=("$label: history chain broken at entry $i")
      return
    fi
  done

  # Check last after-op matches current jj op
  local last_after current_op
  last_after="$(history_after_op "${HISTORY_LINES[$((count-1))]}")"
  current_op="$(get_jj_op)"
  if [[ "$last_after" != "$current_op" ]]; then
    _log_fail "$label: last after-op (${last_after:0:12}) != current jj op (${current_op:0:12})"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: history out of sync with jj")
    return
  fi

  _log_pass "$label"
  ((_PASS_COUNT++)) || true
}

# assert_no_pending_transaction LABEL
# Asserts that .tt/history does not end with an in-progress (incomplete) entry.
assert_no_pending_transaction() {
  local label="$1"
  get_history_lines
  local count="${#HISTORY_LINES[@]}"
  if [[ $count -eq 0 ]]; then
    _log_pass "$label (empty history)"
    ((_PASS_COUNT++)) || true
    return
  fi
  local last_after
  last_after="$(history_after_op "${HISTORY_LINES[$((count-1))]}")"
  if [[ -z "$last_after" ]]; then
    _log_fail "$label: last history entry is in-progress (no after-op-id)"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: dangling in-progress transaction")
  else
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  fi
}
```

#### `.tt` workspace integrity assertions

```bash
# dump_task_structure
# Print a human-readable tree of all bookmarks and their task files to stderr.
# Useful for debugging failing tests. Not an assertion — does not affect pass/fail counts.
dump_task_structure() {
  printf '\n%b── Task structure dump ──%b\n' "$_CYAN" "$_RESET" >&2
  jj -R "$REPO" bookmark list --no-pager 2>/dev/null | awk '{print $1}' | while IFS= read -r bm; do
    [[ "$bm" == task/* || "$bm" == project/* ]] || continue
    local suffix="${bm#*/}"
    printf '  %s\n' "$bm" >&2
    local content
    content="$(jj -R "$REPO" file show -r "$bm" -- ".tt/task/$suffix/TASK.md" 2>/dev/null)" || continue
    local status title
    status="$(printf '%s' "$content" | sed -n 's/^status: *//p' | head -1)"
    title="$(printf '%s' "$content" | sed -n 's/^title: *//p' | head -1 | sed 's/^"//;s/"$//')"
    printf '    title: %s\n    status: %s\n' "$title" "$status" >&2
    printf '%s' "$content" | grep '^subtask: ' | while IFS= read -r st; do
      printf '    %s\n' "$st" >&2
    done
    printf '%s' "$content" | grep '^context: ' | while IFS= read -r ctx; do
      printf '    %s\n' "$ctx" >&2
    done
  done
  printf '\n' >&2
}

# assert_tt_workspace_integrity LABEL
# Comprehensive structural integrity check of the .tt workspace state.
# Verifies (using VCS state only, not tt commands):
#   1. Every task/project bookmark has a corresponding .tt/task/<slug-hex>/TASK.md
#      on its own branch.
#   2. Every subtask: reference in a task file points to a bookmark that exists.
#   3. Every context: reference in a task file has a corresponding context file
#      on the same branch.
#   4. No in-progress transaction in .tt/history.
assert_tt_workspace_integrity() {
  local label="$1"
  local errors=0

  # Collect all task/project bookmarks
  local -a bookmarks=()
  while IFS= read -r bm; do
    [[ "$bm" == task/* || "$bm" == project/* ]] && bookmarks+=("$bm")
  done < <(jj -R "$REPO" bookmark list --no-pager 2>/dev/null | awk '{print $1}')

  for bm in "${bookmarks[@]}"; do
    local suffix="${bm#*/}"
    local task_file=".tt/task/$suffix/TASK.md"

    # Check 1: task file exists on own branch
    if ! file_exists_at_rev "$bm" "$task_file"; then
      printf '%b    ✗ %s: task file missing on own branch: %s%b\n' \
        "$_RED" "$label" "$task_file" "$_RESET" >&2
      ((errors++)) || true
      continue
    fi

    local content
    content="$(jj -R "$REPO" file show -r "$bm" -- "$task_file" 2>/dev/null)"

    # Check 2: every subtask: reference is a valid bookmark
    while IFS= read -r st_line; do
      # st_line is like "[ ] task/foo-abc12345" or "[x] task/foo-abc12345"
      local child_id="${st_line##*] }"
      if ! bookmark_exists "$child_id"; then
        printf '%b    ✗ %s: subtask reference to non-existent bookmark: %s (on %s)%b\n' \
          "$_RED" "$label" "$child_id" "$bm" "$_RESET" >&2
        ((errors++)) || true
      fi
    done < <(printf '%s' "$content" | grep '^subtask: ' | sed 's/^subtask: //')

    # Check 3: every context: reference has a corresponding file
    while IFS= read -r ctx_id; do
      local ctx_file=".tt/task/$suffix/${ctx_id}.md"
      if ! file_exists_at_rev "$bm" "$ctx_file"; then
        printf '%b    ✗ %s: context reference to missing file: %s (on %s)%b\n' \
          "$_RED" "$label" "$ctx_file" "$bm" "$_RESET" >&2
        ((errors++)) || true
      fi
    done < <(printf '%s' "$content" | grep '^context: ' | sed 's/^context: //')

  done

  # Check 4: no in-progress transaction
  get_history_lines
  local hcount="${#HISTORY_LINES[@]}"
  if [[ $hcount -gt 0 ]]; then
    local last_after
    last_after="$(history_after_op "${HISTORY_LINES[$((hcount-1))]}")"
    if [[ -z "$last_after" ]]; then
      printf '%b    ✗ %s: in-progress transaction in .tt/history%b\n' \
        "$_RED" "$label" "$_RESET" >&2
      ((errors++)) || true
    fi
  fi

  if [[ $errors -eq 0 ]]; then
    _log_pass "$label"
    ((_PASS_COUNT++)) || true
  else
    _log_fail "$label: $errors workspace integrity error(s)"
    ((_FAIL_COUNT++)) || true
    _FAILURES+=("$label: $errors workspace integrity error(s)")
  fi
}
```

### 1.9 Summary and Exit

```bash
# Print test summary and exit with appropriate code.
# Usage: harness_summary
harness_summary() {
  printf '\n%b══════════════════════════════════════════════════════════════%b\n' "$_CYAN" "$_RESET" >&2
  printf '%b  Results: %d passed, %d failed, %d skipped%b\n' \
    "$_BOLD" "$_PASS_COUNT" "$_FAIL_COUNT" "$_SKIP_COUNT" "$_RESET" >&2
  if [[ ${#_FAILURES[@]} -gt 0 ]]; then
    printf '\n%b  Failures:%b\n' "$_RED" "$_RESET" >&2
    for f in "${_FAILURES[@]}"; do
      printf '%b    • %s%b\n' "$_RED" "$f" "$_RESET" >&2
    done
  fi
  printf '%b══════════════════════════════════════════════════════════════%b\n' "$_CYAN" "$_RESET" >&2

  [[ $_FAIL_COUNT -eq 0 ]]
}

# Skip a test with a reason.
# Usage: skip_test LABEL REASON
skip_test() {
  _log_skip "$1: $2"
  ((_SKIP_COUNT++)) || true
}
```

---

## 2. Top-Level Runner (`scripts/test.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

# scripts/test.sh — Run all tt test suites
#
# Discovers all *.test.sh files under scripts/cli/ and runs each one.
# Exits with non-zero if any suite fails.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '%s\n' "$*" >&2; }

usage() {
  cat <<EOF
Usage: ${0##*/} [--help] [filter...]

Run tt test suites.

Arguments:
  filter    Optional glob patterns to filter which test files to run.
            Matched against the file path relative to scripts/cli/.
            Examples: "task/checkpoint" "workspace/*"

Options:
  --help    Show this help message.

EOF
  exit 0
}

main() {
  local -a filters=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage ;;
      *) filters+=("$1"); shift ;;
    esac
  done

  local -a test_files=()
  while IFS= read -r f; do
    if [[ ${#filters[@]} -eq 0 ]]; then
      test_files+=("$f")
    else
      local rel="${f#"$SCRIPT_DIR"/cli/}"
      for pattern in "${filters[@]}"; do
        if [[ "$rel" == *"$pattern"* ]]; then
          test_files+=("$f")
          break
        fi
      done
    fi
  done < <(find "$SCRIPT_DIR/cli" -name '*.test.sh' -type f | sort)

  if [[ ${#test_files[@]} -eq 0 ]]; then
    log "No test files found."
    exit 1
  fi

  log "Running ${#test_files[@]} test suite(s)..."
  log ""

  local failed=0
  for test_file in "${test_files[@]}"; do
    local rel="${test_file#"$SCRIPT_DIR"/}"
    log "━━━ $rel ━━━"
    if bash "$test_file"; then
      log ""
    else
      log ""
      ((failed++)) || true
    fi
  done

  if [[ $failed -gt 0 ]]; then
    log "$failed suite(s) failed."
    exit 1
  fi

  log "All suites passed."
}

main "$@"
```

---

## 3. Test Suite: `workspace init` (`scripts/cli/workspace/init.test.sh`)

### 3.1 Basic initialization

Creates a jj repo, runs `workspace init`. Asserts:
- `.tt/config.toml` exists and contains `task_prefix = "task/"` and `project_prefix = "project/"`
- `.tt/.gitignore` exists and contains `/history`
- `.tt/history` file exists (may be empty)
- Virtual directory exists
- `HEAD` symlink in virtual dir points to repo root
- "Create workspace" commit was created
- WC is clean after init

### 3.2 Custom prefixes

`workspace init --task-prefix "t/" --project-prefix "p/"`. Asserts:
- Config contains `task_prefix = "t/"` and `project_prefix = "p/"`

### 3.3 Same prefix rejected

`workspace init --task-prefix "x/" --project-prefix "x/"`. Asserts:
- Non-zero exit code
- Error message about prefixes being identical

### 3.4 Non-jj directory rejected

Point at a non-jj directory. Asserts:
- Non-zero exit code, error message

### 3.5 Dirty working copy rejected

Make a dirty WC, then init. Asserts:
- Non-zero exit, error about uncommitted changes

### 3.6 Non-empty virtual dir without --force rejected

Create a virtual dir with contents. Asserts:
- Non-zero exit unless `--force` is used
- With `--force`, succeeds

### 3.7 Existing .tt file (not directory) without --force rejected

Create a `.tt` regular file. Asserts:
- Non-zero exit
- With `--force`, the file is removed and init succeeds

### 3.8 Idempotent re-init with --force

Run init twice (second time with `--force`). Asserts:
- Second init succeeds and config is updated

---

## 4. Test Suite: `workspace switch` (`scripts/cli/workspace/switch.test.sh`)

### 4.1 Basic switch between worktrees

Create project → checkout with --worktree → create second task → checkout with --worktree → switch to first.
Asserts:
- HEAD symlink updated to first task's worktree
- Hooks would fire (verify via log output containing "Switching to")

### 4.2 Switch with no worktree for task fails

Try to switch to a task that has no dedicated worktree. Asserts:
- Non-zero exit, error about no worktree found

### 4.3 Invalid task ID rejected

`workspace switch not-a-task-id`. Asserts:
- Non-zero exit, error about unrecognized ID

### 4.4 Non-existent bookmark rejected

`workspace switch task/nonexistent-00000000`. Asserts:
- Non-zero exit

### 4.5 Dirty outgoing workspace rejected

Make outgoing worktree dirty. Asserts:
- Non-zero exit without `--force`
- Succeeds with `--force`

---

## 5. Test Suite: `workspace branch` (`scripts/cli/workspace/branch.test.sh`)

### 5.1 Valid task ID

Create a task, run `workspace branch <task-id>`. Asserts:
- Stdout is the task ID
- Exit code 0

### 5.2 Non-existent bookmark

`workspace branch task/nonexistent-00000000`. Asserts:
- Non-zero exit

### 5.3 Invalid format

`workspace branch not-a-task`. Asserts:
- Non-zero exit, error about unrecognized ID

---

## 6. Test Suite: `workspace worktree` (`scripts/cli/workspace/worktree.test.sh`)

### 6.1 No dedicated worktree — falls back to repo

Create a task (no --worktree). Run `workspace worktree <task-id>`. Asserts:
- Stdout is the repo root path

### 6.2 With dedicated worktree

Create a task with `--checkout --worktree`. Run `workspace worktree <task-id>`. Asserts:
- Stdout is the worktree path

### 6.3 Non-existent bookmark

`workspace worktree task/nonexistent-00000000`. Asserts:
- Non-zero exit

---

## 7. Test Suite: `task create` (`scripts/cli/task/create.test.sh`)

### 7.1 Create task under project

Create a project, checkout, create a child task. Asserts:
- Child bookmark exists
- Parent has `subtask: [ ] <child-id>` entry
- Child task file exists on child branch with `status: TODO`
- Child task file has correct title (quoted in frontmatter)
- Child branch forked from parent (parent is VCS ancestor of child)
- WC returned to parent branch (not on child)
- Stdout is the new task ID

### 7.2 Create project

`tt task create --project --slug proj --title "My project"`. Asserts:
- Bookmark `project/proj-<hex>` exists
- Task file on project branch has `status: TODO`, correct title
- No parent subtask entries anywhere

### 7.3 Create project with --target

`tt task create --project --target main --slug proj --title "Proj"`. Asserts:
- Project branch forked from `main`
- `main` is a VCS ancestor of the project

### 7.4 Create with --checkout

Create a task with `--checkout`. Asserts:
- WC is on the new task branch
- Task status is `IN-PROGRESS` (checkout transitions TODO → IN-PROGRESS)
- `TASK.md` symlink exists in worktree root pointing to `.tt/task/<slug>/TASK.md`

### 7.5 Create with --checkout --worktree

Create a task with `--checkout --worktree`. Asserts:
- A new jj workspace directory was created
- WC in that workspace is on the new task branch

### 7.6 Create with custom slug

Provide `--slug my-custom-slug`. Asserts:
- Task ID matches `task/my-custom-slug-[0-9a-f]{8}`

### 7.7 Create with labels

`--label bug --label urgent`. Asserts:
- Task file has `label: bug` and `label: urgent` in frontmatter

### 7.8 Create with body from stdin

`echo "Task description" | tt task create --slug x --title X`. Asserts:
- Task body contains "Task description"

### 7.9 Create fails on completed parent

Complete a parent task, then try to create a child. Asserts:
- Non-zero exit
- Error message about DONE status

### 7.10 Create with --force overwrites existing bookmark

Create a task, then create again with same slug + `--force`. Asserts:
- No error, bookmark updated

### 7.11 Create records single transaction

After create, check `.tt/history`. Asserts:
- Exactly one new entry for the create operation
- History integrity holds

### 7.12 Create with --propagate

Create two children, second with `--propagate`. Asserts:
- First child's base is updated to include the parent commit from the second child's creation
- Parent is a VCS ancestor of both children

### 7.13 Mutually exclusive flags

`--project --parent task/x-00000000` together. Asserts:
- Non-zero exit, error about mutual exclusivity

### 7.14 --target without --project rejected

`--target main` without `--project`. Asserts:
- Non-zero exit

### 7.15 Invalid slug rejected

`--slug "UPPERCASE"`, `--slug "--leading-hyphen"`, etc. Asserts:
- Non-zero exit, slug validation error

### 7.16 WC position preserved when not using --checkout

Create a task without --checkout while on parent. Asserts:
- After create, WC is back on parent branch (not stranded)

---

## 8. Test Suite: `task checkout` (`scripts/cli/task/checkout.test.sh`)

### 8.1 Basic checkout of TODO task

Create task (TODO), then checkout. Asserts:
- Status transitions from `TODO` to `IN-PROGRESS`
- `TASK.md` symlink created in worktree root
- "Begin task" commit message present
- Bookmark advanced to include the "Begin task" commit
- WC is a fresh empty change on top of the bookmark

### 8.2 Checkout of IN-PROGRESS task (no Begin commit)

Checkout a task that's already IN-PROGRESS (checkout a second time). Asserts:
- No second "Begin task" commit
- WC positioned on top of task branch

### 8.3 Checkout with dirty WC rejected

Make WC dirty, try checkout. Asserts:
- Non-zero exit
- Error about uncommitted changes

### 8.4 Checkout with dirty WC + --force

Make WC dirty, checkout with `--force`. Asserts:
- Succeeds with warning

### 8.5 Checkout invalid task ID rejected

`tt task checkout not-a-task`. Asserts:
- Non-zero exit

### 8.6 Checkout non-existent bookmark rejected

`tt task checkout task/nonexistent-00000000`. Asserts:
- Non-zero exit

### 8.7 Checkout with --worktree creates workspace

`tt task checkout <id> --worktree`. Asserts:
- New workspace directory created at `<workspace_dir>/<task-id>`
- jj workspace exists for it

### 8.8 Checkout with --worktree reuses existing workspace

Checkout with --worktree, then checkout something else, then checkout first task again with --worktree.
Asserts:
- Reuses existing workspace directory, no error

### 8.9 Checkout with --worktree + --switch updates HEAD

`tt task checkout <id> --worktree --switch`. Asserts:
- HEAD symlink updated to new worktree

### 8.10 Checkout records transaction

Asserts:
- `.tt/history` has a new entry
- History integrity holds

---

## 9. Test Suite: `task checkpoint` (`scripts/cli/task/checkpoint.test.sh`)

### 9.1 Basic checkpoint with message

Create a project, checkout, create a task, checkout, checkpoint with `-m`. Asserts:
- Commit message format: `Checkpoint: <msg> (<bookmark>)`
- Bookmark advanced to the new commit (`@-`)
- WC is clean (fresh empty change on top)
- Exit code 0

### 9.2 Checkpoint with pending file changes

Edit a working copy file, then checkpoint. Asserts:
- File is committed (visible in `@-` diff)
- Bookmark advances
- WC clean after

### 9.3 Checkpoint on empty WC

No pending changes. Asserts:
- Commit is still created (empty checkpoint)
- Bookmark advances

### 9.4 Checkpoint not on task branch fails

Switch to `main` (or a non-task branch). Run checkpoint. Asserts:
- Non-zero exit
- Error message about "not on a task or project branch"

### 9.5 Checkpoint records transaction history

Verify `.tt/history` entry is written correctly. Asserts:
- Before-op differs from after-op
- Entry format is `<before>:<after>` (no empty after)

### 9.6 Multiple sequential checkpoints

Two checkpoints back-to-back. Asserts:
- Bookmark advances twice
- Both commit messages correct
- History has two entries
- History chain is unbroken

### 9.7 Checkpoint on project branch

Create a project, checkout, checkpoint on the project. Asserts:
- Works (projects are valid targets for checkpoint)
- Message includes project bookmark name

---

## 10. Test Suite: `task complete` (`scripts/cli/task/complete.test.sh`)

### 10.1 Complete current task

Create task, checkout, complete. Asserts:
- Status changes to `DONE`
- Commit message contains "Complete task: <title>"
- Bookmark advanced
- WC clean

### 10.2 Complete explicit task ID (cross-branch)

Create task, checkout, go back to parent, `complete <task-id>`. Asserts:
- Status changes to `DONE` on task's branch
- WC returns to where it was (parent branch)

### 10.3 Complete already-DONE task is no-op

Complete a task that is already DONE. Asserts:
- Exit code 0
- "already DONE" message
- No new commits

### 10.4 Complete with incomplete subtasks fails

Create parent + 2 children, complete only one child. Try to complete parent. Asserts:
- Non-zero exit
- Error about incomplete subtasks

### 10.5 Complete with incomplete subtasks + --force

Same setup, but use `--force`. Asserts:
- Succeeds despite incomplete subtasks
- Status is DONE

### 10.6 Complete with dirty WC rejected

Make WC dirty, try to complete. Asserts:
- Non-zero exit

### 10.7 Complete records transaction

Check `.tt/history` after complete. Asserts:
- One new entry, history integrity holds

---

## 11. Test Suite: `task checkin` (`scripts/cli/task/checkin.test.sh`)

### 11.1 Basic checkin of completed task

Create project → task, checkout task, make changes, checkpoint, complete, checkin. Asserts:
- Parent bookmark has a merge commit ("Merge subtask: <title>")
- Parent's subtask entry updated to `[x]` (status DONE → checkbox [x])
- TASK.md symlink in parent worktree points to parent's task file
- WC on parent branch after checkin
- No conflicts

### 11.2 Partial checkin (task still IN-PROGRESS)

Create task, checkout, checkpoint, checkin (without complete). Asserts:
- Parent's subtask entry updated to `[-]` (status IN-PROGRESS → checkbox [-])
- Merge commit created on parent
- "Partial checkin complete" message

### 11.3 Checkin with --complete

`checkin --complete`. Asserts:
- Task status becomes DONE before merge
- Parent subtask checkbox is `[x]`

### 11.4 Checkin with --context

`checkin --context "Handoff notes here"`. Asserts:
- A context file created on the parent with title "Handoff: <task-title>"
- Parent's frontmatter has a `context:` entry
- Context file body contains "Handoff notes here"

### 11.5 Checkin with --delete

`checkin --complete --delete`. Asserts:
- Task bookmark deleted after checkin
- Task directory removed from parent branch
- Subtask entry removed from parent frontmatter

### 11.6 Checkin of project branch rejected

Try to checkin a project branch. Asserts:
- Non-zero exit
- Error about using `tt task publish` instead

### 11.7 Checkin with dirty WC rejected

Asserts:
- Non-zero exit without checkpoint first

### 11.8 Checkin with --rebase

`checkin --rebase`. Asserts:
- Propagation happened before checkin (parent rebased into child)
- No conflicts on merge

### 11.9 Checkin with --merge

`checkin --merge`. Asserts:
- Merge strategy used

### 11.10 Checkin with --propagate

`checkin --propagate`. Asserts:
- After checkin, sibling tasks are rebased/merged onto updated parent

### 11.11 Bookmark up-to-date check (implicit current)

Make commits without checkpointing (bookmark behind WC), then checkin implicitly. Asserts:
- Non-zero exit, error about running `tt task checkpoint` first

### 11.12 Bypass bookmark check with explicit task ID

Same situation but pass task ID explicitly. Asserts:
- Succeeds (explicit ID bypasses the check)

### 11.13 Unmerged range validation

Create a task, modify a sibling's task file on the child branch, try checkin. Asserts:
- Non-zero exit, error about unexpected task file modifications

### 11.14 Checkin records single transaction

Check `.tt/history`. Asserts:
- One new entry for entire checkin (including --complete, --propagate sub-ops)
- History integrity holds

### 11.15 Checkin with no parent found fails

Create a parentless task, try to checkin. Asserts:
- Non-zero exit, error about no parent branch

---

## 12. Test Suite: `task edit` (`scripts/cli/task/edit.test.sh`)

### 12.1 Edit title

`tt task edit --title "New title"`. Asserts:
- Task file title updated
- Commit message "Edit task: New title (<bookmark>)"
- `updated` timestamp changed

### 12.2 Edit body from stdin

`echo "New body" | tt task edit`. Asserts:
- Task body replaced with "New body"

### 12.3 Add label

`tt task edit --label new-label`. Asserts:
- `label: new-label` added to frontmatter
- Existing labels preserved

### 12.4 Delete label

`tt task edit --delete-label existing-label`. Asserts:
- Label removed
- Other labels preserved

### 12.5 Edit preserves subtask and context entries

Edit title on a task that has subtasks and contexts. Asserts:
- All `subtask:` entries preserved
- All `context:` entries preserved
- Only title and updated timestamp changed

### 12.6 Cross-branch edit (explicit task ID, not current)

Edit a different task than the current branch. Asserts:
- Target task file updated
- WC returned to original position
- Current branch unmodified

### 12.7 No-op edit (no changes)

Edit with identical title, no new labels, no body change. Asserts:
- "No changes" message
- No new commits created

### 12.8 Edit with dirty WC rejected

Make WC dirty, try to edit. Asserts:
- Non-zero exit

### 12.9 Edit records transaction

Check `.tt/history`. Asserts:
- One new entry (unless no-op), history integrity holds

---

## 13. Test Suite: `task delete` (`scripts/cli/task/delete.test.sh`)

### 13.1 Delete completed task

Create project → task, checkout, complete, checkin, delete. Asserts:
- Task bookmark deleted
- Task directory removed from parent branch
- Subtask entry removed from parent frontmatter
- "Remove subtask:" commit on parent branch

### 13.2 Delete task with descendants

Create project → parent task → child task → grandchild. Complete all, delete parent task. Asserts:
- All descendant bookmarks deleted (child, grandchild)
- All descendant task directories removed from parent

### 13.3 Delete non-DONE task fails

Try to delete an IN-PROGRESS task. Asserts:
- Non-zero exit, error about status
- With `--force`, succeeds

### 13.4 Delete with dirty WC fails

Make WC dirty, try delete. Asserts:
- Non-zero exit without `--force`
- With `--force`, succeeds

### 13.5 Delete parentless task fails

Try to delete a project (parentless). Asserts:
- Non-zero exit, error about parentless tasks

### 13.6 Delete records transaction

Check `.tt/history` after delete. Asserts:
- One entry, history integrity holds

---

## 14. Test Suite: `task rename` (`scripts/cli/task/rename.test.sh`)

### 14.1 Basic rename

Create task with slug `old-name`, rename to `new-name`. Asserts:
- Old bookmark `task/old-name-<hex>` deleted
- New bookmark `task/new-name-<hex>` exists (same hex suffix)
- Task file directory renamed: `.tt/task/new-name-<hex>/TASK.md` exists
- Old directory `.tt/task/old-name-<hex>/` gone
- Parent's subtask entry updated from old ID to new ID
- "Task renamed: old → new" output

### 14.2 Same slug is no-op

Rename to the same slug. Asserts:
- Exit code 0
- No new commits

### 14.3 Conflicting slug rejected

Create two tasks, try to rename one to the other's slug+hex. Asserts:
- Non-zero exit, error about existing bookmark

### 14.4 Invalid slug rejected

`--slug "UPPERCASE"`. Asserts:
- Non-zero exit, validation error

### 14.5 Dirty WC rejected

Make WC dirty, try rename. Asserts:
- Non-zero exit

### 14.6 Rename preserves task file content

After rename, task title, body, labels, subtasks all preserved. Asserts:
- All frontmatter fields identical before and after (except paths)

### 14.7 Rename updates TASK.md symlink

If a TASK.md symlink exists pointing to old path, it should point to new path after rename. Asserts:
- Symlink target updated

### 14.8 Rename records transaction

Check `.tt/history`. Asserts:
- One entry, history integrity holds

### 14.9 Rename task with commits in unmerged range

Create task, checkout, make several checkpoints, then rename. Asserts:
- All commits in the unmerged range rewritten (old dir removed, new dir present)
- No conflicts after rename
- Bookmark at new name points to equivalent commit

---

## 15. Test Suite: `task move` (`scripts/cli/task/move.test.sh`)

### 15.1 Basic reparenting

Create project, two tasks (A, B). Move B from project to under A. Asserts:
- Old parent (project) no longer has subtask entry for B
- New parent (A) has subtask entry `[ ] B`
- B's unmerged range rebased onto A
- B is a VCS descendant of A

### 15.2 Cycle detection

Create A → B (A is parent of B). Try to move A under B. Asserts:
- Non-zero exit, error about cycle

### 15.3 Move to same parent is error

Move a task to its current parent. Asserts:
- Non-zero exit, error about already a child

### 15.4 Parentless task cannot be moved

Try to move a project (no parent). Asserts:
- Non-zero exit

### 15.5 Dirty WC rejected

Make WC dirty, try move. Asserts:
- Non-zero exit

### 15.6 Move preserves WC position

If WC is on a third branch (not the moved task or its parents), position preserved. Asserts:
- After move, WC still on same branch

### 15.7 Move when WC is on old parent

WC is on old parent. After move, WC should be on updated old parent tip. Asserts:
- WC on old parent (with subtask entry removed)

### 15.8 Move when WC is on moved task

WC is on the task being moved. After move, WC follows the rebase. Asserts:
- WC lands wherever rebase puts it

### 15.9 Move records transaction

Check `.tt/history`. Asserts:
- One entry, history integrity holds

### 15.10 No conflicts after reparent

After move, verify no conflicts across all bookmarks. Asserts:
- `assert_no_conflicts`

---

## 16. Test Suite: `task propagate` (`scripts/cli/task/propagate.test.sh`)

### 16.1 Rebase descendants (default)

Create project → parent → two children. Make a change on parent (via checkpoint). Propagate. Asserts:
- Both children rebased onto parent's new tip
- Parent is VCS ancestor of both children
- No conflicts

### 16.2 Merge strategy

Same setup, but `--merge`. Asserts:
- Merge commits created on children (each child has 2 parents)

### 16.3 --shallow (direct children only)

Create project → parent → child → grandchild. Change parent, propagate --shallow. Asserts:
- Child updated
- Grandchild NOT updated (still behind)

### 16.4 Recursive propagation (default, not shallow)

Same setup without --shallow. Asserts:
- Both child and grandchild updated

### 16.5 --to filter

Create parent → 3 children. Change parent, propagate --to child2. Asserts:
- Only child2 updated; child1 and child3 unchanged

### 16.6 Already up-to-date children skipped

Create parent → child. Propagate without any parent changes. Asserts:
- "already up to date" message
- No new commits

### 16.7 Partially checked-in child gets resume commit

Create parent → child, checkin child (partial, still IN-PROGRESS), propagate from parent. Asserts:
- Child gets a resume commit on top of parent
- "creating resume commit" message

### 16.8 --dry-run

Propagate with `--dry-run`. Asserts:
- "[dry-run]" messages
- No actual changes made
- No transaction recorded

### 16.9 Conflicts detected without --force

Create a conflict scenario. Propagate without --force. Asserts:
- Non-zero exit, error about conflicts

### 16.10 Conflicts proceed with --force

Same scenario with `--force`. Asserts:
- Succeeds despite conflicts

### 16.11 Propagate records transaction

Check `.tt/history`. Asserts:
- One entry (not one per child), history integrity holds

### 16.12 WC restored after propagate

After propagate, WC should be where it was before. Asserts:
- WC position unchanged

---

## 17. Test Suite: `task publish` (`scripts/cli/task/publish.test.sh`)

### 17.1 Basic publish to target

Create project, make changes, `publish --target main`. Asserts:
- `main` bookmark advanced (merge commit)
- Merge commit message "Merge subtask: <title>"
- `.tt/task/` directory NOT present on `main` (scaffolding removed)
- `TASK.md` symlink NOT present on `main`
- No conflicts

### 17.2 Publish non-project branch rejected

Try to publish a task branch (not a project). Asserts:
- Non-zero exit, error about using `tt task checkin`

### 17.3 Publish without --target rejected

`publish` without `--target`. Asserts:
- Non-zero exit, error about --target required

### 17.4 Publish with --rebase

`publish --target main --rebase`. Asserts:
- Propagation from target into project happened before publishing

### 17.5 Publish with --merge

`publish --target main --merge`. Asserts:
- Merge strategy used

### 17.6 Publish with dirty WC rejected

Make WC dirty, try publish. Asserts:
- Non-zero exit

### 17.7 Non-existent target rejected

`publish --target nonexistent`. Asserts:
- Non-zero exit

### 17.8 WC stays on project after publish

After publish, WC should still be on the project branch (not switched to target). Asserts:
- Current branch is still the project

### 17.9 Publish records transaction

Check `.tt/history`. Asserts:
- One entry, history integrity holds

---

## 18. Test Suite: `task tree` (`scripts/cli/task/tree.test.sh`)

### 18.1 Basic tree output

Create a project with 2 tasks (one with a subtask). Run `tt task tree`. Asserts:
- Output is valid markdown with nested bullet points
- Project appears at top level
- Tasks indented under project
- Subtask indented under task
- Checkboxes reflect status: `[ ]` for TODO, `[-]` for IN-PROGRESS, `[x]` for DONE

### 18.2 --focus shows current chain only

Create deep hierarchy: project → A → B → C. Checkout C. Run `tree --focus`. Asserts:
- Output shows project → A → B → C
- Siblings of A, B not shown
- Current task (C) is bold-formatted

### 18.3 --project filter

Create 2 projects. Run `tree --project <proj1>`. Asserts:
- Only proj1's tree shown

### 18.4 --all includes detached

Create a task not under any project (orphan). Run `tree --all`. Asserts:
- "Orphaned tasks:" section present with the orphan

### 18.5 --detached adds orphan section

Run `tree --detached`. Asserts:
- Projects shown + orphaned section

### 18.6 Completed subtask with [x] checkbox

Complete and checkin a subtask. Run tree. Asserts:
- Subtask shows `[x]` checkbox

### 18.7 Empty project (no subtasks)

Create a project with no children. Run tree. Asserts:
- Project listed with no children (just the project line)

### 18.8 --focus with no current branch fails

Go to main (non-task branch). Run `tree --focus`. Asserts:
- Non-zero exit

---

## 19. Test Suite: `task show` (`scripts/cli/task/show.test.sh`)

### 19.1 Show current task

Create and checkout a task with title, body, labels. Run `tt task show`. Asserts:
- Output contains task ID, title, status
- Output contains body text
- Labels shown
- Parent shown

### 19.2 Show explicit task ID

`tt task show <task-id>`. Asserts:
- Shows the requested task (not current)

### 19.3 Show task with subtasks

Create task with children. Run show. Asserts:
- "Subtasks:" section lists children with checkboxes and titles

### 19.4 Show task with context

Add context to a task. Run show. Asserts:
- "Context:" section lists context with title

### 19.5 Show with --expand-context

Add context, run `show --expand-context`. Asserts:
- Context file content expanded inline

### 19.6 Show completed (checked-in) task

Complete and checkin a task. Run `show <task-id>`. Asserts:
- Shows from parent branch (where to read rule)
- Status shows DONE

### 19.7 Show task with no subtasks

Run show on task with no children. Asserts:
- "[No subtasks]" message

### 19.8 Show task with no context

Run show on task with no context. Asserts:
- "[No context files]" message

### 19.9 Show with no body

Create task with empty body. Run show. Asserts:
- "[No description]" message

### 19.10 Not on task branch fails (no arg)

Go to main, run `show` with no arg. Asserts:
- Non-zero exit

---

## 20. Test Suite: `task current` (`scripts/cli/task/current.test.sh`)

### 20.1 On a task branch

Checkout a task, run `tt task current`. Asserts:
- Stdout is the task ID
- Exit code 0

### 20.2 On a project branch

Checkout a project, run `tt task current`. Asserts:
- Stdout is the project ID

### 20.3 Not on a task/project branch

Go to main. Run `tt task current`. Asserts:
- Non-zero exit, error message

---

## 21. Test Suite: `task parent` (`scripts/cli/task/parent.test.sh`)

### 21.1 Parent of a task

Create project → task. Run `tt task parent <task-id>`. Asserts:
- Stdout is the project ID

### 21.2 Parent of current task (implicit)

Checkout task, run `tt task parent` (no args). Asserts:
- Stdout is the parent ID

### 21.3 Parent of project (no parent)

Run `tt task parent <project-id>`. Asserts:
- Non-zero exit, "No parent found"

### 21.4 --project finds nearest ancestor project

Create project → task A → task B. Run `parent --project <task-B-id>`. Asserts:
- Stdout is the project ID (walks up past A)

### 21.5 --project when already a project

Run `parent --project <project-id>`. Asserts:
- Non-zero exit (project has no ancestor project)

---

## 22. Test Suite: `task prompt` (`scripts/cli/task/prompt.test.sh`)

### 22.1 Basic prompt output

Create and checkout a task with title, body, and context. Run `tt task prompt`. Asserts:
- Output starts with "Implement task: <title>"
- Contains frontmatter block with task ID
- Body text present
- Context blocks present with their content
- Commands section with `tt task tree --focus`, `tt task current`, `tt task parent`

### 22.2 Prompt with --message

`tt task prompt --message "Extra instructions"`. Asserts:
- Extra message section appended at the end

### 22.3 Prompt for explicit task ID

`tt task prompt <task-id>`. Asserts:
- Shows prompt for specified task, not current

### 22.4 Prompt with no context

Create task with no context files. Run prompt. Asserts:
- No context blocks in output
- Commands section still present

### 22.5 Not on task branch fails (no arg)

Go to main, run `prompt` with no arg. Asserts:
- Non-zero exit

---

## 23. Test Suite: `task context add` (`scripts/cli/task/context/add.test.sh`)

### 23.1 Add context from stdin

`echo "Context body" | tt task context add --title "My context" --slug "my-ctx"`. Asserts:
- Context file created at `.tt/task/<slug>/context/my-ctx-<hex>.md`
- Context file has frontmatter with title, created, updated timestamps
- Context file body is "Context body"
- Task file has `context: context/my-ctx-<hex>` entry
- Commit message "Add context: My context (<bookmark>)"
- Context ID printed to stdout

### 23.2 Add context to explicit task ID

`echo "Body" | tt task context add --title "Ctx" --slug ctx <task-id>`. Asserts:
- Context added to the specified task, not current

### 23.3 Empty body rejected

`echo "" | tt task context add --title "Ctx" --slug ctx`. Asserts:
- Non-zero exit, error about empty body

### 23.4 Dirty WC rejected

Make WC dirty, try to add context. Asserts:
- Non-zero exit

### 23.5 Multiple contexts on same task

Add two contexts. Asserts:
- Both context entries in frontmatter
- Both context files exist
- `updated` timestamp refreshed on task file

### 23.6 Context add records transaction

Check `.tt/history`. Asserts:
- One entry, history integrity holds

---

## 24. Test Suite: `task context get` (`scripts/cli/task/context/get.test.sh`)

### 24.1 Get all context files

Add 2 contexts, run `context get` with no args. Asserts:
- Stdout contains both context files' raw content (including frontmatter)

### 24.2 Get specific context ID

Add 2 contexts, run `context get <ctx-id-1>`. Asserts:
- Only first context's content printed

### 24.3 Get multiple specific context IDs

`context get <ctx-1> <ctx-2>`. Asserts:
- Both printed in order specified

### 24.4 Non-existent context ID fails

`context get context/nonexistent-00000000`. Asserts:
- Non-zero exit, error listing available IDs

### 24.5 Task with no context fails

Run `context get` on task with no contexts. Asserts:
- Non-zero exit, "no context files"

### 24.6 Get from explicit task

`context get --task <task-id>`. Asserts:
- Reads context from specified task

### 24.7 Get follows "where to read" rule

Complete and checkin a task with context. Run `context get --task <task-id>`. Asserts:
- Reads from parent branch (where task file was merged)

---

## 25. Test Suite: `task context list` (`scripts/cli/task/context/list.test.sh`)

### 25.1 List context IDs

Add 2 contexts, run `context list`. Asserts:
- Stdout has two lines, each a context ID

### 25.2 No contexts: empty output

Run `context list` on task with no contexts. Asserts:
- Empty stdout
- Exit code 0

### 25.3 List for explicit task

`context list <task-id>`. Asserts:
- Lists contexts for specified task

### 25.4 List with --task flag

`context list --task <task-id>`. Asserts:
- Same as positional arg

---

## 26. Test Suite: `task context delete` (`scripts/cli/task/context/delete.test.sh`)

### 26.1 Delete a context

Add context, then `context delete <ctx-id>`. Asserts:
- Context file removed from branch
- `context:` entry removed from task frontmatter
- `updated` timestamp refreshed
- Commit message "Delete context: <title>"

### 26.2 Delete non-existent context ID fails

`context delete context/nonexistent-00000000`. Asserts:
- Non-zero exit

### 26.3 Delete requires context/ prefix

`context delete foo-00000000`. Asserts:
- Non-zero exit, error about format

### 26.4 Delete with dirty WC rejected

Make WC dirty, try to delete context. Asserts:
- Non-zero exit

### 26.5 Delete from explicit task

`context delete <ctx-id> --task <task-id>`. Asserts:
- Context removed from specified task

### 26.6 Delete records transaction

Check `.tt/history`. Asserts:
- One entry, history integrity holds

---

## 27. Test Suite: `history undo` (`scripts/cli/history/undo.test.sh`)

### 27.1 Undo last command

Create a task (one history entry), then undo. Asserts:
- jj operation restored to before-op
- History file has one fewer entry
- Task bookmark no longer exists (undone)

### 27.2 Multiple sequential undos

Create project, create task (2 entries). Undo twice. Asserts:
- After first undo: task gone, project still exists
- After second undo: project gone too

### 27.3 History chain patched after undo

Undo once. Check that the now-last history entry's after-op matches the current jj op. Asserts:
- `jj op restore` creates a new op ID; the history line is patched
- History integrity holds after undo

### 27.4 Undo with op ID mismatch fails

Create a task (history entry), then make a manual jj operation (e.g. `jj new`). Try undo. Asserts:
- Non-zero exit, error about "modified outside of tt"
- With `--force`, succeeds

### 27.5 Undo with dirty WC fails

Make WC dirty, try undo. Asserts:
- Non-zero exit
- With `--force`, succeeds

### 27.6 Undo with in-progress transaction

Manually write a partial history entry (empty after-op). Try undo. Asserts:
- Non-zero exit, error about in-progress transaction
- With `--force`, succeeds (reverts the in-progress entry)

### 27.7 Empty history

No tt commands run (empty `.tt/history`). Try undo. Asserts:
- Non-zero exit, "Nothing to undo"

### 27.8 Undo preserves outgoing op ID in log

After undo, stderr contains the outgoing op ID for manual redo. Asserts:
- Output contains "jj op restore <op-id>"

---

## 28. Integration Test Scenarios

These are more complex multi-command workflows that exercise several commands
together, verifying the overall system coherence.

### 28.1 Full lifecycle: create → checkout → edit → checkpoint → complete → checkin

End-to-end workflow. Asserts:
- Final state: parent has [x] subtask, merge commit, WC on parent
- History integrity across all operations
- Workspace integrity (`assert_tt_workspace_integrity`)

### 28.2 Nested task hierarchy

Project → Phase 1 → Task A, Task B. Task A → subtask A1.
Complete A1 → checkin A1 → complete A → checkin A → complete Phase 1 → checkin Phase 1. Asserts:
- All subtask checkboxes [x] at each level
- No conflicts
- Tree output shows completed hierarchy

### 28.3 Propagate after sibling checkin

Project → A, B. Complete and checkin A. Propagate from project to B. Asserts:
- B now has A's changes in its ancestry
- B is VCS descendant of updated project tip

### 28.4 Undo a complete and re-do

Create task, complete, undo, verify status back to IN-PROGRESS, then complete again. Asserts:
- State correctly restored and re-applied

### 28.5 Rename + checkin

Create task, rename, then complete + checkin. Asserts:
- Parent's subtask entry uses new ID
- Merge commit references new ID
- No orphaned bookmarks

---

## 29. DESIGN.md Updates

Add a new section `§10 Testing` after §9 (User workflow):

```markdown
## 10. Testing

### 10.1 Test harness

The test harness (`scripts/test/harness.sh`) is a sourceable bash library providing:

- **Workspace setup:** `setup_workspace` creates a fresh jj repository with `tt workspace init` in a temporary directory, providing an isolated environment for each test. The workspace includes `workspace_dir` in `.tt/config.toml` for worktree-related tests.
- **Workflow helpers:** `create_project`, `create_task`, `create_task_under`, `checkout_task`, `checkpoint_task`, `complete_task`, `checkin_task`, `edit_file`, `append_file` — convenience wrappers for common workflow steps.
- **VCS introspection:** `get_jj_op`, `get_wc_commit`, `get_wc_change_id`, `get_bookmark_commit`, `get_full_commit_id`, `get_commit_message`, `get_commit_message_first_line`, `get_modified_files`, `get_file_list`, `is_wc_clean`, `is_diff_empty`, `read_file_at_rev`, `bookmark_exists`, `is_vcs_ancestor`, `get_bookmarks_at`, `get_all_task_bookmarks`, `count_commits`, `has_conflicts`, `file_exists_at_rev`, `get_symlink_target`.
- **Generic assertions:** `assert_eq`, `assert_neq`, `assert_contains`, `assert_not_contains`, `assert_matches`, `assert_not_matches`, `assert_file_exists`, `assert_file_not_exists`, `assert_symlink`, `assert_exit_code`, `assert_success`, `assert_failure`, `assert_output_empty`, `assert_output_not_empty`, `assert_line_count`.
- **VCS assertions:** `assert_commit_empty`, `assert_commit_not_empty`, `assert_bookmark_exists`, `assert_bookmark_not_exists`, `assert_wc_clean`, `assert_wc_dirty`, `assert_commit_message`, `assert_commit_message_first_line`, `assert_file_on_branch`, `assert_file_not_on_branch`, `assert_file_content_at_rev`, `assert_no_conflicts`, `assert_is_ancestor`, `assert_not_ancestor`, `assert_revset_count`.
- **tt-specific assertions:** `assert_task_status`, `assert_task_title`, `assert_task_label`, `assert_task_no_label`, `assert_task_body_contains`, `assert_frontmatter_field`, `assert_frontmatter_field_count`, `assert_subtask_entry`, `assert_no_subtask_entry`, `assert_subtask_count`, `assert_context_entry`, `assert_no_context_entry`, `assert_context_file_exists`, `assert_context_file_not_exists`, `assert_context_count`, `assert_current_task`, `assert_current_task_matches`, `assert_on_main`.
- **Transaction assertions:** `assert_history_count`, `assert_history_integrity`, `assert_no_pending_transaction`.
- **Integrity:** `assert_tt_workspace_integrity` — comprehensive structural check of all task files, subtask references, context references, and transaction state.
- **Debugging:** `dump_task_structure` — prints the full task tree for debugging.
- **Summary:** `harness_summary` prints pass/fail/skip counts and exits non-zero on failures.

### 10.2 Test structure

Test suites are co-located with their command implementations as `*.test.sh` files:

```
scripts/cli/workspace/init.test.sh        # tests for tt workspace init
scripts/cli/task/checkpoint.test.sh       # tests for tt task checkpoint
scripts/cli/task/create.test.sh           # tests for tt task create
scripts/cli/task/context/add.test.sh      # tests for tt task context add
scripts/cli/history/undo.test.sh          # tests for tt history undo
```

Each test file is a standalone bash script that sources the harness, runs tests inline, and calls `harness_summary` at the end. Tests use `_log_section` to label groups of related assertions.

### 10.3 Running tests

```bash
scripts/test.sh                          # run all test suites
scripts/test.sh checkpoint               # filter: only suites matching "checkpoint"
scripts/test.sh "context/"               # filter: all context command suites
bash scripts/cli/task/checkpoint.test.sh  # run a single suite directly
```

### 10.4 Test coverage

Every command in the CLI has a dedicated test suite:

| Command | Suite | Test count | Notes |
|---------|-------|------------|-------|
| `tt workspace init` | `workspace/init.test.sh` | 8 | Config, prefixes, guards |
| `tt workspace switch` | `workspace/switch.test.sh` | 5 | HEAD symlink, worktree lookup |
| `tt workspace branch` | `workspace/branch.test.sh` | 3 | Lookup + validation |
| `tt workspace worktree` | `workspace/worktree.test.sh` | 3 | Lookup + fallback |
| `tt task create` | `task/create.test.sh` | 16 | All modes + flags |
| `tt task checkout` | `task/checkout.test.sh` | 10 | Status transitions, worktrees |
| `tt task checkpoint` | `task/checkpoint.test.sh` | 7 | Commit format, history |
| `tt task complete` | `task/complete.test.sh` | 7 | Status, subtask gates |
| `tt task checkin` | `task/checkin.test.sh` | 15 | Merge, validation, propagate |
| `tt task edit` | `task/edit.test.sh` | 9 | Title/body/labels, cross-branch |
| `tt task delete` | `task/delete.test.sh` | 6 | Subtree removal, guards |
| `tt task rename` | `task/rename.test.sh` | 9 | Bookmark/dir/parent updates |
| `tt task move` | `task/move.test.sh` | 10 | Reparent, cycle detection |
| `tt task propagate` | `task/propagate.test.sh` | 12 | Rebase/merge, shallow, filter |
| `tt task publish` | `task/publish.test.sh` | 9 | Scaffold removal, target merge |
| `tt task tree` | `task/tree.test.sh` | 8 | Output format, filtering |
| `tt task show` | `task/show.test.sh` | 10 | Metadata display, where-to-read |
| `tt task current` | `task/current.test.sh` | 3 | Lookup |
| `tt task parent` | `task/parent.test.sh` | 5 | Lookup, --project |
| `tt task prompt` | `task/prompt.test.sh` | 5 | Output format, context |
| `tt task context add` | `task/context/add.test.sh` | 6 | File creation, frontmatter |
| `tt task context get` | `task/context/get.test.sh` | 7 | Retrieval, where-to-read |
| `tt task context list` | `task/context/list.test.sh` | 4 | Listing |
| `tt task context delete` | `task/context/delete.test.sh` | 6 | Removal, frontmatter |
| `tt history undo` | `history/undo.test.sh` | 8 | Rollback, chain patching |
| Integration | (in individual suites) | 5 | Full lifecycle workflows |

Edge cases requiring interactive input (editor prompts) cannot be tested non-interactively
but all commands accept `--message`/`--title`/`--slug` flags or stdin pipes as alternatives.
```

---

## Task List

- [ ] 1. Create jj change for the implementation
- [ ] 2. Create `scripts/test/harness.sh` — full test harness
- [ ] 3. Create `scripts/test.sh` — top-level runner
- [ ] 4. Create `scripts/cli/workspace/init.test.sh`
- [ ] 5. Create `scripts/cli/workspace/switch.test.sh`
- [ ] 6. Create `scripts/cli/workspace/branch.test.sh`
- [ ] 7. Create `scripts/cli/workspace/worktree.test.sh`
- [ ] 8. Create `scripts/cli/task/create.test.sh`
- [ ] 9. Create `scripts/cli/task/checkout.test.sh`
- [ ] 10. Create `scripts/cli/task/checkpoint.test.sh`
- [ ] 11. Create `scripts/cli/task/complete.test.sh`
- [ ] 12. Create `scripts/cli/task/checkin.test.sh`
- [ ] 13. Create `scripts/cli/task/edit.test.sh`
- [ ] 14. Create `scripts/cli/task/delete.test.sh`
- [ ] 15. Create `scripts/cli/task/rename.test.sh`
- [ ] 16. Create `scripts/cli/task/move.test.sh`
- [ ] 17. Create `scripts/cli/task/propagate.test.sh`
- [ ] 18. Create `scripts/cli/task/publish.test.sh`
- [ ] 19. Create `scripts/cli/task/tree.test.sh`
- [ ] 20. Create `scripts/cli/task/show.test.sh`
- [ ] 21. Create `scripts/cli/task/current.test.sh`
- [ ] 22. Create `scripts/cli/task/parent.test.sh`
- [ ] 23. Create `scripts/cli/task/prompt.test.sh`
- [ ] 24. Create `scripts/cli/task/context/add.test.sh`
- [ ] 25. Create `scripts/cli/task/context/get.test.sh`
- [ ] 26. Create `scripts/cli/task/context/list.test.sh`
- [ ] 27. Create `scripts/cli/task/context/delete.test.sh`
- [ ] 28. Create `scripts/cli/history/undo.test.sh`
- [ ] 29. Run all test suites and fix any issues
- [ ] 30. Update `DESIGN.md` with testing section
- [ ] 31. Final commit

---

## Relevant Source Paths

- `scripts/cli/tt` — main dispatcher
- `scripts/cli/lib/common.sh` — shared library (transactions, helpers)
- `scripts/cli/workspace/init` — workspace init command
- `scripts/cli/workspace/switch` — workspace switch command
- `scripts/cli/workspace/branch` — workspace branch command
- `scripts/cli/workspace/worktree` — workspace worktree command
- `scripts/cli/task/create` — create command
- `scripts/cli/task/checkout` — checkout command
- `scripts/cli/task/checkpoint` — checkpoint command
- `scripts/cli/task/complete` — complete command
- `scripts/cli/task/checkin` — checkin command
- `scripts/cli/task/edit` — edit command
- `scripts/cli/task/delete` — delete command
- `scripts/cli/task/rename` — rename command
- `scripts/cli/task/move` — move command
- `scripts/cli/task/propagate` — propagate command
- `scripts/cli/task/publish` — publish command
- `scripts/cli/task/tree` — tree command
- `scripts/cli/task/show` — show command
- `scripts/cli/task/current` — current command
- `scripts/cli/task/parent` — parent command
- `scripts/cli/task/prompt` — prompt command
- `scripts/cli/task/context/add` — context add command
- `scripts/cli/task/context/get` — context get command
- `scripts/cli/task/context/list` — context list command
- `scripts/cli/task/context/delete` — context delete command
- `scripts/cli/history/undo` — history undo command
- `tests/test-history-undo.sh` — existing ad-hoc test (reference for patterns)
- `.agents/plans/scripts/test-checkin-validation.sh` — existing ad-hoc test
- `.agents/plans/scripts/test-task-show-completed.sh` — existing ad-hoc test
- `DESIGN.md` — project design document
- `.agents/rules/bash-style.mdc` — bash coding guidelines
