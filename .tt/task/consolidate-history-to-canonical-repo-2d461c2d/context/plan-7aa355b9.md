---
title: "Implementation plan"
created: 2026-04-24T09:48:03Z
updated: 2026-04-24T09:48:03Z
---
# Plan: Consolidate transaction history to canonical repo via .jj/repo pointer

## Overview

The `.tt/history` transaction log is currently written to whatever directory `resolve_repo` returns, which is the **worktree root** when invoked from inside a secondary jj workspace with `TT_REPO` unset. This causes two failures in the `worktree/delete` tests and is semantically wrong: jj shares a single operation log across all workspaces, so `tt`'s history should also be singular and live only in the **canonical** repo root.

---

## Background and Research

### jj workspace model (confirmed via official docs)

From the jj docs (https://docs.jj-vcs.dev/latest/glossary):
> Each workspace has a `.jj/` directory, but the **commits and operations will be stored in the initial workspace**; the other workspaces will have pointers to the initial workspace.

Concretely:
- **Canonical repo**: `.jj/repo` is a **directory** (the actual op/commit store).
- **Secondary workspace**: `.jj/repo` is a **file** containing a relative path back to the canonical repo's `.jj/repo` directory (e.g. `../../../../repo/.jj/repo`).
- `jj -R <any-workspace> op log` returns **identical operation IDs** regardless of which workspace path is used, because they all share the same op store. This means `get_jj_op_id` can safely be called on any workspace path — the result is always the same.

### Root cause of the failures

`find_repo_root` walks up from CWD looking for the first directory containing `.jj/`. Secondary workspaces have `.jj/` too, so when `TT_REPO` is unset and CWD is inside a secondary workspace, `resolve_repo` returns the worktree path. All downstream code — including the transaction functions — derives the history file as `$repo/.tt/history`, landing in a per-worktree location.

This causes two concrete failures in `worktree/delete` tests:

1. **`test_worktree_delete__transaction_succeeds`** — setup step (`run_tt_in_worktree ... task complete`) writes history to the *worktree's* `.tt/history`; `worktree delete` (via `run_tt` with `TT_REPO`) writes to the *canonical repo's* `.tt/history`. Chain check sees a gap.

2. **`test_worktree_delete__transaction_succeeds_from_worktree`** — `run_tt_in_worktree` unsets `TT_REPO`, so `resolve_repo` returns the worktree path. `tt_begin_transaction` writes the in-progress entry to `$worktree/.tt/history`. Then `forget_worktree` deletes the worktree entirely. `tt_commit_transaction` tries to `sed -i` the now-deleted history file → exits non-zero → command fails.

### Why re-resolving at commit/rollback time doesn't work

The natural fix — resolve the canonical history file path via the `.jj/repo` pointer at commit/rollback time — fails because `forget_worktree` **deletes the entire worktree directory** before `tt_commit_transaction` is called. By the time commit runs, `$worktree/.jj/repo` no longer exists, so the pointer can't be followed.

### Agreed solution

Resolve the canonical history file path **once, at `tt_begin_transaction` time**, when the worktree still exists, and store it in `_TT_TRANSACTION_OWNER` (repurposed from a boolean `true` flag to hold the resolved history file path). Commit and rollback read `_TT_TRANSACTION_OWNER` directly instead of re-resolving.

Since all jj workspaces share the same op log, the `jj -R "$repo"` calls in commit (for `get_jj_op_id`) and rollback (for `jj op restore`) are valid from any workspace path — but since `$repo` may be deleted by the time they run, the canonical repo path is derived at commit/rollback time via `find_repo_root` walking up from the history file's directory (which is always inside the canonical repo and always exists).

---

## Files to Change

| File | Change |
|------|--------|
| `scripts/cli/lib/common.sh` | Add `resolve_history_repo` + `resolve_history_file_location` helpers; rewrite three transaction functions; update block comment |
| `scripts/cli/task/checkout` | Remove `init_tt_history "$target_worktree"` call (already partially applied) |
| `scripts/cli/history/undo` | Replace hardcoded `"$repo/.tt/history"` with `resolve_history_file_location` |
| `scripts/cli/history/unlock` | Replace hardcoded `"$repo/.tt/history"` with `resolve_history_file_location` |
| `scripts/cli/worktree/delete.test.sh` | Add `assert_history_integrity` to both transaction test scenarios |
| `DESIGN.md` | Update §6.12.1 to document the canonical-repo-only history and the pointer-following mechanism |

---

## Detailed Implementation

### 1. `scripts/cli/lib/common.sh` — Transaction section rewrite

#### 1a. Block comment

Replace the existing transaction block comment to document the canonical-repo-only invariant:

```bash
# ---------------------------------------------------------------------------
# Transaction management
#
# A "transaction" records the jj operation ID before and after a mutating tt
# command, enabling `tt history undo` to restore the repository state.
#
# Log file: <canonical-repo>/.tt/history
# Format:   one line per transaction: <before-op-id>:<after-op-id>
#           An in-progress transaction has an empty after-op-id: <before-op-id>:
#
# History location: the history file always lives in the **canonical** jj repo
# root (the repo whose .jj/repo entry is a directory, not a pointer file).
# Secondary jj workspaces have a .jj/repo *file* containing a relative path
# back to the canonical repo's .jj/repo directory. resolve_history_repo
# follows that pointer so all workspaces share a single history file.
#
# Nesting: sub-commands invoked by a top-level command inherit TT_TRANSACTION_ID
# via the environment. tt_begin_transaction is a no-op when TT_TRANSACTION_ID is
# already set. The internal (non-exported) _TT_TRANSACTION_OWNER variable
# stores the resolved history file path for the owning process; it is not
# exported so sub-processes never inherit it (they are not the transaction owner).
# ---------------------------------------------------------------------------
```

#### 1b. `resolve_history_repo` helper

```bash
# Usage: resolve_history_repo REPO
# Returns the canonical repo root for history file location.
# If REPO is a secondary jj workspace (.jj/repo is a pointer file),
# follows the pointer to find the canonical repo root.
# If REPO is already the canonical repo (.jj/repo is a directory), returns REPO.
resolve_history_repo() {
  local repo="$1"
  local repo_entry="$repo/.jj/repo"
  if [[ -f "$repo_entry" ]]; then
    # Secondary workspace: .jj/repo is a file containing a relative path to
    # the canonical repo's .jj/repo directory (e.g. "../../../../repo/.jj/repo").
    local target
    target="$(cd "$repo/.jj" && realpath "$(cat "$repo_entry")")" \
      || { log "Error: Could not resolve canonical repo from $repo_entry"; return 1; }
    # target = /path/to/canonical/.jj/repo — strip /.jj/repo to get repo root
    dirname "$(dirname "$target")"
  else
    # Canonical repo: .jj/repo is a directory (the actual op store)
    printf '%s' "$repo"
  fi
}
```

#### 1c. `resolve_history_file_location` semantic helper

```bash
# Usage: resolve_history_file_location REPO
# Returns the path to the .tt/history file for REPO.
# Follows .jj/repo pointer files so secondary jj workspaces resolve to the
# canonical repo's history file rather than a per-worktree copy.
# Canonical repos return <repo>/.tt/history directly.
resolve_history_file_location() {
  local repo="$1"
  local canonical_repo
  canonical_repo="$(resolve_history_repo "$repo")" || return 1
  printf '%s/.tt/history' "$canonical_repo"
}
```

#### 1d. `tt_begin_transaction` — store resolved history file in `_TT_TRANSACTION_OWNER`

`_TT_TRANSACTION_OWNER` is repurposed from a boolean `true` sentinel to holding the **resolved history file path**. It remains non-exported. The ownership check in commit/rollback changes from `[[ "${_TT_TRANSACTION_OWNER:-}" != "true" ]]` to `[[ -z "${_TT_TRANSACTION_OWNER:-}" ]]`.

```bash
# Usage: tt_begin_transaction REPO
# Begins a tt transaction. No-op if TT_TRANSACTION_ID is already set (nested call).
# Captures the current jj operation ID, checks for in-progress transactions,
# appends "<before-op-id>:" to .tt/history, exports TT_TRANSACTION_ID, and sets
# an ERR trap to auto-rollback on failure.
#
# Resolves and caches the canonical history file path in _TT_TRANSACTION_OWNER
# at begin time (while the repo/worktree still exists on disk), so that
# tt_commit_transaction and tt_rollback_transaction can use it even if the
# worktree has been deleted by the time they run (e.g. worktree delete).
tt_begin_transaction() {
  local repo="$1"
  # No-op when nested (parent command already began a transaction)
  if [[ -n "${TT_TRANSACTION_ID:-}" ]]; then
    return 0
  fi

  local history_file
  history_file="$(resolve_history_file_location "$repo")" || exit 1

  # Capture current jj operation ID
  local before_op
  before_op="$(get_jj_op_id "$repo")" || {
    log "Error: Could not read jj operation ID to begin transaction"
    exit 1
  }

  # Check for in-progress transaction (last line has empty after-op-id)
  if [[ -f "$history_file" && -s "$history_file" ]]; then
    local last_line
    last_line="$(tail -n 1 "$history_file" 2>/dev/null)" || true
    if [[ -n "$last_line" ]]; then
      local last_after="${last_line#*:}"
      if [[ -z "$last_after" ]]; then
        log "Error: Another tt command is in progress (incomplete transaction)."
        log "  To revert a crashed process: tt history undo --force"
        log "  Or to keep the current state: tt history unlock --force"
        exit 1
      fi
    fi
  fi

  # Append in-progress entry to history log
  printf '%s:\n' "$before_op" >> "$history_file"

  # Export for sub-commands (nested tt_begin_transaction calls will be no-ops)
  export TT_TRANSACTION_ID="$before_op"
  # Store resolved history file path for commit/rollback (not exported — sub-processes
  # are not the transaction owner). Using the file path rather than `true` means we
  # avoid re-resolving at commit/rollback time, which may fail if the worktree has
  # been deleted by then (e.g. worktree delete).
  _TT_TRANSACTION_OWNER="$history_file"

  # Set ERR trap to auto-rollback on failure
  trap 'tt_rollback_transaction "'"$repo"'"' ERR
}
```

#### 1e. `tt_commit_transaction` — use cached `_TT_TRANSACTION_OWNER`

```bash
# Usage: tt_commit_transaction REPO
# Finalizes the transaction by writing the after-op-id into .tt/history.
# No-op when called from a nested sub-command (not the transaction owner).
tt_commit_transaction() {
  local repo="$1"
  # Only the owning process commits the transaction
  if [[ -z "${_TT_TRANSACTION_OWNER:-}" ]]; then
    return 0
  fi

  local history_file="${_TT_TRANSACTION_OWNER}"
  local before_op="${TT_TRANSACTION_ID}"

  # Derive canonical repo from the history file path (walk up from .tt/ to find .jj/).
  # This is safe even if $repo (a worktree) has been deleted, since history_file
  # is always inside the canonical repo which remains on disk.
  local canonical_repo
  canonical_repo="$(cd "$(dirname "$history_file")" && find_repo_root)" || {
    log "Warning: Could not derive canonical repo from history file path; history may be incomplete"
    canonical_repo="$repo"
  }

  # Capture current jj operation ID
  local after_op
  after_op="$(get_jj_op_id "$canonical_repo")" || {
    log "Warning: Could not read jj operation ID for transaction commit; history may be incomplete"
    after_op="unknown"
  }

  # Replace the last line (in-progress: "<before>:") with the completed entry ("<before>:<after>")
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$ s|^${before_op}:\$|${before_op}:${after_op}|" "$history_file"
  else
    sed -i "$ s|^${before_op}:\$|${before_op}:${after_op}|" "$history_file"
  fi

  # Clear ERR trap and ownership flag
  trap - ERR
  unset _TT_TRANSACTION_OWNER
}
```

#### 1f. `tt_rollback_transaction` — use cached `_TT_TRANSACTION_OWNER`

```bash
# Usage: tt_rollback_transaction REPO
# Rolls back the transaction by restoring jj to the before-op state and
# removing the in-progress line from .tt/history.
# No-op when called from a nested sub-command (not the transaction owner).
tt_rollback_transaction() {
  local repo="$1"
  # Only the owning process rolls back
  if [[ -z "${_TT_TRANSACTION_OWNER:-}" ]]; then
    return 0
  fi

  local before_op="${TT_TRANSACTION_ID:-}"
  if [[ -z "$before_op" ]]; then
    return 0
  fi

  local history_file="${_TT_TRANSACTION_OWNER}"

  # Derive canonical repo from the history file path (walk up from .tt/ to find .jj/).
  local canonical_repo
  canonical_repo="$(cd "$(dirname "$history_file")" && find_repo_root)" || canonical_repo="$repo"

  log "Rolling back transaction (restoring jj operation: ${before_op:0:12}...)"

  # Restore jj to before-op state
  jj -R "$canonical_repo" op restore "$before_op" 2>/dev/null || \
    log "Warning: Could not restore jj operation state; manual recovery may be needed"

  # Remove the in-progress line from history
  if [[ -f "$history_file" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "/^${before_op}:\$/d" "$history_file"
    else
      sed -i "/^${before_op}:\$/d" "$history_file"
    fi
  fi

  # Clear ERR trap and ownership flag
  trap - ERR
  unset _TT_TRANSACTION_OWNER
}
```

---

### 2. `scripts/cli/task/checkout` — Remove `init_tt_history`

In the `new_worktree == true` branch, remove the `init_tt_history "$target_worktree"` call and update the comment. The `mkdir -p "$target_worktree/.tt"` line stays (needed for the `.tt/workspace` symlink).

**Before:**
```bash
    # Plant .tt/workspace symlink and history file in the new worktree.
    mkdir -p "$target_worktree/.tt"
    init_tt_history "$target_worktree"
    if [[ -L "$repo/.tt/workspace" ]]; then
```

**After:**
```bash
    # Plant .tt/workspace symlink in the new worktree.
    # Note: history lives in the canonical repo only (see resolve_history_file_location).
    mkdir -p "$target_worktree/.tt"
    if [[ -L "$repo/.tt/workspace" ]]; then
```

---

### 3. `scripts/cli/history/undo` — Use `resolve_history_file_location`

Replace the hardcoded path with a call to the new helper. This ensures `tt history undo` also works correctly when invoked from inside a secondary workspace.

**Before:**
```bash
  repo="$(resolve_repo "$repo")"

  local history_file="$repo/.tt/history"
```

**After:**
```bash
  repo="$(resolve_repo "$repo")"

  local history_file
  history_file="$(resolve_history_file_location "$repo")" || exit 1
```

---

### 4. `scripts/cli/history/unlock` — Use `resolve_history_file_location`

Same change as `history/undo`.

**Before:**
```bash
  repo="$(resolve_repo "$repo")"

  local history_file="$repo/.tt/history"
```

**After:**
```bash
  repo="$(resolve_repo "$repo")"

  local history_file
  history_file="$(resolve_history_file_location "$repo")" || exit 1
```

---

### 5. `scripts/cli/worktree/delete.test.sh` — Add history integrity assertions

Both transaction test scenarios currently only assert command success, file removal, and bookmark existence. They need `assert_history_integrity` added with `chain_depth 2` (two tt commands ran: `task complete` + `worktree delete`).

Note: the harness `get_history_lines` reads from `$REPO/.tt/history` (the canonical repo path set by `setup_workspace`), which is correct — both commands now write to that same file.

**`test_worktree_delete__transaction_succeeds`** — add after the existing assertions:
```bash
  assert_history_integrity "history chain valid after delete" 2
```

**`test_worktree_delete__transaction_succeeds_from_worktree`** — add after the existing assertions:
```bash
  assert_history_integrity "history chain valid after delete from worktree" 2
```

---

### 6. `DESIGN.md` — Update §6.12.1

Replace the existing §6.12.1 "History log file" section to document the canonical-repo-only invariant:

**Before:**
```markdown
#### 6.12.1 History log file

**Location:** `.tt/history` in the repository root.

**Format:** One line per completed transaction:
...
**Tracking:** `.tt/.gitignore` ...
```

**After:**
```markdown
#### 6.12.1 History log file

**Location:** `.tt/history` in the **canonical** jj repository root.

jj uses a single shared operation log across all workspaces: secondary workspaces
(created with `jj workspace add`) store a `.jj/repo` *pointer file* that references
the canonical repo's `.jj/repo` *directory*. Because all workspaces share the same
op log, `tt` keeps a single shared history file in the canonical repo's `.tt/`
directory rather than planting a per-worktree copy.

`resolve_history_repo REPO` (in `scripts/cli/lib/common.sh`) detects whether REPO
is a secondary workspace by checking whether `.jj/repo` is a file (pointer) or a
directory (canonical). If it is a pointer file, the function resolves the target
to find the canonical repo root. `resolve_history_file_location REPO` wraps this
to return the full `.tt/history` path and is the entry point used by the transaction
functions and `tt history undo`/`unlock`.

**Format:** One line per completed transaction:
...
**Tracking:** `.tt/.gitignore` ...
```

Also update the `tt_begin_transaction` description in §6.12.2 to mention canonical resolution:

**Before:**
> - **`tt_begin_transaction REPO`** — Called at the start of a mutating command, before the first jj operation. Captures the current jj operation ID as `<before-op-id>`, appends `<before-op-id>:` (in-progress) to `.tt/history`, ...

**After:**
> - **`tt_begin_transaction REPO`** — Called at the start of a mutating command, before the first jj operation. Resolves the canonical repo's history file via `resolve_history_file_location` (following any `.jj/repo` pointer if REPO is a secondary workspace) and caches the resolved path in `_TT_TRANSACTION_OWNER` for use by commit/rollback (which may run after the worktree has been deleted). Captures the current jj operation ID as `<before-op-id>`, appends `<before-op-id>:` (in-progress) to the canonical `.tt/history`, ...

---

## Current State of the Codebase

The following **partial changes have already been applied** to `common.sh` and `task/checkout` during earlier exploration — they are **inconsistent and must be replaced wholesale** by the plan above:

- `common.sh`: `resolve_history_repo` and `resolve_history_file_location` already added (correct, keep).
- `common.sh`: transaction block comment already updated (correct, keep).
- `common.sh`: `tt_begin_transaction` already calls `resolve_history_file_location` but still sets `_TT_TRANSACTION_OWNER=true` (incorrect — must change to `_TT_TRANSACTION_OWNER="$history_file"`).
- `common.sh`: `tt_commit_transaction` and `tt_rollback_transaction` call `resolve_history_file_location` and `resolve_history_repo` at commit/rollback time (incorrect — they fail after worktree deletion; must use cached `_TT_TRANSACTION_OWNER` instead).
- `task/checkout`: `init_tt_history` call already removed, comment already updated (correct, keep).
- `DESIGN.md`: §6.12.1 already partially updated with canonical-repo text (correct but partially applied — ensure full replacement per plan above).

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| History file lives only in canonical repo | jj shares a single op log across all workspaces; tt history should match |
| Resolve history file path at `tt_begin_transaction` time | The worktree may be deleted before commit/rollback run (e.g. `worktree delete`) |
| Store resolved path in `_TT_TRANSACTION_OWNER` (repurposed from `true` boolean) | One variable instead of two; keeps non-export semantics unchanged; ownership now detected via `[[ -z … ]]` instead of `[[ … != "true" ]]` |
| Derive canonical repo at commit/rollback via `find_repo_root` from history file dir | Robust to future changes in history file location within the repo tree; reuses existing helper |
| `get_jj_op_id` uses canonical repo in commit/rollback | `$repo` (worktree) may be deleted by then; canonical repo is always on disk |
| `history/undo` and `history/unlock` also use `resolve_history_file_location` | Consistency; ensures these commands also work from inside a secondary workspace |
| Add `assert_history_integrity` to both transaction tests | New shared-history behaviour should be verified end-to-end |

---

## Task List

- [ ] **Step 1**: Rewrite transaction functions in `scripts/cli/lib/common.sh`
  - [ ] 1a. Update block comment
  - [ ] 1b. Verify `resolve_history_repo` and `resolve_history_file_location` are correct (already added)
  - [ ] 1c. Update `tt_begin_transaction`: set `_TT_TRANSACTION_OWNER="$history_file"` (not `true`)
  - [ ] 1d. Rewrite `tt_commit_transaction`: ownership check `[[ -z … ]]`, use `_TT_TRANSACTION_OWNER` for history file, derive canonical repo via `find_repo_root`
  - [ ] 1e. Rewrite `tt_rollback_transaction`: same pattern as commit
- [ ] **Step 2**: Update `scripts/cli/task/checkout` — remove `init_tt_history` (already done; verify)
- [ ] **Step 3**: Update `scripts/cli/history/undo` — replace hardcoded `"$repo/.tt/history"` with `resolve_history_file_location`
- [ ] **Step 4**: Update `scripts/cli/history/unlock` — replace hardcoded `"$repo/.tt/history"` with `resolve_history_file_location`
- [ ] **Step 5**: Update `scripts/cli/worktree/delete.test.sh` — add `assert_history_integrity` to both transaction tests
- [ ] **Step 6**: Update `DESIGN.md` §6.12.1 and §6.12.2 per plan
- [ ] **Step 7**: Run `scripts/test worktree/delete` and confirm both transaction tests pass
- [ ] **Step 8**: Run `scripts/test history/` and confirm undo/unlock tests still pass
- [ ] **Step 9**: Run full test suite `scripts/test` and confirm no regressions
