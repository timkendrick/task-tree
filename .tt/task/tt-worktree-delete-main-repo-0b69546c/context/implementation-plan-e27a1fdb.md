---
title: "Implementation Plan"
created: 2026-04-24T13:05:35Z
updated: 2026-04-24T13:05:35Z
---
# Plan: Prevent deleting canonical repo via `tt worktree delete`

## Context

### Task description
`tt worktree delete` can be used to delete worktrees that have been forked from the canonical repo. It is unspecified what happens if this is run within the main repository (i.e. not a jj workspace). The task is to ensure that running `tt worktree delete` on the main repository exits with an error rather than attempting to delete the main workspace, and to update DESIGN.md accordingly.

### User questionnaire and responses

| # | Question | Response |
|---|----------|----------|
| 1 | Error message when run on canonical repo? | `"Error: Not a task worktree"` |
| 2 | Should `--force` bypass this check? | No, `--force` should **not** bypass this check |
| 3 | Detection method? | Compare resolved worktree path against canonical repo root. Extract a shared DRY helper for resolving canonical repo root and refactor existing call sites. |

### Decision log

1. **Hard guard**: The check is non-overridable — not even `--force` can bypass it. Deleting the canonical repo is always an error.
2. **Detection**: Compare the resolved target worktree path against the canonical repo root using `realpath` for canonicalization (handles macOS `/var` vs `/private/var`).
3. **DRY refactoring**: The canonical repo root resolution logic currently lives in `resolve_history_repo()` and is inlined in `tt_commit_transaction` / `tt_rollback_transaction`. Extract a new `resolve_canonical_repo()` helper, update all call sites to use it directly, and remove `resolve_history_repo()`.

### Relevant source files

- `scripts/cli/worktree/delete` — The `tt worktree delete` command (lines 65-150)
- `scripts/cli/worktree/delete.test.sh` — Test suite for worktree delete
- `scripts/cli/lib/common.sh` — Shared library containing:
  - `resolve_history_repo()` (line ~954) — resolves canonical repo from a worktree (follows `.jj/repo` pointer file)
  - `tt_commit_transaction()` (line ~1043) — inlines canonical repo resolution
  - `tt_rollback_transaction()` (line ~1087) — inlines canonical repo resolution
- `DESIGN.md` — Design document, §5.5 worktree delete specification

### Key technical detail

In jj, worktrees created via `jj workspace add` have a `.jj/repo` file (pointer) pointing back to the canonical repo's `.jj/repo` directory. The canonical repo itself has `.jj/repo` as a **directory**.

The function `resolve_history_repo()` already implements this detection: if `.jj/repo` is a file → follow pointer to canonical repo; if `.jj/repo` is a directory → this IS the canonical repo.

For this task, we need to check if the target worktree path (resolved by `find_worktrees_for_branch`) is the canonical repo itself. The "default" workspace in jj has no recorded path (`<Error: Workspace has no recorded path: default>`), so it won't appear in `find_worktrees_for_branch` results normally. However, the repo root itself could theoretically be resolved as a worktree if a task's bookmark is checked out there.

## Implementation plan

### Step 1: Extract `resolve_canonical_repo()` helper in `common.sh`

Rename the logic currently in `resolve_history_repo()` into a new `resolve_canonical_repo()` function. Update the single call site (`resolve_history_file_location`) to call `resolve_canonical_repo` directly. Update `tt_commit_transaction` and `tt_rollback_transaction` to use the new helper instead of inlining the logic. Remove `resolve_history_repo()` entirely.

**1a. Replace `resolve_history_repo()` with `resolve_canonical_repo()`** in `scripts/cli/lib/common.sh`.

Current `resolve_history_repo()` (lines ~953-970):
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
    ...
  else
    printf '%s' "$repo"
  fi
}
```

Replace with:
```bash
# Usage: resolve_canonical_repo REPO
# Returns the canonical repo root for the repository.
# If REPO is a secondary jj workspace (.jj/repo is a pointer file),
# follows the pointer to find the canonical repo root.
# If REPO is already the canonical repo (.jj/repo is a directory), returns REPO.
resolve_canonical_repo() {
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

**1b. Update `resolve_history_file_location()`** — change:
```bash
  canonical_repo="$(resolve_history_repo "$repo")" || return 1
```
to:
```bash
  canonical_repo="$(resolve_canonical_repo "$repo")" || return 1
```

**1c. Update the block comment** above the Transaction management section — replace references to `resolve_history_repo` with `resolve_canonical_repo`.

**1d. Refactor `tt_commit_transaction()`** — replace the inline canonical repo derivation block with:
```bash
  local canonical_repo
  canonical_repo="$(resolve_canonical_repo "$repo")" || {
    log "Warning: Could not resolve canonical repo; history may be incomplete"
    canonical_repo="$repo"
  }
```

**1e. Refactor `tt_rollback_transaction()`** — same pattern:
```bash
  local canonical_repo
  canonical_repo="$(resolve_canonical_repo "$repo")" || canonical_repo="$repo"
```

### Step 2: Add canonical repo check in `scripts/cli/worktree/delete`

After the target worktree has been resolved (after the disambiguation block, before the safety checks), add a check that compares the target worktree against the canonical repo root. This check is **always enforced** — it is NOT inside the `if [[ "$force" != true ]]` block.

Insert after the disambiguation logic (after `target_worktree` is fully resolved) and before the `# All pre-mutation safety checks` comment:

```bash
  # Refuse to delete the canonical (main) repo workspace — this is always an error
  local canonical_repo
  canonical_repo="$(resolve_canonical_repo "$repo")"
  if [[ "$(realpath "$target_worktree" 2>/dev/null || printf '%s' "$target_worktree")" == "$(realpath "$canonical_repo" 2>/dev/null || printf '%s' "$canonical_repo")" ]]; then
    log "Error: Not a task worktree"
    exit 1
  fi
```

### Step 3: Add test cases in `scripts/cli/worktree/delete.test.sh`

Add the following test functions:

```bash
test_worktree_delete__canonical_repo_rejected() {
  # When the only "worktree" for a task is the canonical repo itself
  # (task checked out in the main workspace without --worktree),
  # tt worktree delete should refuse with "Not a task worktree".
  setup_workspace "wt-del-canonical"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  # Checkout WITHOUT --worktree, so the task lives in the main repo workspace
  run_tt task checkout "$task_id" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "canonical repo rejected" "$exit_code"
  assert_contains "mentions not a task worktree" "$output" "Not a task worktree"
}

test_worktree_delete__canonical_repo_force_not_allowed() {
  # --force does NOT bypass the canonical repo check
  setup_workspace "wt-del-canonical-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" --force 2>&1) || exit_code=$?
  assert_failure "canonical repo rejected even with --force" "$exit_code"
  assert_contains "mentions not a task worktree" "$output" "Not a task worktree"
}
```

### Step 4: Update DESIGN.md

In the `tt worktree delete` section (§5.5), add the following to the description:

Current text:
```
- **`tt worktree delete --task <task-id> [--worktree=<path>] [--force] [--repo PATH]`** — Delete a task's jj worktree. Locates the worktree via the mandatory `--task <task-id>` argument; with `--worktree=<path>`, used to disambiguate tasks checked out in multiple worktrees (the provided path must have the specified task as its most recent task bookmark). If the worktree cannot be located (no worktree exists with the task bookmark as its direct ancestor), exits with an error. If the worktree contains uncommitted changes or has commits more recent than the task bookmark, exits with an error unless `--force` is specified. Forgets the jj workspace and removes all files from the worktree path. The task bookmark is NOT deleted. If the virtual project's `HEAD` symlink points to the deleted worktree, it is reset to the repository root.
```

Add after "exits with an error" (the first occurrence, about locating the worktree) and before the safety checks:

> If the resolved worktree is the canonical (main) repository (i.e. not a dedicated jj workspace), the command exits with an error. This check is not bypassed by `--force`.

## Task list

- [ ] Step 1: Replace `resolve_history_repo()` with `resolve_canonical_repo()`, update all call sites (`resolve_history_file_location`, `tt_commit_transaction`, `tt_rollback_transaction`), remove `resolve_history_repo()`
- [ ] Step 2: Add canonical repo check in `scripts/cli/worktree/delete`
- [ ] Step 3: Add test cases in `scripts/cli/worktree/delete.test.sh`
- [ ] Step 4: Update DESIGN.md §5.5 worktree delete specification
- [ ] Step 5: Run worktree delete tests and verify they pass
- [ ] Step 6: Run broader test suite to verify no regressions from the refactoring
- [ ] Step 7: Commit all changes
