---
title: "Implementation Plan"
created: 2026-04-06T20:08:16Z
updated: 2026-04-06T20:08:16Z
---
# Plan: Clean up task worktree after `tt task checkin` completes

## Overview

After a successful `tt task checkin --complete`, if the checked-in task had a dedicated jj worktree, the worktree should be automatically cleaned up: the jj workspace should be forgotten (`jj workspace forget`) and the working copy files deleted from disk. A `--retain-worktree` flag should suppress both operations.

## Task File

`.tt/task/tt-task-checkin-worktree-cleanup-bf8d7100/TASK.md`

---

## Research Findings

### Current State

The `scripts/cli/task/checkin` script already has a **broken** attempt at cleanup at the very bottom of `main()`:

```bash
# --- Post-checkin worktree cleanup ---
# Delete the dedicated child worktree if a complete checkin was done.
if [[ "$task_status" == "DONE" ]]; then
  local child_ws_path="${workspace_dir:+${workspace_dir}/${task_id}}"
  if [[ -n "$child_ws_path" ]] && [[ -d "$child_ws_path" ]] && \
     [[ -d "$child_ws_path/.jj" || -L "$child_ws_path/.jj" ]]; then
    local child_ws_name
    child_ws_name="$(jj -R "$child_ws_path" workspace root 2>/dev/null | xargs -I{} jj -R "$target_ws" workspace list --no-pager 2>/dev/null | grep "{}" | awk '{print $1}' | tr -d ':' || true)"
    if [[ -n "$child_ws_name" ]]; then
      jj -R "$target_ws" workspace forget "$child_ws_name" 2>/dev/null || true
    fi
    rm -rf "$child_ws_path"
  fi
fi
```

**Problems with the current implementation:**
1. The workspace name lookup is completely broken — it pipes the workspace root path into `xargs -I{} jj workspace list | grep "{}"`, which doesn't work (jj workspace list doesn't take a path argument via stdin; the pattern matching also fails).
2. It uses a hardcoded `${workspace_dir}/${task_id}` path instead of using `find_worktrees_for_branch` to discover the actual worktree.
3. It assumes the workspace has a `.jj` directory at the root (for jj worktrees), but `find_worktrees_for_branch` already handles this correctly.
4. There is no `--retain-worktree` flag at all.
5. It doesn't use the existing `resolve_workspace_name` and `forget_worktree` library functions.

### Failing Tests (Pre-existing)

Three tests in `scripts/cli/task/checkin.test.sh` cover the functionality:

1. `test_task_checkin__worktree_deleted_after_complete_checkin` (line 193) — passes currently because the broken code happens to delete the worktree via `rm -rf` (even though the workspace forget fails silently).
2. `test_task_checkin__retain_worktree_flag` (line 217) — passes vacuously because `--retain-worktree` causes the command to fail (unknown option), and the test uses `|| true`, so the worktree is never deleted.
3. `test_task_checkin__worktree_not_deleted_after_partial_checkin` (line 239) — passes because the existing code only runs when `task_status == "DONE"`, which a partial checkin won't be.

The `--retain-worktree` test passes for the wrong reason (command failure rather than correct flag handling). The checkin command should **succeed** when `--retain-worktree` is passed.

### Library Functions Available

In `scripts/cli/lib/common.sh`:

- **`find_worktrees_for_branch REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX`** — Returns newline-separated list of worktree paths where BOOKMARK is the current branch.
- **`resolve_workspace_name REPO WORKTREE_PATH`** — Given a worktree path, returns the jj workspace name.
- **`forget_worktree REPO WORKSPACE_NAME [WORKTREE_PATH]`** — Forgets the jj workspace and optionally `rm -rf`s the worktree directory.
- **`parse_workspace_list_line LINE`** — Parses a line from `jj workspace list -T 'name ++ ": " ++ root ++ "\n"'`.

The `scripts/cli/worktree/delete` script uses these functions correctly as the reference implementation.

### Key Implementation Detail: `child_worktree` vs `find_worktrees_for_branch`

The checkin script already resolves `child_worktree` via `resolve_task_worktree`. However, after the checkin is complete, we need to use `find_worktrees_for_branch` again to find the **dedicated** worktree (one that is NOT the same as `$repo`). The distinction is:
- `child_worktree` may be `$repo` itself (when no dedicated worktree exists).
- A dedicated worktree is one returned by `find_worktrees_for_branch` that is different from `$repo`.

When `$child_worktree == $repo`, there is no dedicated worktree to clean up.

### Transaction Ordering

The transaction is committed **before** the worktree deletion (line: `tt_commit_transaction "$repo"`). This is correct: the history file lives in `$repo`, which may be the child worktree that's about to be removed. The worktree cleanup must happen **after** `tt_commit_transaction`.

Currently the cleanup happens after `tt_commit_transaction` and after `--delete` and `--propagate`. The new implementation should maintain this ordering.

---

## Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Use `find_worktrees_for_branch` + `resolve_workspace_name` + `forget_worktree` | These are the correct, already-tested library functions used by `tt worktree delete`. |
| 2 | Only clean up if `child_worktree != repo` | When the task has no dedicated worktree, `child_worktree` resolves to `$repo` — nothing to delete. |
| 3 | Place cleanup after `tt_commit_transaction`, `--delete`, and `--propagate` | Transaction must be committed before worktree files are deleted (history file may be inside). |
| 4 | `--retain-worktree` suppresses both `workspace forget` and `rm -rf` | Exactly as specified in the task. |
| 5 | Partial checkin (status IN-PROGRESS) never deletes the worktree | Exactly as specified; condition: `task_status == "DONE"`. |

---

## Implementation Plan

### Files to Change

1. **`scripts/cli/task/checkin`** — Main implementation changes:
   - Add `--retain-worktree` flag to argument parsing, usage, and help text
   - Replace broken cleanup block with correct implementation

2. **`DESIGN.md`** — Document the new `--retain-worktree` flag in the `tt task checkin` command description

### Detailed Changes

#### 1. `scripts/cli/task/checkin` — Argument Parsing

Add `--retain-worktree` to the usage comment at the top of the file, the `usage()` function, and the argument parsing loop.

**Usage comment** (around line 11):
```
#   checkin [<task-id>] [--context <markdown>] [--complete] [--rebase | --merge]
#           [--force] [--delete] [--retain-worktree]
#           [--worktree=<path>] [--repo PATH]
#           [--propagate] [--propagate-rebase | --propagate-merge]
#           [--propagate-shallow] [--propagate-force] [--propagate-dry-run]
#           [--propagate-to <child-id>]
```

**In `usage()` function**, add:
```
  --retain-worktree         Skip worktree deletion after complete checkin.
```

**In `main()`**, add local variable:
```bash
local retain_worktree=false
```

**In the argument parsing case statement**, add:
```bash
--retain-worktree) retain_worktree=true; shift ;;
```

#### 2. `scripts/cli/task/checkin` — Cleanup Block Replacement

Replace the entire broken post-checkin worktree cleanup block at the bottom of `main()`:

**REMOVE (broken code):**
```bash
# --- Post-checkin worktree cleanup ---
# Delete the dedicated child worktree if a complete checkin was done.
if [[ "$task_status" == "DONE" ]]; then
  local child_ws_path="${workspace_dir:+${workspace_dir}/${task_id}}"
  if [[ -n "$child_ws_path" ]] && [[ -d "$child_ws_path" ]] && \
     [[ -d "$child_ws_path/.jj" || -L "$child_ws_path/.jj" ]]; then
    local child_ws_name
    child_ws_name="$(jj -R "$child_ws_path" workspace root 2>/dev/null | xargs -I{} jj -R "$target_ws" workspace list --no-pager 2>/dev/null | grep "{}" | awk '{print $1}' | tr -d ':' || true)"
    if [[ -n "$child_ws_name" ]]; then
      jj -R "$target_ws" workspace forget "$child_ws_name" 2>/dev/null || true
    fi
    rm -rf "$child_ws_path"
  fi
fi
```

**REPLACE WITH:**
```bash
# --- Post-checkin worktree cleanup ---
# On a complete checkin (DONE), if the child task had a dedicated worktree,
# forget the jj workspace and delete the files from disk.
# Suppressed by --retain-worktree or if status is not DONE.
# IMPORTANT: This MUST be the last thing main() does. After forget_worktree,
# the script's own files may have been deleted from disk (if the checkin
# was run from within the child worktree), so no further commands should run.
if [[ "$task_status" == "DONE" ]] && [[ "$retain_worktree" != true ]]; then
  # child_worktree is the dedicated worktree if one existed, otherwise $repo.
  # Only clean up if the child was checked out in a dedicated worktree (not $repo).
  local canon_child canon_repo
  canon_child="$(realpath "$child_worktree" 2>/dev/null)" || canon_child="$child_worktree"
  canon_repo="$(realpath "$repo" 2>/dev/null)"            || canon_repo="$repo"
  if [[ "$canon_child" != "$canon_repo" ]]; then
    local ws_name
    if ws_name="$(resolve_workspace_name "$repo" "$child_worktree")"; then
      forget_worktree "$repo" "$ws_name" "$child_worktree"
      # Do NOT execute any further commands after forget_worktree.
      # The script's own files may have been deleted from disk.
    fi
  fi
fi
```

**Key design decisions for the cleanup block:**
- No `log` calls after `forget_worktree` — the script may have been deleted.
- No fallback `rm -rf` if `resolve_workspace_name` fails — if we can't identify the workspace, don't touch the files.
- This block MUST be the last thing in `main()` — no further commands should execute after `forget_worktree`.

#### 3. `DESIGN.md` — Update `tt task checkin` command description

In the command reference at line 292 (the `tt task checkin` entry), add `--retain-worktree` to the option list and description.

**Current:**
```
- **`tt task checkin [<task-id>] [--context <markdown>] [--complete] [--rebase | --merge] [--force] [--delete] [--worktree=<path>] [--propagate ...]`**
```

**Updated:** Add `[--retain-worktree]` to the option list and a sentence in the description:
> With `--retain-worktree`: skip the automatic worktree deletion after a complete checkin; the jj workspace remains registered and the files remain on disk.

Also update line 597:
```
- **Complete checkin (task status `DONE`):** The tool switches the worktree to the parent (updates `HEAD` symlink, deletes the child worktree if it was dedicated and `--retain-worktree` was not passed).
```

---

## Task List

- [ ] **Step 1**: Create a new jj change before making any edits
- [ ] **Step 2**: Update `scripts/cli/task/checkin` — add `--retain-worktree` to usage comment, `usage()`, local variable declaration, and argument parsing
- [ ] **Step 3**: Update `scripts/cli/task/checkin` — replace broken cleanup block with correct implementation
- [ ] **Step 4**: Run tests: `bash scripts/cli/task/checkin.test.sh`
- [ ] **Step 5**: Verify all three target tests pass AND no regressions
- [ ] **Step 6**: Commit the implementation change
- [ ] **Step 7**: Update `DESIGN.md` — add `--retain-worktree` to command reference and after-checkin behavior
- [ ] **Step 8**: Commit the DESIGN.md update

---

## Questions and Responses

No clarifying questions were needed — all implementation details are specified in the task description.

---

## Decision Log

1. **Use existing library functions** (`resolve_workspace_name`, `forget_worktree`): These are already battle-tested in `scripts/cli/worktree/delete`. Using them ensures consistency and avoids reimplementing logic.

2. **Detect dedicated worktree by comparing canonical paths**: `child_worktree` equals `$repo` when no dedicated worktree was created. Using `realpath` for comparison handles macOS `/var` vs `/private/var` symlink differences.

3. **Graceful fallback when workspace not registered**: If `resolve_workspace_name` fails (workspace somehow not registered with jj), fall back to `rm -rf` and log a warning. This handles edge cases without failing the overall checkin.

4. **Transaction is already committed before this block**: The `tt_commit_transaction` call already happens before `--delete` and `--propagate`. The cleanup block is the last thing in `main()`, which is correct.
5. **No commands after `forget_worktree`**: If the checkin was run from within the child worktree, `forget_worktree` deletes the script's own files. The cleanup block must be the last thing in `main()` and must not log or execute anything after the deletion.
6. **No fallback `rm -rf`**: If `resolve_workspace_name` fails (workspace not registered in jj), we skip the cleanup entirely rather than blindly deleting files we can't positively identify.
