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

# Global counters (written to temp files so subshells can contribute)
_PASS_COUNT=0
_FAIL_COUNT=0
_SKIP_COUNT=0
declare -a _FAILURES=()



# Temp dir for accumulating results across subshells
_RESULTS_DIR="$(mktemp -d)"
trap 'rm -rf "$_RESULTS_DIR"' EXIT

# Suite start time in milliseconds. Uses python3 for sub-second precision;
# falls back to whole seconds via date if python3 is unavailable.
_ms_now() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    printf '%d000' "$(date +%s)"
  fi
}
_SUITE_START="$(_ms_now)"
_SECTION_START="$_SUITE_START"

# Colors (respect NO_COLOR; _TT_TEST_FORCE_COLOR bypasses the TTY check for
# buffered subprocess output that will be replayed on a real TTY by the runner)
if [[ -z "${NO_COLOR:-}" && ( -t 2 || -n "${_TT_TEST_FORCE_COLOR:-}" ) ]]; then
  _RED='\033[0;31m'
  _GREEN='\033[0;32m'
  _YELLOW='\033[0;33m'
  _CYAN='\033[0;36m'
  _BOLD='\033[1m'
  _RESET='\033[0m'
else
  _RED='' _GREEN='' _YELLOW='' _CYAN='' _BOLD='' _RESET=''
fi

# ---------------------------------------------------------------------------
# Test Lifecycle
# ---------------------------------------------------------------------------

# Per-test temp directory; cleaned up after each test.
# A new directory is created within the provided TT_TEST_ROOT
# if specified otherwise a fresh temp dir is created.
if [[ -n "${TT_TEST_ROOT:-}" ]]; then
  _TEST_ROOT="$(mktemp -d "$TT_TEST_ROOT/tt-test-XXXXXX")"
else
  _TEST_ROOT="$(mktemp -d)"
fi
trap 'rm -rf "$_TEST_ROOT"' EXIT

# Per-test workspace vars (set by setup_workspace)
REPO=""
VIRTUAL=""

# Create a fresh jj repo + tt workspace for a test.
# Sets REPO, VIRTUAL, and exports TT_REPO, changes CWD to REPO.
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
  # workspace init creates .tt/workspace symlink automatically; no further setup needed.

  # Export so run_tt forwards it as --repo to all tt commands
  export TT_REPO="$REPO"
}

# ---------------------------------------------------------------------------
# tt Command Helper
# ---------------------------------------------------------------------------

# Run a tt command, with stdout and stderr captured separately.
# Usage: run_tt [args...]
run_tt() {
  TT_REPO="${TT_REPO:-${REPO:-}}" "$TT" "$@"
}

# Edit a working copy file (creates or overwrites).
# Usage: edit_file PATH CONTENT
edit_file() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
}

# Append to a working copy file.
# Usage: append_file PATH CONTENT
append_file() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" >> "$path"
}

# ---------------------------------------------------------------------------
# Workflow Convenience Helpers
# ---------------------------------------------------------------------------

# Create a project and return its ID on stdout.
# Usage: id=$(create_project SLUG TITLE [BODY])
create_project() {
  local slug="$1" title="$2" body="${3:-}"
  run_tt task create --project --slug "$slug" --title "$title" <<< "$body" 2>/dev/null | tail -1
}

# Create a child task under the current branch and return its ID on stdout.
# Usage: id=$(create_task SLUG TITLE [BODY])
create_task() {
  local slug="$1" title="$2" body="${3:-}"
  run_tt task create --slug "$slug" --title "$title" <<< "$body" 2>/dev/null | tail -1
}

# Create a child task under a specific parent and return its ID on stdout.
# Usage: id=$(create_task_under PARENT_ID SLUG TITLE [BODY])
create_task_under() {
  local parent="$1" slug="$2" title="$3" body="${4:-}"
  run_tt task create --parent "$parent" --slug "$slug" --title "$title" <<< "$body" 2>/dev/null | tail -1
}

# Checkout a task (switches WC to it).
# Usage: checkout_task TASK_ID
checkout_task() {
  run_tt task checkout "$1" >/dev/null 2>&1
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

# Capture the task ID from the last line of stdout.
# Usage: TASK_ID=$(last_line "$output")
last_line() {
  printf '%s' "$1" | tail -1
}

# ---------------------------------------------------------------------------
# VCS Introspection Helpers
# ---------------------------------------------------------------------------

# Get the current jj operation ID.
get_jj_op() {
  jj -R "$REPO" op log --no-graph -T id -n 1 2>/dev/null
}

# Get the current working-copy revision's change ID (short 8 chars).
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

# Check if a given revision has an empty diff.
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

# ---------------------------------------------------------------------------
# Log Helpers
# ---------------------------------------------------------------------------

_log_pass() { printf '%b  ✓ %s%b\n' "$_GREEN" "$1" "$_RESET" >&2; }
_log_fail() { printf '%b  ✗ %s%b\n' "$_RED" "$1" "$_RESET" >&2; }
_log_skip() { printf '%b  ⊘ %s%b\n' "$_YELLOW" "$1" "$_RESET" >&2; }
_log_section() {
  # Print elapsed time for the previous section if one was running
  local now elapsed
  now="$(_ms_now)"
  if [[ "$_SECTION_START" != "$_SUITE_START" ]]; then
    elapsed=$(( now - _SECTION_START ))
    printf '%b  (%d.%03ds)%b\n' "$_YELLOW" "$(( elapsed / 1000 ))" "$(( elapsed % 1000 ))" "$_RESET" >&2
  fi
  _SECTION_START="$now"
  printf '\n%b── %s%b\n' "$_BOLD" "$1" "$_RESET" >&2
}

# ---------------------------------------------------------------------------
# Generic Assertion Helpers
# ---------------------------------------------------------------------------

# _record_pass / _record_fail / _record_skip
# Write a result to the shared temp dir so subshells contribute to totals.
_record_pass() { printf 'p\n' >> "${_TT_TEST_RESULTS_DIR:-$_RESULTS_DIR}/results"; }
_record_fail() { printf 'f\n' >> "${_TT_TEST_RESULTS_DIR:-$_RESULTS_DIR}/results"; printf '%s\n' "$1" >> "${_TT_TEST_RESULTS_DIR:-$_RESULTS_DIR}/failures"; }
_record_skip() { printf 's\n' >> "${_TT_TEST_RESULTS_DIR:-$_RESULTS_DIR}/results"; }

# assert_eq LABEL ACTUAL EXPECTED
assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected '$expected', got '$actual'"
    _record_fail "$label: expected '$expected', got '$actual'"
  fi
}

# assert_neq LABEL ACTUAL UNEXPECTED
assert_neq() {
  local label="$1" actual="$2" unexpected="$3"
  if [[ "$actual" != "$unexpected" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected value to differ from '$unexpected'"
    _record_fail "$label: expected value to differ from '$unexpected'"
  fi
}

# assert_contains LABEL HAYSTACK NEEDLE
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected to contain '$needle'"
    printf '    Actual: %s\n' "$haystack" >&2
    _record_fail "$label: expected to contain '$needle'"
  fi
}

# assert_not_contains LABEL HAYSTACK NEEDLE
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected NOT to contain '$needle'"
    _record_fail "$label: expected NOT to contain '$needle'"
  fi
}

# assert_matches LABEL STRING PATTERN
# PATTERN is an extended regex (ERE).
# %SLUG% shorthand: matches a task/project ID with given slug.
assert_matches() {
  local label="$1" string="$2" pattern="$3"
  local ere_pattern
  ere_pattern="$(printf '%s' "$pattern" | sed 's/%[^%]*%/[a-z0-9-]+-[0-9a-f]{8}/g')"
  if printf '%s' "$string" | grep -qE "$ere_pattern"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected to match pattern '$pattern' (ERE: '$ere_pattern')"
    printf '    Actual: %s\n' "$string" >&2
    _record_fail "$label: expected to match '$pattern'"
  fi
}

# assert_not_matches LABEL STRING PATTERN
assert_not_matches() {
  local label="$1" string="$2" pattern="$3"
  local ere_pattern
  ere_pattern="$(printf '%s' "$pattern" | sed 's/%[^%]*%/[a-z0-9-]+-[0-9a-f]{8}/g')"
  if ! printf '%s' "$string" | grep -qE "$ere_pattern"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected NOT to match pattern '$pattern'"
    _record_fail "$label: expected NOT to match '$pattern'"
  fi
}

# assert_file_exists LABEL PATH
assert_file_exists() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: file not found: $path"
    _record_fail "$label: file not found: $path"
  fi
}

# assert_file_not_exists LABEL PATH
assert_file_not_exists() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: file should not exist: $path"
    _record_fail "$label: file should not exist: $path"
  fi
}

# assert_symlink LABEL PATH EXPECTED_TARGET
assert_symlink() {
  local label="$1" path="$2" expected="$3"
  if [[ -L "$path" ]]; then
    local actual
    actual="$(readlink "$path")"
    assert_eq "$label" "$actual" "$expected"
  else
    _log_fail "$label: not a symlink: $path"
    _record_fail "$label: not a symlink: $path"
  fi
}

# assert_exit_code LABEL EXPECTED ACTUAL
assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  assert_eq "$label (exit code)" "$actual" "$expected"
}

# assert_success LABEL EXIT_CODE
assert_success() {
  local label="$1" exit_code="$2"
  assert_eq "$label (should succeed)" "$exit_code" "0"
}

# assert_failure LABEL EXIT_CODE
assert_failure() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" != "0" ]]; then
    _log_pass "$label (exit code $exit_code)"
    _record_pass
  else
    _log_fail "$label: expected non-zero exit code, got 0"
    _record_fail "$label: expected non-zero exit code, got 0"
  fi
}

# assert_output_empty LABEL OUTPUT
assert_output_empty() {
  local label="$1" output="$2"
  if [[ -z "$output" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected empty output, got: $output"
    _record_fail "$label: expected empty output"
  fi
}

# assert_output_not_empty LABEL OUTPUT
assert_output_not_empty() {
  local label="$1" output="$2"
  if [[ -n "$output" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: expected non-empty output"
    _record_fail "$label: expected non-empty output"
  fi
}

# assert_line_count LABEL OUTPUT EXPECTED_COUNT
assert_line_count() {
  local label="$1" output="$2" expected="$3"
  local actual
  actual="$(printf '%s' "$output" | grep -c . 2>/dev/null || true)"
  assert_eq "$label (line count)" "$actual" "$expected"
}

# ---------------------------------------------------------------------------
# VCS-Specific Assertion Helpers
# ---------------------------------------------------------------------------

# assert_commit_empty LABEL REV
assert_commit_empty() {
  local label="$1" rev="$2"
  if is_diff_empty "$rev"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: commit '$rev' is not empty (has file changes)"
    _record_fail "$label: commit '$rev' is not empty"
  fi
}

# assert_commit_not_empty LABEL REV
assert_commit_not_empty() {
  local label="$1" rev="$2"
  if ! is_diff_empty "$rev"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: commit '$rev' should not be empty"
    _record_fail "$label: commit '$rev' should be non-empty"
  fi
}

# assert_bookmark_exists LABEL BOOKMARK
assert_bookmark_exists() {
  local label="$1" bookmark="$2"
  if bookmark_exists "$bookmark"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: bookmark '$bookmark' does not exist"
    _record_fail "$label: bookmark '$bookmark' does not exist"
  fi
}

# assert_bookmark_not_exists LABEL BOOKMARK
assert_bookmark_not_exists() {
  local label="$1" bookmark="$2"
  if ! bookmark_exists "$bookmark"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: bookmark '$bookmark' should not exist"
    _record_fail "$label: bookmark '$bookmark' should not exist"
  fi
}

# assert_wc_clean LABEL
assert_wc_clean() {
  local label="$1"
  if is_wc_clean; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: working copy is not clean"
    _record_fail "$label: working copy is not clean"
  fi
}

# assert_wc_dirty LABEL
assert_wc_dirty() {
  local label="$1"
  if ! is_wc_clean; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: working copy should be dirty"
    _record_fail "$label: working copy should be dirty"
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
assert_commit_message_first_line() {
  local label="$1" rev="$2" expected="$3"
  local actual
  actual="$(get_commit_message_first_line "$rev")"
  assert_eq "$label" "$actual" "$expected"
}

# assert_file_on_branch LABEL BRANCH PATH
assert_file_on_branch() {
  local label="$1" branch="$2" path="$3"
  if file_exists_at_rev "$branch" "$path"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: file '$path' not found on branch '$branch'"
    _record_fail "$label: file '$path' not found on branch '$branch'"
  fi
}

# assert_file_not_on_branch LABEL BRANCH PATH
assert_file_not_on_branch() {
  local label="$1" branch="$2" path="$3"
  if ! file_exists_at_rev "$branch" "$path"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: file '$path' should not exist on branch '$branch'"
    _record_fail "$label: file '$path' should not exist on branch '$branch'"
  fi
}

# assert_file_content_at_rev LABEL REV PATH EXPECTED_CONTENT
assert_file_content_at_rev() {
  local label="$1" rev="$2" path="$3" expected="$4"
  local actual
  actual="$(read_file_at_rev "$rev" "$path")" || {
    _log_fail "$label: could not read $path at $rev"
    _record_fail "$label: could not read $path at $rev"
    return
  }
  assert_contains "$label" "$actual" "$expected"
}

# assert_no_conflicts LABEL [REVSET]
assert_no_conflicts() {
  local label="$1" revset="${2:-bookmarks()}"
  local conflicted
  conflicted="$(jj -R "$REPO" log -r "$revset" --no-graph \
    -T 'if(conflict, commit_id.short(8) ++ " " ++ description.first_line() ++ "\n")' \
    2>/dev/null)" || true
  if [[ -z "$conflicted" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: conflicting commits found:"
    printf '%s\n' "$conflicted" | while IFS= read -r line; do
      printf '    %s\n' "$line" >&2
    done
    _record_fail "$label: conflicting commits found"
  fi
}

# assert_is_ancestor LABEL ANCESTOR_REV DESCENDANT_REV
assert_is_ancestor() {
  local label="$1" ancestor="$2" descendant="$3"
  if is_vcs_ancestor "$ancestor" "$descendant"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: '$ancestor' is not an ancestor of '$descendant'"
    _record_fail "$label: '$ancestor' is not an ancestor of '$descendant'"
  fi
}

# assert_not_ancestor LABEL ANCESTOR_REV DESCENDANT_REV
assert_not_ancestor() {
  local label="$1" ancestor="$2" descendant="$3"
  if ! is_vcs_ancestor "$ancestor" "$descendant"; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: '$ancestor' should not be an ancestor of '$descendant'"
    _record_fail "$label: '$ancestor' should not be an ancestor of '$descendant'"
  fi
}

# assert_revset_count LABEL REVSET EXPECTED_COUNT
assert_revset_count() {
  local label="$1" revset="$2" expected="$3"
  local actual
  actual="$(count_commits "$revset")"
  assert_eq "$label" "$actual" "$expected"
}

# ---------------------------------------------------------------------------
# Task File Helpers
# ---------------------------------------------------------------------------

# Read the TASK.md for a given task ID from its branch (default) or from REV.
# Usage: content=$(read_task_file "task/my-task-abc12345")
read_task_file() {
  local task_id="$1" rev="${2:-$1}"
  local suffix="${task_id#*/}"
  jj -R "$REPO" file show -r "$rev" -- ".tt/task/$suffix/TASK.md" 2>/dev/null
}

# Extract a single-value frontmatter field.
get_frontmatter_field() {
  local content="$1" field="$2"
  printf '%s' "$content" | sed -n "s/^${field}: *//p" | head -1
}

# Extract all values for a repeatable frontmatter field.
get_frontmatter_field_all() {
  local content="$1" field="$2"
  printf '%s' "$content" | sed -n "s/^${field}: *//p"
}

# Extract the body (everything after the second ---).
get_task_body() {
  local content="$1"
  printf '%s' "$content" | awk '/^---$/{n++; if(n==2){found=1; next}} found{print}'
}

# ---------------------------------------------------------------------------
# Task Status / Frontmatter Assertions
# ---------------------------------------------------------------------------

# assert_task_status LABEL TASK_ID EXPECTED_STATUS [REV]
assert_task_status() {
  local label="$1" task_id="$2" expected="$3"
  local rev="${4:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  actual="$(get_frontmatter_field "$content" "status")"
  assert_eq "$label" "$actual" "$expected"
}

# assert_task_title LABEL TASK_ID EXPECTED_TITLE [REV]
assert_task_title() {
  local label="$1" task_id="$2" expected="$3"
  local rev="${4:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  actual="$(get_frontmatter_field "$content" "title" | sed 's/^"//;s/"$//')"
  assert_eq "$label" "$actual" "$expected"
}

# assert_task_label LABEL TASK_ID EXPECTED_LABEL [REV]
assert_task_label() {
  local label="$1" task_id="$2" expected="$3"
  local rev="${4:-$task_id}"
  local content labels
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  labels="$(get_frontmatter_field_all "$content" "label")"
  assert_contains "$label" "$labels" "$expected"
}

# assert_task_no_label LABEL TASK_ID UNEXPECTED_LABEL [REV]
assert_task_no_label() {
  local label="$1" task_id="$2" unexpected="$3"
  local rev="${4:-$task_id}"
  local content labels
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  labels="$(get_frontmatter_field_all "$content" "label")"
  assert_not_contains "$label" "$labels" "$unexpected"
}

# assert_task_body_contains LABEL TASK_ID NEEDLE [REV]
assert_task_body_contains() {
  local label="$1" task_id="$2" needle="$3"
  local rev="${4:-$task_id}"
  local content body
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  body="$(get_task_body "$content")"
  assert_contains "$label" "$body" "$needle"
}

# assert_frontmatter_field LABEL TASK_ID FIELD EXPECTED_VALUE [REV]
assert_frontmatter_field() {
  local label="$1" task_id="$2" field="$3" expected="$4"
  local rev="${5:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  actual="$(get_frontmatter_field "$content" "$field")"
  assert_eq "$label" "$actual" "$expected"
}

# assert_frontmatter_field_count LABEL TASK_ID FIELD EXPECTED_COUNT [REV]
assert_frontmatter_field_count() {
  local label="$1" task_id="$2" field="$3" expected="$4"
  local rev="${5:-$task_id}"
  local content actual
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  actual="$(get_frontmatter_field_all "$content" "$field" | grep -c . 2>/dev/null || true)"
  assert_eq "$label" "$actual" "$expected"
}

# ---------------------------------------------------------------------------
# Subtask Entry Assertions
# ---------------------------------------------------------------------------

# assert_subtask_entry LABEL PARENT_ID CHILD_ID EXPECTED_CHECKBOX [REV]
assert_subtask_entry() {
  local label="$1" parent_id="$2" child_id="$3" expected_checkbox="$4"
  local rev="${5:-$parent_id}"
  local content
  content="$(read_task_file "$parent_id" "$rev")" || {
    _log_fail "$label: could not read task file for parent '$parent_id'"
    _record_fail "$label: could not read task file for parent '$parent_id'"
    return
  }
  local expected_line="subtask: ${expected_checkbox} ${child_id}"
  assert_contains "$label" "$content" "$expected_line"
}

# assert_no_subtask_entry LABEL PARENT_ID CHILD_ID [REV]
assert_no_subtask_entry() {
  local label="$1" parent_id="$2" child_id="$3"
  local rev="${4:-$parent_id}"
  local content
  content="$(read_task_file "$parent_id" "$rev")" || {
    _log_fail "$label: could not read task file for parent '$parent_id'"
    _record_fail "$label: could not read task file for parent '$parent_id'"
    return
  }
  if printf '%s' "$content" | grep -qF "subtask: " && \
     printf '%s' "$content" | grep "subtask: " | grep -qF "$child_id"; then
    _log_fail "$label: parent '$parent_id' still has a subtask entry for '$child_id'"
    _record_fail "$label: parent still has subtask entry for '$child_id'"
  else
    _log_pass "$label"
    _record_pass
  fi
}

# ---------------------------------------------------------------------------
# Context Assertions
# ---------------------------------------------------------------------------

# assert_context_entry LABEL TASK_ID CTX_ID [REV]
assert_context_entry() {
  local label="$1" task_id="$2" ctx_id="$3"
  local rev="${4:-$task_id}"
  local content
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  assert_contains "$label" "$content" "context: $ctx_id"
}

# assert_no_context_entry LABEL TASK_ID CTX_ID [REV]
assert_no_context_entry() {
  local label="$1" task_id="$2" ctx_id="$3"
  local rev="${4:-$task_id}"
  local content
  content="$(read_task_file "$task_id" "$rev")" || {
    _log_fail "$label: could not read task file for '$task_id'"
    _record_fail "$label: could not read task file for '$task_id'"
    return
  }
  assert_not_contains "$label" "$content" "context: $ctx_id"
}

# assert_context_file_exists LABEL TASK_ID CTX_ID [REV]
assert_context_file_exists() {
  local label="$1" task_id="$2" ctx_id="$3"
  local rev="${4:-$task_id}"
  local suffix="${task_id#*/}"
  local ctx_path=".tt/task/$suffix/${ctx_id}.md"
  assert_file_on_branch "$label" "$rev" "$ctx_path"
}

# assert_context_file_not_exists LABEL TASK_ID CTX_ID [REV]
assert_context_file_not_exists() {
  local label="$1" task_id="$2" ctx_id="$3"
  local rev="${4:-$task_id}"
  local suffix="${task_id#*/}"
  local ctx_path=".tt/task/$suffix/${ctx_id}.md"
  assert_file_not_on_branch "$label" "$rev" "$ctx_path"
}

# assert_context_count LABEL TASK_ID EXPECTED_COUNT [REV]
assert_context_count() {
  local label="$1" task_id="$2" expected="$3" rev="${4:-$task_id}"
  assert_frontmatter_field_count "$label" "$task_id" "context" "$expected" "$rev"
}

# ---------------------------------------------------------------------------
# Current Task / Misc Assertions
# ---------------------------------------------------------------------------

# assert_current_task LABEL EXPECTED_TASK_ID
assert_current_task() {
  local label="$1" expected="$2"
  local actual
  actual="$(jj -R "$REPO" log -r 'heads(ancestors(@) & bookmarks())' -n 1 --no-graph \
    -T 'local_bookmarks.map(|b| b.name()).join(",")' 2>/dev/null)" || true
  actual="${actual%%,*}"
  assert_eq "$label" "$actual" "$expected"
}

# assert_current_task_matches LABEL EXPECTED_ERE_PATTERN
assert_current_task_matches() {
  local label="$1" pattern="$2"
  local actual
  actual="$(jj -R "$REPO" log -r 'heads(ancestors(@) & bookmarks())' -n 1 --no-graph \
    -T 'local_bookmarks.map(|b| b.name()).join(",")' 2>/dev/null)" || true
  actual="${actual%%,*}"
  assert_matches "$label" "$actual" "$pattern"
}

# assert_on_main LABEL
assert_on_main() {
  local label="$1"
  local actual
  actual="$(jj -R "$REPO" log -r 'heads(ancestors(@) & bookmarks())' -n 1 --no-graph \
    -T 'local_bookmarks.map(|b| b.name()).join(",")' 2>/dev/null)" || true
  actual="${actual%%,*}"
  assert_eq "$label" "$actual" "main"
}

# ---------------------------------------------------------------------------
# Transaction History Assertions
# ---------------------------------------------------------------------------

declare -a HISTORY_LINES=()

# Read all lines from .tt/history into HISTORY_LINES.
get_history_lines() {
  HISTORY_LINES=()
  local hf="$REPO/.tt/history"
  if [[ -f "$hf" && -s "$hf" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && HISTORY_LINES+=("$line")
    done < "$hf"
  fi
}

history_before_op() { printf '%s' "${1%%:*}"; }
history_after_op()  { printf '%s' "${1#*:}"; }

# assert_history_count LABEL EXPECTED_COUNT
assert_history_count() {
  local label="$1" expected="$2"
  get_history_lines
  assert_eq "$label" "${#HISTORY_LINES[@]}" "$expected"
}

# assert_subtask_count LABEL PARENT_ID EXPECTED_COUNT [REV]
assert_subtask_count() {
  local label="$1" parent_id="$2" expected="$3"
  local rev="${4:-$parent_id}"
  assert_frontmatter_field_count "$label" "$parent_id" "subtask" "$expected" "$rev"
}

# assert_history_integrity LABEL [CHAIN_DEPTH]
#
# Verifies:
#   1. No in-progress entries: every after-op-id is non-empty.
#   2. The last entry's after-op-id matches the current jj operation ID,
#      i.e. no jj operations have happened since the last tt command.
#   3. Chain contiguity for the last CHAIN_DEPTH entries:
#      entry[i].after == entry[i+1].before for the tail of the log.
#      Defaults to the full history length (all entries checked).
#
# Why gaps can occur: jj auto-snapshots the working copy whenever files
# change between tt commands, advancing the op log without a history entry.
# Each entry's before-op remains a valid restore point, so undo correctness
# is unaffected. Pass an explicit CHAIN_DEPTH equal to the number of tt
# commands your test section issued to limit the contiguity check to those
# entries and avoid false failures from snapshots triggered earlier in setup.
assert_history_integrity() {
  local label="$1" chain_depth="${2:-}"
  get_history_lines
  local count="${#HISTORY_LINES[@]}"

  if [[ $count -eq 0 ]]; then
    _log_pass "$label (empty history)"
    _record_pass
    return
  fi

  # Check 1: no in-progress entry (every after-op-id must be non-empty)
  local i
  for ((i=0; i<count; i++)); do
    local after
    after="$(history_after_op "${HISTORY_LINES[$i]}")"
    if [[ -z "$after" ]]; then
      _log_fail "$label: in-progress transaction at entry $i (empty after-op)"
      _record_fail "$label: in-progress transaction at entry $i"
      return
    fi
  done

  # Check 2: last after-op matches current jj op
  local last_after current_op
  last_after="$(history_after_op "${HISTORY_LINES[$((count-1))]}")"  
  current_op="$(get_jj_op)"
  if [[ "$last_after" != "$current_op" ]]; then
    _log_fail "$label: last after-op (${last_after:0:12}) != current jj op (${current_op:0:12})"
    _record_fail "$label: history out of sync with jj"
    return
  fi

  # Check 3: chain contiguity for the last CHAIN_DEPTH entries (default: all)
  local effective_depth=$(( chain_depth > 0 ? chain_depth : count ))
  if [[ $effective_depth -gt 1 ]]; then
    # The tail slice starts at index (count - effective_depth), clamped to 0.
    local start=$(( count - effective_depth ))
    [[ $start -lt 0 ]] && start=0
    for ((i=start; i<count-1; i++)); do
      local this_after next_before
      this_after="$(history_after_op "${HISTORY_LINES[$i]}")"
      next_before="$(history_before_op "${HISTORY_LINES[$((i+1))]}")"    
      if [[ "$this_after" != "$next_before" ]]; then
        _log_fail "$label: history chain broken at entry $i (last $chain_depth checked): after (${this_after:0:12}) != next before (${next_before:0:12})"
        _record_fail "$label: history chain broken at entry $i"
        return
      fi
    done
  fi

  _log_pass "$label"
  _record_pass
}

# assert_no_pending_transaction LABEL
assert_no_pending_transaction() {
  local label="$1"
  get_history_lines
  local count="${#HISTORY_LINES[@]}"
  if [[ $count -eq 0 ]]; then
    _log_pass "$label (empty history)"
    _record_pass
    return
  fi
  local last_after
  last_after="$(history_after_op "${HISTORY_LINES[$((count-1))]}")"  
  if [[ -z "$last_after" ]]; then
    _log_fail "$label: last history entry is in-progress (no after-op-id)"
    _record_fail "$label: dangling in-progress transaction"
  else
    _log_pass "$label"
    _record_pass
  fi
}

# ---------------------------------------------------------------------------
# .tt Workspace Integrity Assertions
# ---------------------------------------------------------------------------

# Print a human-readable tree of all bookmarks and their task files to stderr.
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

# Comprehensive structural integrity check of the .tt workspace state.
assert_tt_workspace_integrity() {
  local label="$1"
  local errors=0

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
    _record_pass
  else
    _log_fail "$label: $errors workspace integrity error(s)"
    _record_fail "$label: $errors workspace integrity error(s)"
  fi
}

# ---------------------------------------------------------------------------
# Summary and Exit
# ---------------------------------------------------------------------------

# Print test summary and exit with appropriate code.
# Tallies results written by subshells via _record_pass/_record_fail/_record_skip.
# suite_summary
#
# Print pass/fail/skip totals for this suite.
# When _TT_TEST_RESULTS_DIR is set the runner owns the final summary; this
# becomes a no-op so each individual suite does not print its own summary box.
suite_summary() {
  # Runner owns the summary when it provides a shared results dir.
  [[ -n "${_TT_TEST_RESULTS_DIR:-}" ]] && return 0
  _harness_print_summary "$_RESULTS_DIR"
}

# _harness_print_summary RESULTS_DIR
# Print the summary box from a results directory.
_harness_print_summary() {
  local results_dir="$1"
  local pass=0 fail=0 skip=0
  if [[ -f "$results_dir/results" ]]; then
    while IFS= read -r rec; do
      case "$rec" in
        p) ((pass++)) || true ;;
        f) ((fail++)) || true ;;
        s) ((skip++)) || true ;;
      esac
    done < "$results_dir/results"
  fi

  local now total_elapsed
  now="$(_ms_now)"
  total_elapsed=$(( now - _SUITE_START ))
  printf '\n%b══════════════════════════════════════════════════════════════%b\n' "$_CYAN" "$_RESET" >&2
  printf '%b  Results: %d passed, %d failed, %d skipped  (%d.%03ds)%b\n' \
    "$_BOLD" "$pass" "$fail" "$skip" "$(( total_elapsed / 1000 ))" "$(( total_elapsed % 1000 ))" "$_RESET" >&2
  if [[ -f "$results_dir/failures" && -s "$results_dir/failures" ]]; then
    printf '\n%b  Failures:%b\n' "$_RED" "$_RESET" >&2
    while IFS= read -r f; do
      printf '%b    • %s%b\n' "$_RED" "$f" "$_RESET" >&2
    done < "$results_dir/failures"
  fi
  printf '%b══════════════════════════════════════════════════════════════%b\n' "$_CYAN" "$_RESET" >&2

  [[ $fail -eq 0 ]]
}

# run_tests TITLE
#
# Print the suite title, discover all test_* functions defined in the sourcing
# script, optionally filter them, then run them and print a summary.
#
# TITLE  Human-readable suite name, e.g. "tt task checkin".
#
# Environment variables (set by the runner; not intended for direct use):
#
#   _TT_TEST_RUN_ONLY
#     Internal. When set, run only the named test function and exit.
#     Set by the flat pool in test runner; never set directly by users.
#
#   _TT_TEST_FORCE_COLOR
#     Internal. When set, enable ANSI colors even though stderr is not a TTY
#     (because the subprocess output will be replayed on a real TTY by the runner).
#
#   _TT_TEST_FILTER_0, _TT_TEST_FILTER_1, ...
#     ERE patterns (bash =~ operator). A test is included if its full label
#     ("TITLE: function_name") matches ANY of the supplied patterns. When no
#     patterns are set all tests are included.
#
#   _TT_TEST_REGISTER=1
#     Registration pass: write the filtered test names (one per line) to
#     "$_TT_TEST_RESULTS_DIR/tests/$_TT_TEST_SUITE_INDEX" and exit without
#     running any tests. Used by the runner to build the flat test list
#     before the real run.
#
#   _TT_TEST_RESULTS_DIR
#     Shared results directory. _record_pass/fail/skip write here instead of
#     the local temp dir, and suite_summary becomes a no-op (the runner
#     prints a single summary at the end).
#
#   _TT_TEST_OFFSET, _TT_TEST_TOTAL
#     Starting index (0-based) and global total for [n/N] labels.
#
# Usage: call once at the end of a test file in place of suite_summary.
run_tests() {
  local title="${1:?run_tests requires a suite title argument}"

  # Discover all test_* functions in the sourcing script.
  local -a all_tests=()
  while IFS= read -r fn; do
    all_tests+=("$fn")
  done < <(declare -F | awk '{print $3}' | grep '^test_')

  # Apply --filter patterns if any are set.
  local -a tests=()
  local -a filter_patterns=()
  local k=0
  while true; do
    local var="_TT_TEST_FILTER_${k}"
    [[ -z "${!var+set}" ]] && break
    filter_patterns+=("${!var}")
    (( k++ )) || true
  done

  if [[ ${#filter_patterns[@]} -eq 0 ]]; then
    tests=("${all_tests[@]}")
  else
    for fn in "${all_tests[@]}"; do
      local label="$title: $fn"
      local matched=false
      for pattern in "${filter_patterns[@]}"; do
        if [[ "$label" =~ $pattern ]]; then
          matched=true
          break
        fi
      done
      [[ "$matched" == true ]] && tests+=("$fn")
    done
  fi

  # Registration pass: write filtered test names and exit without running.
  if [[ "${_TT_TEST_REGISTER:-}" == "1" ]]; then
    local tests_dir="${_TT_TEST_RESULTS_DIR:?_TT_TEST_RESULTS_DIR required for registration}/tests"
    mkdir -p "$tests_dir"
    printf '%s\n' "${tests[@]}" > "$tests_dir/${_TT_TEST_SUITE_INDEX:?_TT_TEST_SUITE_INDEX required for registration}"
    return 0
  fi

  local suite_total=${#tests[@]}
  local global_offset="${_TT_TEST_OFFSET:-0}"
  local global_total="${_TT_TEST_TOTAL:-$suite_total}"

  if [[ ${#tests[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ -n "${_TT_TEST_RUN_ONLY:-}" ]]; then
    _harness_run_one "$title" "$global_offset" "$global_total" "$_TT_TEST_RUN_ONLY"
  else
    _harness_run_serial "$title" "$suite_total" "${tests[@]}"
  fi

  suite_summary
}

# _harness_run_serial TITLE TOTAL TEST...
# Run test functions sequentially, using _log_section for timing.
_harness_run_serial() {
  local title="$1" total="$2"; shift 2
  local global_offset="${_TT_TEST_OFFSET:-0}"
  local global_total="${_TT_TEST_TOTAL:-$total}"
  local i=0
  for fn in "$@"; do
    (( i++ )) || true
    local global_idx=$(( global_offset + i ))
    _log_section "[$global_idx/$global_total] $title: $fn"
    ( "$fn" )
  done
}


# _harness_run_one TITLE GLOBAL_OFFSET GLOBAL_TOTAL FN
# Run a single named test function (used by the flat pool in test runner).
_harness_run_one() {
  local title="$1" global_offset="$2" global_total="$3" fn="$4"
  local global_idx=$(( global_offset + 1 ))
  _log_section "[$global_idx/$global_total] $title: $fn"
  ( "$fn" )
  local now elapsed
  now="$(_ms_now)"
  elapsed=$(( now - _SECTION_START ))
  printf '%b  (%d.%03ds)%b\n' "$_YELLOW" "$(( elapsed / 1000 ))" "$(( elapsed % 1000 ))" "$_RESET" >&2
}

# Skip a test with a reason.
skip_test() {
  _log_skip "$1: $2"
  _record_skip
}
