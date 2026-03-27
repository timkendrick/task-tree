---
title: "Implementation plan"
created: 2026-03-27T14:59:43Z
updated: 2026-03-27T14:59:43Z
---
# Plan: Ensure bookmark is up to date before `tt task checkin`

**Task:** `task/tt-task-checkin-bookmark-2823aba1`  
**Plan file:** `.agents/plans/tt-task-checkin-bookmark-check.md`

---

## Overview

`tt task checkin` currently merges the commit at the task's bookmark into the parent branch. If the user has made additional `jj` commits after the bookmark (without running `tt task checkpoint` to advance the bookmark), those commits will be silently omitted from the merge. This plan adds a pre-flight check that detects this situation and fails with a helpful error message.

---

## Problem description

The task bookmark tracks `tt`-managed commits (e.g. `Begin task:`, `Checkpoint:`, `Complete task:`). The working-copy `@` may be further ahead in history with regular `jj` commits that have not been checkpointed. The handoff commit in `tt task checkin` is created from `$child_bookmark` (the bookmarked commit), not from `@` — so any commits between `$child_bookmark` and `@` are ignored.

Example scenario (newest-to-oldest):

```
@ (working copy, empty child of ○)
○  My extra jj commit          ← NOT at bookmark, will be lost
○  My other jj commit          ← NOT at bookmark, will be lost  
○  Begin task: foo (task/foo)  ← ↑ task/foo bookmark lives here
```

When `tt task checkin` is run without an explicit `<task-id>`, the handoff is created from the bookmarked `Begin task:` commit, silently omitting the two jj commits above it.

---

## Decision log

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Check is only active when `<task-id>` is **not** explicitly provided | Passing `<task-id>` is an intentional opt-out, even if it matches the current branch |
| 2 | Fail on **any** commits (including empty ones) between bookmark and `@` parent | User confirmed: any commit since the bookmark should trigger the warning |
| 3 | Error message mentions both `tt task checkpoint` and the `<task-id>` bypass | Both options should be visible to the user |
| 4 | Extract helper function `assert_bookmark_up_to_date` into `scripts/cli/lib/common.sh` | Keeps it available for future commands without creating new files |
| 5 | Only apply to `tt task checkin` for now | Other commands (`complete`, `edit`, `context add`) are out of scope for this task |

---

## User questionnaire transcript

**Q1: When `<task-id>` IS explicitly provided, should the check still be skipped?**  
A: Yes — any explicit `<task-id>` argument skips the bookmark check, even if it happens to match the current branch.

**Q2: What counts as 'commits since the bookmarked commit'?**  
A: Fail if there are any commits (empty or non-empty) between the bookmark and `@` (the working copy parent).

**Q3: Should the error message mention the `<task-id>` bypass?**  
A: Yes — mention both `tt task checkpoint` and the `<task-id>` bypass option.

**Q4: Where should the helper function live?**  
A: In `scripts/cli/lib/common.sh`.

**Q5: Should we apply the check to other commands (`complete`, `edit`, `context add`)?**  
A: No — only `tt task checkin` for now.

---

## Relevant files

| File | Role |
|------|------|
| `scripts/cli/task/checkin` | Main checkin command — where the check will be invoked |
| `scripts/cli/lib/common.sh` | Shared library — where `assert_bookmark_up_to_date` will be added |
| `DESIGN.md` | Design document — §5.2 (`tt task checkin`), §6.6 (checkin validation) need updating |
| `tests/test-history-undo.sh` | Reference test file — pattern to follow for any test additions |

---

## Implementation details

### 1. New helper function in `scripts/cli/lib/common.sh`

Add a new function `assert_bookmark_up_to_date` after the existing `is_wc_clean` function (around line 183). The function:

1. Accepts `REPO` and `BOOKMARK` as arguments.
2. Uses the jj revset `(::@- & ~::${BOOKMARK})` to find commits that exist between the bookmark and the working-copy parent. This means: "all ancestors of `@-` (the WC parent, inclusive) that are **not** in `$BOOKMARK`'s ancestry (inclusive)". If non-empty, there are uncommitted checkpoints between the bookmark and the current WC.
3. If any such commits exist, prints an error message and exits 1.
4. Does **not** check for uncommitted WC changes — that's handled separately by `is_wc_clean`.

```bash
# Usage: assert_bookmark_up_to_date REPO BOOKMARK
# Verifies that there are no commits between BOOKMARK and the working-copy
# parent (@-). If there are, exits 1 with a diagnostic message.
# This check is only meaningful when operating on the current (implicit)
# task branch; it should be skipped when an explicit task-id is provided.
assert_bookmark_up_to_date() {
  local repo="$1" bookmark="$2"
  local ahead_commits
  ahead_commits="$(jj -R "$repo" log \
    -r "(::@- & ~::${bookmark})" \
    --no-graph -T 'change_id ++ "\n"' 2>/dev/null)" || return 0
  if [[ -n "$ahead_commits" ]]; then
    log "Error: There are commits since the last checkpoint that are not tracked by the task bookmark."
    log "  Run 'tt task checkpoint' to record them before checking in."
    log "  Alternatively, pass the task ID explicitly (e.g. 'tt task checkin ${bookmark}') to skip this check."
    exit 1
  fi
}
```

### 2. Call site in `scripts/cli/task/checkin`

The check should be inserted **after** the existing `is_wc_clean` check, and only when `$task_id_arg` is empty (no explicit `<task-id>` was passed on the command line). This is important because:
- The existing `is_wc_clean` check (around line 195 in `checkin`) catches uncommitted WC changes.
- The new check fires after WC is confirmed clean, for committed-but-unbookmarked commits.

The check location in `checkin` (after resolving the child branch, after WC clean check):

```bash
# After the existing is_wc_clean check...

# --- Bookmark up-to-date check (implicit current branch only) ---
if [[ -z "$task_id_arg" ]]; then
  assert_bookmark_up_to_date "$repo" "$child_bookmark"
fi
```

**Where exactly to insert it:** After the block:
```bash
if ! is_wc_clean "$child_worktree"; then
  log "Error: Working copy has uncommitted changes. Commit or discard first."
  exit 1
fi
```

And before the `tt_begin_transaction` call.

### 3. DESIGN.md updates

Two sections need updating:

**§5.2 `tt task checkin` command description** — Update the description to mention the new precondition:
- Add to the checkin command description: "When called without an explicit `<task-id>`, also verifies that the task bookmark is up to date (i.e., there are no commits between the bookmark and `@`); if there are, the command fails with a message to run `tt task checkpoint` first."

**§6.6 Checkin validation** — Add a new bullet to the validation checklist:
- "Bookmark is up to date: no commits exist between the task bookmark and the working-copy parent (`@-`). Only checked when no explicit `<task-id>` is provided; skipped if `<task-id>` is given."

---

## Task list

- [ ] **Step 1:** Create a jj commit for this change (`jj new -m "planning"` — actually: already in a fresh change)
- [ ] **Step 2:** Add `assert_bookmark_up_to_date` function to `scripts/cli/lib/common.sh`
  - Insert after `is_wc_clean` (around line 183)
  - Follow the same doc comment convention as surrounding functions
- [ ] **Step 3:** Add the check to `scripts/cli/task/checkin`
  - Insert after the `is_wc_clean` block
  - Only call when `task_id_arg` is empty
- [ ] **Step 4:** Update `DESIGN.md`
  - §5.2 `tt task checkin` command listing
  - §6.6 Checkin validation bullet list
- [ ] **Step 5:** Commit the changes with `jj commit -m "..."`
- [ ] **Step 6:** Run diagnostics (shellcheck, manual smoke test)
- [ ] **Step 7:** Advance the task bookmark with `tt task checkpoint`

---

## Code snippets

### `scripts/cli/lib/common.sh` — new function

Insert after the closing `}` of `is_wc_clean` (after line ~183):

```bash
# Usage: assert_bookmark_up_to_date REPO BOOKMARK
# Exits 1 if there are any commits between BOOKMARK and the working-copy parent
# (@-) that are not tracked by the bookmark. Used by commands that operate on
# the implicit current branch to ensure all work has been checkpointed.
#
# Skip this check when the user passes an explicit task-id, as that constitutes
# an intentional acknowledgement that the bookmark may be behind.
assert_bookmark_up_to_date() {
  local repo="$1" bookmark="$2"
  local ahead_commits
  ahead_commits="$(jj -R "$repo" log \
    -r "(::@- & ~::${bookmark})" \
    --no-graph -T 'change_id ++ "\n"' 2>/dev/null)" || return 0
  if [[ -n "$ahead_commits" ]]; then
    log "Error: There are commits since the last checkpoint that are not tracked by the task bookmark."
    log "  Run 'tt task checkpoint' to record them before checking in."
    log "  Alternatively, pass the task ID explicitly to skip this check:"
    log "    tt task checkin ${bookmark}"
    exit 1
  fi
}
```

### `scripts/cli/task/checkin` — insertion point

After this existing block (approximately line 195–198 in `checkin`):

```bash
if ! is_wc_clean "$child_worktree"; then
  log "Error: Working copy has uncommitted changes. Commit or discard first."
  exit 1
fi
```

Add:

```bash
# --- Bookmark up-to-date check (implicit current branch only) ---
# Skip when <task-id> was passed explicitly (user knowingly bypasses the check).
if [[ -z "$task_id_arg" ]]; then
  assert_bookmark_up_to_date "$repo" "$child_bookmark"
fi
```

### `DESIGN.md` — §5.2 checkin command description update

Locate this sentence in the `tt task checkin` bullet:

> `--worktree=<path>` disambiguates when the child task has multiple worktrees. Runs validation (see §6.6); with `--rebase`/`--merge`, ...

Add after "Runs validation (see §6.6)":

> When called without an explicit `<task-id>`, also verifies that the task bookmark is up to date: if commits exist between the bookmark and the working-copy parent (`@-`), the command fails with a prompt to run `tt task checkpoint` first (or to pass `<task-id>` explicitly to bypass the check).

### `DESIGN.md` — §6.6 validation bullet list update

Add a new bullet to the checkin validation list (before "Working copy is clean"):

```
- Bookmark is up to date (implicit branch only): no commits exist between the task bookmark tip and the working-copy parent (`@-`). Only enforced when `tt task checkin` is called without an explicit `<task-id>` argument. Bypassed by passing `<task-id>` explicitly.
```

---

## Research notes

- **`jj log -r` revsets:** The revset `::@-` means "all ancestors of the working-copy parent, inclusive". The revset `~::${bookmark}` means "everything NOT in the bookmark's ancestry chain (inclusive)". Their intersection is the set of commits since the bookmark. See `jj help revsets`.
- **`@-` in jj:** In jj, `@` is the working-copy commit itself (which is always empty in the normal flow). `@-` is the parent of the working copy, i.e. the most recent committed change.
- **`jj log --no-graph -T 'change_id ++ "\n"'`:** Outputs one change ID per line with no decorations; easy to check for empty output.
- **`|| return 0`:** If jj fails for any reason (e.g. in a detached state), we silently pass the check rather than blocking the user unexpectedly.
- **Existing pattern:** `is_wc_clean` already uses a similar `jj -R "$r" log -r '@'` pattern to check if the WC is empty. The new function follows the same idiom.
