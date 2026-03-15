#!/usr/bin/env bash
# test-migration.sh — Test the migrate-task-files.sh script on a real snapshot
# of the repository's task files.
#
# Strategy: invokes the migration script with --workspace <tmpdir>
# --revision <feature-branch>, which:
#   1. Checks that the feature branch is an ancestor of the test bookmark
#      (ensuring the test bookmark has the correct migration script)
#   2. Creates an isolated jj workspace checked out at the test bookmark
#   3. Runs the migration against the flat task files found there
#   4. With --retain-workspace, leaves the workspace intact for assertions
#
# This script captures the workspace name from stdout, runs assertions
# against the files on disk, then cleans up.
#
# The main workspace is completely untouched throughout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATE="$SCRIPT_DIR/migrate-task-files.sh"
TEST_BOOKMARK="task/test-migration-baa44d0f"
FEATURE_BRANCH="task/standalone-context-files-cf299caa"

PASS=0
FAIL=0
ERRORS=()

pass() { PASS=$((PASS + 1)); printf '  ✓ %s\n' "$1" >&2; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1"); printf '  ✗ %s\n' "$1" >&2; }
section() { printf '\n=== %s ===\n' "$1" >&2; }

TMPDIR_WS="$(mktemp -d)"
WS_NAME=''

cleanup() {
  printf '\n=== Cleanup ===\n' >&2
  if [[ -n "$WS_NAME" ]]; then
    jj -R "$REPO_DIR" workspace forget "$WS_NAME" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_WS"
  printf 'Cleaned up: %s\n' "$TMPDIR_WS" >&2
}
trap 'cleanup' EXIT

# ---------------------------------------------------------------------------
# Run migration
# stdout = workspace name; all other output goes to stderr via log()
# --retain-workspace keeps the temp dir alive for our assertions below
# ---------------------------------------------------------------------------
section "Running migration"
WS_NAME=$(bash "$MIGRATE" \
  --repo "$REPO_DIR" \
  --workspace "$TMPDIR_WS" \
  --revision "$FEATURE_BRANCH" \
  --retain-workspace \
  "$TEST_BOOKMARK")
printf 'Migration complete. Workspace name: %s\n' "$WS_NAME" >&2

# ---------------------------------------------------------------------------
# Post-migration checks
#
# The migration committed to $TEST_BOOKMARK and advanced the workspace WC
# past it. Files on disk in $TMPDIR_WS reflect the migrated state.
# We also verify via jj's recorded tree using --ignore-working-copy.
# ---------------------------------------------------------------------------
section "Post-migration checks"

# Helper: list files tracked at a revision.
# Note: jj file list outputs absolute paths when run against a non-root workspace
# directory, so we always use the main repo root (-R "$REPO_DIR") which shares
# the same commit history and outputs repo-relative paths.
list_files_at() {
  jj -R "$REPO_DIR" --ignore-working-copy file list -r "$1" 2>/dev/null
}

MIGRATED_REV="$TEST_BOOKMARK"

# 1. Old flat .md files must be gone from the migrated commit
old_flat_files=$(list_files_at "$MIGRATED_REV" | grep -E '^\.tt/task/[^/]+\.md$' || true)
if [[ -z "$old_flat_files" ]]; then
  pass "No old flat .md files remain at $MIGRATED_REV"
else
  fail "Old flat files still present: $(printf '%s' "$old_flat_files" | tr '\n' ' ' | cut -c1-120)"
fi

# 2. New TASK.md files exist in subdirectories
task_md_files=$(list_files_at "$MIGRATED_REV" | grep -E '^\.tt/task/[^/]+/TASK\.md$' || true)
task_md_count=0
[[ -n "$task_md_files" ]] && task_md_count=$(printf '%s\n' "$task_md_files" | wc -l | tr -d ' ')
if [[ "$task_md_count" -ge 40 ]]; then
  pass "New TASK.md files exist ($task_md_count task directories)"
else
  fail "Expected >=40 TASK.md files, got $task_md_count"
fi

# 3. Context files created for bootstrap-cli-d35756ce (has 2 context chunks)
ctx_files=$(list_files_at "$MIGRATED_REV" \
  | grep -E '^\.tt/task/bootstrap-cli-d35756ce/context/.*\.md$' || true)
ctx_count=0
[[ -n "$ctx_files" ]] && ctx_count=$(printf '%s\n' "$ctx_files" | wc -l | tr -d ' ')
if [[ "$ctx_count" -ge 2 ]]; then
  pass "Context files created for bootstrap-cli-d35756ce ($ctx_count files)"
else
  fail "Expected >=2 context files for bootstrap-cli-d35756ce, got $ctx_count"
fi

# 4. TASK.md content checks for bootstrap-cli-d35756ce
task_md_path="$TMPDIR_WS/.tt/task/bootstrap-cli-d35756ce/TASK.md"
if [[ -f "$task_md_path" ]]; then
  pass "bootstrap-cli-d35756ce/TASK.md exists on disk"
  task_content=$(cat "$task_md_path")

  # 4a. context: entries in frontmatter
  ctx_entries=$(printf '%s\n' "$task_content" | grep -c '^context:' || true)
  if [[ "$ctx_entries" -ge 2 ]]; then
    pass "TASK.md has $ctx_entries context: frontmatter entries"
  else
    fail "TASK.md has too few context: entries ($ctx_entries, expected >=2)"
  fi

  # 4b. No description: field (promoted to body)
  if ! printf '%s\n' "$task_content" | grep -q '^description:'; then
    pass "TASK.md has no description: frontmatter field"
  else
    fail "TASK.md still has description: frontmatter field"
  fi

  # 4c. created: and updated: fields present
  if printf '%s\n' "$task_content" | grep -q '^created:'; then
    pass "TASK.md has created: field"
  else
    fail "TASK.md missing created: field"
  fi
  if printf '%s\n' "$task_content" | grep -q '^updated:'; then
    pass "TASK.md has updated: field"
  else
    fail "TASK.md missing updated: field"
  fi

  # 4d. Body non-empty (description was JSON-decoded and promoted)
  body=$(printf '%s\n' "$task_content" \
    | awk '/^---$/{n++; if(n==2){found=1; next}} found{print}')
  if [[ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ]]; then
    pass "TASK.md has non-empty body (description promoted from frontmatter)"
  else
    fail "TASK.md body is empty — description not promoted"
  fi
else
  fail "bootstrap-cli-d35756ce/TASK.md missing from disk"
fi

# 5. Context file content checks
first_ctx_dir="$TMPDIR_WS/.tt/task/bootstrap-cli-d35756ce/context"
if [[ -d "$first_ctx_dir" ]]; then
  first_ctx_file=$(find "$first_ctx_dir" -name '*.md' -type f | sort | head -1)
  if [[ -n "$first_ctx_file" && -f "$first_ctx_file" ]]; then
    ctx_content=$(cat "$first_ctx_file")

    if printf '%s\n' "$ctx_content" | grep -q '^title:'; then
      pass "Context file has title: field"
    else
      fail "Context file missing title: field ($first_ctx_file)"
    fi
    if printf '%s\n' "$ctx_content" | grep -q '^created:'; then
      pass "Context file has created: field"
    else
      fail "Context file missing created: field ($first_ctx_file)"
    fi
    if printf '%s\n' "$ctx_content" | grep -q '^updated:'; then
      pass "Context file has updated: field"
    else
      fail "Context file missing updated: field ($first_ctx_file)"
    fi

    ctx_body=$(printf '%s\n' "$ctx_content" \
      | awk '/^---$/{n++; if(n==2){found=1; next}} found{print}')
    if [[ -n "$(printf '%s' "$ctx_body" | tr -d '[:space:]')" ]]; then
      pass "Context file has non-empty body"
    else
      fail "Context file has empty body ($first_ctx_file)"
    fi
  else
    fail "No context .md files found in $first_ctx_dir"
  fi
else
  fail "Context directory missing: $first_ctx_dir"
fi

# 6. Bookmark was advanced to a new commit
original_commit="11a51373"
migrated_commit=$(jj -R "$TMPDIR_WS" --ignore-working-copy \
  log -r "$TEST_BOOKMARK" --no-graph \
  -T 'commit_id.short(8) ++ "\n"' 2>/dev/null | head -1)
if [[ "$migrated_commit" != "$original_commit" ]]; then
  pass "Bookmark advanced to new commit ($migrated_commit)"
else
  fail "Bookmark still at original commit — migration may not have committed"
fi

# 7. Migration commit message
commit_msg=$(jj -R "$TMPDIR_WS" --ignore-working-copy \
  log -r "$TEST_BOOKMARK" --no-graph \
  -T 'description ++ "\n"' 2>/dev/null | head -1)
if [[ "$commit_msg" == *"Migrate task files to directory format"* ]]; then
  pass "Migration commit has expected message"
else
  fail "Unexpected commit message: '$commit_msg'"
fi

# 8. Simple task (no context chunks) migrated correctly
simple_task_path="$TMPDIR_WS/.tt/task/zsh-completions-0538e4f5/TASK.md"
if [[ -f "$simple_task_path" ]]; then
  simple_content=$(cat "$simple_task_path")
  if printf '%s\n' "$simple_content" | grep -q '^status:'; then
    pass "Simple task (zsh-completions) has status: field"
  else
    fail "Simple task TASK.md missing status: field"
  fi
  if [[ ! -d "$TMPDIR_WS/.tt/task/zsh-completions-0538e4f5/context" ]]; then
    pass "Simple task has no context/ directory (none expected)"
  else
    ctx_count_simple=$(find "$TMPDIR_WS/.tt/task/zsh-completions-0538e4f5/context" \
      -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$ctx_count_simple" -eq 0 ]]; then
      pass "Simple task context/ directory is empty"
    else
      fail "Simple task unexpectedly has $ctx_count_simple context file(s)"
    fi
  fi
else
  fail "Simple task TASK.md missing: $simple_task_path"
fi

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
section "Results"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL" >&2

if [[ "$FAIL" -gt 0 ]]; then
  printf '\nFailed checks:\n' >&2
  for err in "${ERRORS[@]}"; do
    printf '  ✗ %s\n' "$err" >&2
  done
  printf '\nTo inspect the migrated workspace manually, re-run with --retain-workspace\n' >&2
  printf 'and remove the cleanup trap, then explore: %s\n' "$TMPDIR_WS" >&2
  exit 1
else
  printf '\nAll checks passed!\n' >&2
fi
