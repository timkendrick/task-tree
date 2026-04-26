---
title: "Implementation Plan"
created: 2026-04-26T08:25:17Z
updated: 2026-04-26T08:25:17Z
---
# Plan: Insert Frontmatter Labels in Correct Position

**Task:** `task/frontmatter-label-ordering-252d77b0`
**Parent:** `project/bootstrap-cli-d35756ce`
**Status:** IN-PROGRESS

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Codebase Research](#codebase-research)
3. [Decision Log](#decision-log)
4. [Implementation Plan](#implementation-plan)
5. [Task List](#task-list)

---

## Problem Statement

When adding a context to a task (`tt task context add`) or creating a new subtask (`tt task create`), the resulting `context:` / `subtask:` frontmatter entry is appended right before the closing `---`, without regard for the canonical field ordering.

**Canonical order** (being established by this task — not yet in DESIGN.md):
```
title:
status:
created:
updated:
label:
…
context:
…
subtask:
…
```

> **Note:** DESIGN.md §4 does not currently define a canonical field order. The existing
> §4.2 example even shows `context:` after `subtask:`, which this task corrects. This plan
> establishes `label → context → subtask` as the standard (matching `task/reorder`'s
> existing `write_task_file()`) and documents it in DESIGN.md as part of the work.

### Concrete failure cases

**Case A – context add on task with existing subtasks**

Before:
```markdown
---
title: "My Task"
status: TODO
created: 2025-01-01T00:00:00Z
updated: 2025-01-01T00:00:00Z
subtask: [ ] task/child-abc12345
---
```

After `tt task context add --title "Research" --slug "research"`:
```markdown
---
title: "My Task"
status: TODO
created: 2025-01-01T00:00:00Z
updated: 2025-01-01T01:00:00Z
subtask: [ ] task/child-abc12345
context: context/research-xyz12345        ← WRONG: context after subtask
---
```

Expected:
```markdown
---
title: "My Task"
status: TODO
created: 2025-01-01T00:00:00Z
updated: 2025-01-01T01:00:00Z
context: context/research-xyz12345        ← CORRECT: context before subtask
subtask: [ ] task/child-abc12345
---
```

**Case B – `rewrite_task_file()` in `task/edit` emits wrong order.**

The function currently emits: `label → subtask → context`.
Correct order: `label → context → subtask`.

---

## Codebase Research

### Relevant source files

| Path | Lines | Purpose |
|---|---|---|
| `scripts/cli/lib/common.sh` | 1128 | Shared library: `parse_task_frontmatter`, `parse_frontmatter_field`, etc. |
| `scripts/cli/task/edit` | 361 | `rewrite_task_file()` helper + edit command |
| `scripts/cli/task/reorder` | 471 | `write_task_file()` (already correct order) + reorder command |
| `scripts/cli/task/create` | 504 | `write_task_stub()`, `add_subtask_to_frontmatter()` |
| `scripts/cli/task/context/add` | 300 | Inline AWK to insert `context:` before `---` |
| `scripts/cli/task/checkin` | 516 | Inline AWK to insert `context:` before `---` during handoff |
| `scripts/cli/task/move` | 337 | Inline AWK to insert `subtask:` before `---` |
| `scripts/harness/harness.sh` | 1465 | Test assertion helpers |
| `scripts/test` | ~375 | Test runner — discovers `scripts/cli/**/*.test.sh` via `find` |

### All frontmatter-mutating sites (complete inventory)

| Site | What it does | Ordering bug? |
|---|---|---|
| `task/edit` `rewrite_task_file()` (lines 63–93) | Full rewrite: title/status/created/updated/labels/**subtasks/contexts** | **YES** — emits `label → subtask → context` |
| `task/reorder` `write_task_file()` (lines 55–72) | Full rewrite: title/status/created/updated/labels/contexts/subtasks | **No** — already correct order. Duplicate of edit's function. |
| `task/create` `write_task_stub()` (lines ~128–134) | Creates initial stub (no labels/contexts/subtasks) | No bug |
| `task/create` `add_subtask_to_frontmatter()` (lines 143–152) | Appends `subtask: [ ] task_id` before closing `---` | No immediate bug (subtask is always last), but fragile |
| `task/context/add` inline AWK (line 270) | Appends `context: ctx_id` before closing `---` | **YES** — if task has `subtask:` entries, context ends up after subtasks |
| `task/checkin` inline AWK (line 397) | Appends `context: ctx_id` before closing `---` in parent | **YES** — same as above |
| `task/move` inline AWK (line 272) | Appends `subtask: [ ] task_id` before closing `---` | No immediate bug (subtask is always last), but fragile |

### Existing harness assertions (relevant subset)

The harness already provides task-ID-based helpers that cover most needs:
- `assert_task_title`, `assert_task_status`, `assert_task_label`, `assert_task_no_label`
- `assert_frontmatter_field`, `assert_frontmatter_field_count`
- `assert_subtask_entry`, `assert_no_subtask_entry`
- `assert_context_entry`, `assert_no_context_entry`

**What's missing:** An assertion that validates frontmatter field ordering. All other assertions already exist.

### Existing `task/edit` caller verification

Lines 277–279 of `task/edit` correctly populate the env arrays before calling `rewrite_task_file`:
```bash
export REWRITE_LABELS=("${final_labels[@]+"${final_labels[@]}"}")
export REWRITE_SUBTASKS=("${current_subtasks[@]+"${current_subtasks[@]}"}")
export REWRITE_CONTEXTS=("${current_contexts[@]+"${current_contexts[@]}"}")
```
Three call sites (lines 293, 316, 331) all use the same pattern. Verified correct.

---

## Decision Log

| # | Question | Decision | Rationale |
|---|---|---|---|
| 1 | Where should shared helpers live? | `lib/common.sh` | Single shared location, already sourced by all CLI scripts |
| 2 | How to implement order-aware insertion? | Private `_insert_frontmatter_line()` inner helper with two public wrappers: `append_frontmatter_context`, `append_frontmatter_subtask` | DRY: shared AWK+tmpfile+mv plumbing; public wrappers encode semantic insertion points via regex `BEFORE_PATTERN`. |
| 3 | Should helpers update `updated:` timestamp? | **No** — helpers are pure. Separate `update_frontmatter_timestamp` helper. | Separation of concerns. Callers control when timestamps change. |
| 4 | Where should new tests live? | Unit tests in new `lib/common.test.sh`; ordering integration tests in existing per-command test files | Unit tests for AWK helper correctness; integration tests for end-to-end ordering. |
| 5 | How to assert frontmatter ordering? | Single AWK-based `assert_frontmatter_order` that validates structure + canonical key order | ~20 lines, not 100. Existing harness helpers cover everything else. |
| 6 | Replace existing `assert_task_*` helpers? | No — they're complementary (task-ID-based). Only add the ordering assertion. | No duplication. |
| 7 | Rename `write_task_file` → `rewrite_task_file`? | Yes — `write_task_file` in `reorder` becomes the shared version under the name `rewrite_task_file` | The `edit` version has the bug and is removed. `reorder`'s version is already correct and becomes canonical. |
| 8 | Should `rewrite_task_file` use atomic writes? | Yes — write to temp file + `mv` | All other helpers do this. Prevents file corruption on partial write. |
| 9 | How to handle pre-existing ordering violations in `append_frontmatter_context`? | Insert before first `subtask:` line. Document that it doesn't fix existing misordered contexts. | Future: `rewrite_task_file` normalizes order on full rewrites. Incremental inserts are best-effort. |

---

## Implementation Plan

### Overview of changes

1. **`scripts/harness/harness.sh`** — Add `assert_frontmatter_order` assertion.
2. **`scripts/cli/lib/common.sh`** — Add shared helpers: `rewrite_task_file()`, private `_insert_frontmatter_line()` with public wrappers `append_frontmatter_context()` and `append_frontmatter_subtask()`, plus `update_frontmatter_timestamp()`.
3. **`scripts/cli/task/edit`** — Remove local `rewrite_task_file()` (now in common.sh).
4. **`scripts/cli/task/reorder`** — Remove local `write_task_file()`, rename call sites to `rewrite_task_file`.
5. **`scripts/cli/task/context/add`** — Replace inline AWK with `append_frontmatter_context` + `update_frontmatter_timestamp`.
6. **`scripts/cli/task/checkin`** — Refactor to write string to disk first, then call `append_frontmatter_context`.
7. **`scripts/cli/task/create`** — Remove `add_subtask_to_frontmatter()`, replace call with `append_frontmatter_subtask`.
8. **`scripts/cli/task/move`** — Replace inline AWK with `append_frontmatter_subtask`.
9. **`scripts/cli/lib/common.test.sh`** — New file: unit tests for AWK helpers.
10. **Integration tests** — Add ordering tests to `context/add.test.sh`, `edit.test.sh`, `create.test.sh`, `checkin.test.sh`.
11. **`DESIGN.md`** — Fix §4.2 example ordering. Document canonical frontmatter field order.

---

### Step 1: Add `assert_frontmatter_order` to `harness.sh`

Add a single AWK-based assertion after the existing `assert_context_count` section. This validates both structure (proper `---` delimiters, valid `<key>: <value>` lines) and canonical key ordering.

```bash
# ---------------------------------------------------------------------------
# Frontmatter Ordering Assertion
# ---------------------------------------------------------------------------

# assert_frontmatter_order LABEL CONTENT
#
# Validates that CONTENT has a well-formed frontmatter block with fields in
# canonical order. Checks:
#   1. Starts with "---" and contains a second "---" closing delimiter.
#   2. Each frontmatter line matches the pattern: <known-key>: <value>
#      (known keys: title, status, created, updated, label, context, subtask)
#   3. All present fields appear in canonical order:
#      title < status < created < updated < label < context < subtask
#      (every occurrence of key A precedes every occurrence of key B)
#
# CONTENT is the raw file content (including `---` delimiters and body).
assert_frontmatter_order() {
  local label="$1" content="$2"
  local result
  result="$(printf '%s' "$content" | awk '
    BEGIN {
      # Canonical ordering: lower rank = earlier in file
      split("title,status,created,updated,label,context,subtask", _keys, ",")
      for (_i = 1; _i <= length(_keys); _i++) rank[_keys[_i]] = _i
      n_keys = length(_keys)
      prev_rank = 0
      errors = 0
      sep = 0
    }
    /^---$/ {
      sep++
      if (sep == 2) { if (errors == 0) print "ok"; exit }
      next
    }
    sep == 1 {
      # Validate line format: must be <known-key>: <value>
      k = $0; sub(/:.*$/, "", k)
      if (!(k in rank)) {
        print "unknown key: " k " at line " NR
        errors++
        next
      }
      r = rank[k]
      if (r < prev_rank) {
        print "ordering violation: " k " (rank " r ") after rank " prev_rank " at line " NR
        errors++
      }
      prev_rank = r
    }
    END { if (sep < 2 && errors == 0) { print "missing closing ---"; exit 1 } }
  ')" || true
  if [[ "$result" == "ok" ]]; then
    _log_pass "$label"
    _record_pass
  else
    _log_fail "$label: $result"
    _record_fail "$label: $result"
  fi
}
```

This replaces the plan's original ~100-line `assert_frontmatter_syntax` plus 5 redundant helpers. The existing harness helpers (`assert_task_title`, `assert_subtask_entry`, etc.) cover all other assertions.

---

### Step 2a: Add `rewrite_task_file()` to `common.sh`

Add near the end of the "Task frontmatter parsing" section (after `parse_task_frontmatter`, around line 930), before the "Transaction management" section.

Based on `task/reorder`'s `write_task_file()` which already has the correct field order: `title → status → created → updated → label → context → subtask`.

```bash
# ---------------------------------------------------------------------------
# rewrite_task_file FILE TITLE STATUS BODY CREATED
#
# Rewrites FILE with canonical frontmatter followed by BODY.
# Arrays REWRITE_LABELS, REWRITE_CONTEXTS, REWRITE_SUBTASKS must be set by
# the caller as environment variables before calling this function.
#
# Canonical field order: title, status, created, updated, label…, context…, subtask…
# The 'updated' timestamp is generated fresh on each call.
# Writes to a temp file and renames for atomicity.
rewrite_task_file() {
  local file="$1"
  local title="$2"
  local status="$3"
  local body="$4"
  local created="$5"

  local updated
  updated="$(generate_timestamp)"

  local tmpfile
  tmpfile="$(mktemp)"
  {
    echo '---'
    echo "title: \"${title//\"/\\\"}\""
    echo "status: $status"
    echo "created: $created"
    echo "updated: $updated"
    for lbl in "${REWRITE_LABELS[@]+"${REWRITE_LABELS[@]}"}"; do
      echo "label: $lbl"
    done
    for ctx in "${REWRITE_CONTEXTS[@]+"${REWRITE_CONTEXTS[@]}"}"; do
      echo "context: $ctx"
    done
    for st in "${REWRITE_SUBTASKS[@]+"${REWRITE_SUBTASKS[@]}"}"; do
      echo "subtask: $st"
    done
    echo '---'
    if [[ -n "$body" ]]; then
      printf '%s\n' "$body"
    fi
  } > "$tmpfile"
  mv "$tmpfile" "$file"
}
```

---

### Step 2b/2c: Add `_insert_frontmatter_line()` + public wrappers to `common.sh`

```bash
# ---------------------------------------------------------------------------
# _insert_frontmatter_line FILE LINE_TO_INSERT [BEFORE_PATTERN]
#
# Shared implementation for inserting a line into YAML frontmatter.
# Inserts LINE_TO_INSERT at the correct position:
#   - If BEFORE_PATTERN is given: before the first line matching that pattern
#     within the frontmatter block.
#   - If omitted: before the closing --- separator.
# Uses temp file + mv for atomicity.
_insert_frontmatter_line() {
  local file="$1" line="$2" before="${3:-}"
  local tmpfile
  tmpfile="$(mktemp)"
  awk -v ins="$line" -v bef="$before" '
    BEGIN { sep=0; inserted=0 }
    /^---$/ {
      sep++
      if (sep == 2 && !inserted) { print ins; inserted=1 }
      print; next
    }
    sep == 1 && bef != "" && !inserted && $0 ~ bef {
      print ins; inserted=1
    }
    { print }
  ' "$file" > "$tmpfile"
  mv "$tmpfile" "$file"
}

# append_frontmatter_context FILE CTX_ID
#
# Appends a 'context: CTX_ID' line before the first 'subtask:' line
# (or before the closing '---' if no subtask entries exist).
# Does not update the 'updated:' timestamp — call update_frontmatter_timestamp
# separately if needed.
append_frontmatter_context() {
  _insert_frontmatter_line "$1" "context: $2" "^subtask:"
}

# append_frontmatter_subtask FILE TASK_ID
#
# Appends a 'subtask: [ ] TASK_ID' line before the closing '---' separator
# (after any existing context: or subtask: entries).
append_frontmatter_subtask() {
  _insert_frontmatter_line "$1" "subtask: [ ] $2" ""
}
```

---

### Step 2c: Add `update_frontmatter_timestamp()` to `common.sh`

Updates the `updated:` field in-place.

```bash
# update_frontmatter_timestamp FILE TIMESTAMP
#
# Updates the 'updated:' field in the frontmatter of FILE to TIMESTAMP.
# Uses temp file + mv for atomicity.
update_frontmatter_timestamp() {
  local file="$1"
  local ts="$2"
  local tmpfile
  tmpfile="$(mktemp)"
  awk -v ts="$ts" '
    BEGIN { sep=0 }
    /^---$/ { sep++; print; next }
    sep == 1 && /^updated:/ { print "updated: " ts; next }
    { print }
  ' "$file" > "$tmpfile"
  mv "$tmpfile" "$file"
}
```

---

### Step 3: Update `task/edit`

**Remove** the local `rewrite_task_file()` definition (lines 55–93) from `task/edit`. The function will be inherited from `common.sh` (already sourced at the top of the script).

The fix is entirely in the shared `rewrite_task_file()` in `common.sh` (correct order: `label → context → subtask`). The three call sites (lines 293, 316, 331) correctly populate the env arrays and need no changes.

**Note:** `task_file_changed()` is only used by `edit` and stays in `edit`.

---

### Step 4: Update `task/reorder`

**Remove** the local `write_task_file()` definition (lines 52–72) from `task/reorder`. Replace both call sites with `rewrite_task_file`:

1. `reorder_subtask()` — `write_task_file "$parent_worktree/$parent_task_file" ...` → `rewrite_task_file ...`
2. `reorder_frontmatter()` — `write_task_file "$canonical_worktree/$task_file" ...` → `rewrite_task_file ...`

No behavioral change — the shared function has the same signature and same (correct) field order.

---

### Step 5: Update `task/context/add`

Replace the inline AWK at lines 268–273 with the shared helpers:

**Before:**
```bash
  updated_task_content="$(printf '%s' "$task_content" | awk -v ctx="$ctx_id" -v ts="$ctx_ts" '
    /^---$/ { sep++; if (sep == 2) { print "context: " ctx } }
    /^updated:/ && sep == 1 { print "updated: " ts; next }
    { print }
  ')"

  printf '%s\n' "$updated_task_content" > "$task_file_path_on_disk"
```

**After:**
```bash
  append_frontmatter_context "$task_file_path_on_disk" "$ctx_id"
  update_frontmatter_timestamp "$task_file_path_on_disk" "$ctx_ts"
```

The variable `task_content` (line 265: `task_content="$(cat "$task_file_path_on_disk")"`) is no longer needed for this step. Check whether it's used elsewhere in the function before removing it.

---

### Step 6: Update `task/checkin`

The checkin code builds `updated_parent_content` as a string (mutating the subtask checkbox), then optionally appends a context entry via inline AWK, then writes the final string to disk.

**Before** (simplified):
```bash
  # (1) Build updated_parent_content as a string — mutates the subtask checkbox
  updated_parent_content="$(printf '%s' "$parent_task_content" | awk ...)"

  # (2) If --context: append context entry to the string
  if [[ -n "$context_text" ]]; then
    # ... write ctx file to disk ...
    updated_parent_content="$(printf '%s' "$updated_parent_content" | awk -v ctx="$ctx_id" '
      /^---$/ { sep++; if (sep == 2) { print "context: " ctx } }
      { print }
    ')"
  fi

  # (3) Write the final string to disk
  printf '%s\n' "$updated_parent_content" > "$target_ws/$parent_task_file"
```

**After:**
```bash
  # (1) Build updated_parent_content as a string — unchanged
  updated_parent_content="$(printf '%s' "$parent_task_content" | awk ...)"

  # (2) Write to disk (always, before any in-place mutations)
  printf '%s\n' "$updated_parent_content" > "$target_ws/$parent_task_file"

  # (3) If --context: create ctx file and insert context entry in correct position
  if [[ -n "$context_text" ]]; then
    # ... write ctx file to disk (unchanged) ...
    append_frontmatter_context "$target_ws/$parent_task_file" "$ctx_id"
    log "Created context file: $ctx_file"
  fi
```

This moves the final disk write **before** the `if` block and replaces the inline AWK with `append_frontmatter_context`. The helpers operate on the file directly, so the string → file → mutate → done flow is clean.

---

### Step 7: Update `task/create`

Replace the local `add_subtask_to_frontmatter()` function (lines 143–152) with a call to the shared `append_frontmatter_subtask()` from `common.sh`.

The function is called once at line ~439:
```bash
add_subtask_to_frontmatter "$parent_path" "$task_id"
```
→
```bash
append_frontmatter_subtask "$parent_path" "$task_id"
```

Delete the function definition (lines 140–152).

---

### Step 8: Update `task/move`

Replace the inline AWK at lines 271–275:

**Before:**
```bash
  awk -v task_id="$task_id" '
    /^---$/ { sep++; if (sep == 2) { print "subtask: [ ] " task_id } }
    { print }
  ' "$repo/$new_parent_task_file" > "$tmpfile2"
  mv "$tmpfile2" "$repo/$new_parent_task_file"
```

**After:**
```bash
  append_frontmatter_subtask "$repo/$new_parent_task_file" "$task_id"
```

(The `tmpfile2` variable is no longer needed.)

---

### Step 9: Create `scripts/cli/lib/common.test.sh`

Unit tests for the AWK helpers. Each test constructs an input file directly, calls the helper, and asserts the result.

```bash
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

# Helper: create a temp task file with the given frontmatter + body
_make_task_file() {
  local path="$1"; shift
  {
    echo '---'
    for line in "$@"; do echo "$line"; done
    echo '---'
  } > "$path"
}

# --- append_frontmatter_context ---

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
  ctx_line="$(printf '%s' "$content" | grep -n '^context:' | cut -d: -f1 | head -1)"
  sub_line="$(printf '%s' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "context line before subtask line" "$([[ "$ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
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
  last_ctx_line="$(printf '%s' "$content" | grep -n '^context:' | cut -d: -f1 | tail -1)"
  sub_line="$(printf '%s' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "last context before first subtask" "$([[ "$last_ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
}

# --- append_frontmatter_subtask ---

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
  ctx_line="$(printf '%s' "$content" | grep -n '^context:' | cut -d: -f1 | head -1)"
  sub_line="$(printf '%s' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "context before subtask" "$([[ "$ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
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

# --- update_frontmatter_timestamp ---

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

# --- rewrite_task_file ---

test_rewrite_task_file__canonical_order() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  REWRITE_LABELS=("bug" "feature")
  REWRITE_CONTEXTS=("context/ctx1-aaa11111" "context/ctx2-bbb22222")
  REWRITE_SUBTASKS=("[ ] task/child-abc12345" "[x] task/child-def67890")

  rewrite_task_file "$file" "My Task" "IN-PROGRESS" "Task body here." "2025-01-01T00:00:00Z"

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

test_rewrite_task_file__atomic_write() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  # Write an initial file
  _make_task_file "$file" "title: \"Old\""

  REWRITE_LABELS=()
  REWRITE_CONTEXTS=()
  REWRITE_SUBTASKS=()

  rewrite_task_file "$file" "New Title" "TODO" "" "2025-01-01T00:00:00Z"

  local content
  content="$(cat "$file")"
  assert_contains "title updated" "$content" "title: \"New Title\""

  unset REWRITE_LABELS REWRITE_CONTEXTS REWRITE_SUBTASKS
}

run_tests "tt lib/common (unit)"
```

---

### Step 10: Add ordering integration tests to existing test files

These test the full `tt` pipeline to verify that commands produce correctly-ordered frontmatter.

#### `context/add.test.sh` — add:

```bash
test_context_add__context_inserted_before_subtask() {
  setup_workspace "ctxadd-order"
  proj_id=$(create_project "proj" "Project")
  checkout_task "$proj_id" >/dev/null
  task_id=$(create_task "t" "T")
  checkout_task "$task_id" >/dev/null

  # Create a child so task has a subtask: entry
  run_tt task create --slug "child" --title "Child" <<< "" >/dev/null 2>&1
  checkout_task "$task_id" >/dev/null

  # Add context — must appear before the subtask entry
  echo "Body" | run_tt task context add --title "Research" --slug "research" >/dev/null 2>&1

  content="$(read_task_file "$task_id")"
  assert_frontmatter_order "valid order after context add on task with subtask" "$content"
}
```

#### `edit.test.sh` — add:

```bash
test_task_edit__frontmatter_canonical_order() {
  setup_workspace "edit-order"
  proj_id=$(create_project "proj" "Project")
  checkout_task "$proj_id" >/dev/null
  task_id=$(create_task "t" "T")
  checkout_task "$task_id" >/dev/null

  # Add a label, create a subtask and add context to maximally populate frontmatter
  run_tt task edit --label "bug" <<< "" >/dev/null 2>&1
  child_id=$(run_tt task create --slug "child" --title "Child" <<< "" 2>/dev/null | tail -1)
  checkout_task "$task_id" >/dev/null
  echo "Body" | run_tt task context add --title "Ctx" --slug "ctx" >/dev/null 2>&1

  # Run edit to trigger rewrite_task_file
  run_tt task edit --title "Updated T" <<< "" >/dev/null 2>&1

  content="$(read_task_file "$task_id")"
  assert_frontmatter_order "canonical order after edit" "$content"
}
```

#### `create.test.sh` — add:

```bash
test_task_create__subtask_after_existing_context() {
  setup_workspace "create-subtask-order"
  proj_id=$(create_project "proj" "Project")
  checkout_task "$proj_id" >/dev/null
  task_id=$(create_task "parent" "Parent")
  checkout_task "$task_id" >/dev/null

  # Add a context to parent first
  echo "Body" | run_tt task context add --title "Research" --slug "research" >/dev/null 2>&1

  # Now create a child — the subtask entry must appear after the context entry
  child_id=$(run_tt task create --slug "child" --title "Child" <<< "" 2>/dev/null | tail -1)

  content="$(read_task_file "$task_id")"
  assert_frontmatter_order "canonical order after subtask added to parent with context" "$content"
}
```

#### `checkin.test.sh` — add:

```bash
test_task_checkin__context_before_subtask_in_parent() {
  setup_workspace "checkin-ctx-order"
  proj_id=$(create_project "proj" "Project")
  checkout_task "$proj_id" >/dev/null
  task_id=$(create_task "parent" "Parent")
  checkout_task "$task_id" >/dev/null

  # Create two children
  child_a=$(run_tt task create --slug "ca" --title "Child A" <<< "" 2>/dev/null | tail -1)
  child_b=$(run_tt task create --slug "cb" --title "Child B" <<< "" 2>/dev/null | tail -1)

  # Check in child_a with --context (adds context: entry to parent)
  checkout_task "$child_a" >/dev/null
  run_tt task checkin --complete --context "Handoff notes" "$child_a" >/dev/null 2>&1
  checkout_task "$task_id" >/dev/null

  content="$(read_task_file "$task_id")"
  assert_frontmatter_order "valid order after checkin with --context" "$content"
}
```

---

### Step 11: Fix `DESIGN.md`

Two changes needed:

**11a. Fix the §4.2 example** — move `context:` entries before `subtask:` entries:

The current in-progress example (around lines 116–148) shows:
```markdown
subtask: [ ] task/plan-feature-9fdbbd60
...
context: context/initial-research-ab3243f0
context: context/provider-comparison-7f8e2d1a
---
```

Change to:
```markdown
context: context/initial-research-ab3243f0
context: context/provider-comparison-7f8e2d1a
subtask: [ ] task/plan-feature-9fdbbd60
...
---
```

**11b. Add canonical ordering note** after the frontmatter examples in §4.2:

```markdown
**Canonical frontmatter field order.** All task files must use the following
canonical field ordering within the frontmatter block:

```
title:       (required, exactly one)
status:      (required, exactly one)
created:     (required, exactly one)
updated:     (required, exactly one)
label:       (zero or more; each on its own line)
context:     (zero or more; each on its own line)
subtask:     (zero or more; each on its own line)
```

All tool commands that mutate task file frontmatter maintain this ordering
automatically. The `rewrite_task_file` shared helper normalizes ordering on
full rewrites; `append_frontmatter_context` and `append_frontmatter_subtask`
insert at the correct position for incremental mutations.
```

---

### Step 12: Verify test runner discovers new test file

The test runner (`scripts/test`, line 77) uses:
```bash
find "$SCRIPT_DIR/cli" -name '*.test.sh' -type f | sort
```

This will discover `scripts/cli/lib/common.test.sh`. No changes to the test runner needed.

---

## Task List

- [ ] **Checkpoint**: Create a VCS checkpoint before starting.
- [ ] **Step 1**: Add `assert_frontmatter_order` to `scripts/harness/harness.sh`.
- [ ] **Step 2a**: Add `rewrite_task_file()` to `scripts/cli/lib/common.sh` (correct order: label → context → subtask, atomic write).
- [ ] **Step 2b**: Add `_insert_frontmatter_line()` + `append_frontmatter_context()` + `append_frontmatter_subtask()` to `scripts/cli/lib/common.sh`.
- [ ] **Step 2c**: Add `update_frontmatter_timestamp()` to `scripts/cli/lib/common.sh`.
- [ ] **Step 3**: Remove local `rewrite_task_file()` from `scripts/cli/task/edit`.
- [ ] **Step 4**: Remove local `write_task_file()` from `scripts/cli/task/reorder`, rename call sites to `rewrite_task_file`.
- [ ] **Step 5**: Replace inline AWK in `scripts/cli/task/context/add` with `append_frontmatter_context` + `update_frontmatter_timestamp`.
- [ ] **Step 6**: Refactor `scripts/cli/task/checkin` — write string to disk first, then call `append_frontmatter_context`.
- [ ] **Step 7**: Remove `add_subtask_to_frontmatter()` from `scripts/cli/task/create`, replace call with `append_frontmatter_subtask`.
- [ ] **Step 8**: Replace inline AWK in `scripts/cli/task/move` with `append_frontmatter_subtask`.
- [ ] **Step 9**: Create `scripts/cli/lib/common.test.sh` with unit tests for AWK helpers.
- [ ] **Step 10a**: Add `test_context_add__context_inserted_before_subtask` to `context/add.test.sh`.
- [ ] **Step 10b**: Add `test_task_edit__frontmatter_canonical_order` to `edit.test.sh`.
- [ ] **Step 10c**: Add `test_task_create__subtask_after_existing_context` to `create.test.sh`.
- [ ] **Step 10d**: Add `test_task_checkin__context_before_subtask_in_parent` to `checkin.test.sh`.
- [ ] **Step 11a**: Fix `DESIGN.md` §4.2 example to show `context:` before `subtask:`.
- [ ] **Step 11b**: Add canonical ordering note to `DESIGN.md` §4.2.
- [ ] **Diagnostics**: Run all affected test suites and verify they pass.
- [ ] **Checkpoint**: Create a final VCS checkpoint.
