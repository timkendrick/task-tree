---
title: "Consolidate transaction history to canonical repo via .jj/repo pointer"
status: DONE
created: 2026-04-24T09:24:59Z
updated: 2026-04-24T09:48:03Z
context: context/plan-7aa355b9
---
## Problem

The transaction history file (`.tt/history`) is currently planted separately in each jj worktree by `task checkout --worktree`, meaning each worktree accumulates its own isolated history log. This is wrong: jj has a **single shared operation log** across all workspaces (secondary workspaces use a pointer file at `.jj/repo` that references the canonical repo's store), so tt's history should also be singular.

This causes two concrete failures in the `worktree/delete` tests:

1. **`test_worktree_delete__transaction_succeeds`** — `assert_history_integrity` reports a broken chain because the setup step (`run_tt_in_worktree ... task complete`) wrote its history entry to the *worktree's* `.tt/history`, while `worktree delete` (run via `run_tt` with `TT_REPO`) wrote to the *repo's* `.tt/history`. The chain check sees a gap.

2. **`test_worktree_delete__transaction_succeeds_from_worktree`** — `run_tt_in_worktree` unsets `TT_REPO`, so `resolve_repo` returns the worktree path. `tt_begin_transaction` writes the in-progress entry to `$worktree/.tt/history`. Then `forget_worktree` deletes the worktree entirely. `tt_commit_transaction` tries to `sed -i` the now-deleted history file → exits non-zero → command fails.

## Root cause

`find_repo_root` walks up from CWD and stops at the first directory containing `.jj/`. A secondary jj workspace has `.jj/` too, so `resolve_repo` returns the worktree path when invoked from inside a worktree (with `TT_REPO` unset). All downstream code — including `tt_begin_transaction` — uses this `$repo` value to locate `.tt/history`, landing in the wrong (worktree-local) file.

## jj internals (confirmed via docs + empirical exploration)

From the official jj docs: *"Each workspace has a `.jj/` directory, but the commits and operations will be stored in the initial workspace; the other workspaces will have pointers to the initial workspace."*

Concretely:
- Canonical repo: `.jj/repo` is a **directory** (the actual op store).
- Secondary workspace: `.jj/repo` is a **file** containing a relative path back to the canonical repo's `.jj/repo` (e.g. `../../repo/.jj/repo`).
- `jj -R <worktree>` and `jj -R <canonical-repo>` share the same op log — op IDs are identical.

## Proposed fix

Add a new helper `resolve_history_repo REPO` used **only** by the three transaction functions (`tt_begin_transaction`, `tt_commit_transaction`, `tt_rollback_transaction`):

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
    # Secondary workspace: follow the pointer
    local target
    target="$(cd "$repo/.jj" && realpath "$(cat "$repo_entry")")"
    # target = /path/to/canonical/.jj/repo — strip /.jj/repo to get repo root
    dirname "$(dirname "$target")"
  else
    # Canonical repo
    printf '%s' "$repo"
  fi
}
```

All three transaction functions call `resolve_history_repo "$repo"` to derive `history_file`, while `$repo` itself is left unchanged for all `jj -R "$repo"` calls.

## Additional cleanup

- Remove the `init_tt_history "$target_worktree"` call from `task checkout --worktree` (no longer needed; history lives only in the canonical repo).
- Remove `mkdir -p "$target_worktree/.tt"` if it was only there for the history file (check whether `.tt/workspace` and `.tt/.gitignore` still need it).
- Update DESIGN.md §6.12 to make clear the history file lives in the canonical repo root, not per-worktree.
