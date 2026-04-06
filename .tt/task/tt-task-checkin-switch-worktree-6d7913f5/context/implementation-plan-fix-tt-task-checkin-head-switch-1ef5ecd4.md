---
title: "Implementation plan: fix tt task checkin HEAD switch"
created: 2026-04-06T12:03:49Z
updated: 2026-04-06T12:03:49Z
---
# Plan: Fix `tt task checkin` not switching HEAD worktree alias

## Overview

`tt task checkin --complete` run from inside a task's dedicated jj worktree (without `TT_REPO` set) fails to update the `HEAD` virtual worktree alias symlink to point to the parent task's workspace after checkin completes.

**Root cause:** `find_worktrees_for_branch` in `scripts/cli/lib/common.sh` parses `jj workspace list` using the old output format (`awk '{print $2}'` to extract the path). As of jj 0.40.0, the default output format is `name: <change-id> <commit-id> (description)` — not `name: /path/to/root (@ rev)`. The second field is now a change-ID, not a directory path. `[[ ! -d "$ws_root" ]]` is always true, so every workspace is skipped, `find_worktrees_for_branch` always returns empty, and the switch condition in `checkin` is never entered.

---

## Affected Files

| File | Purpose |
|------|---------|
| `scripts/cli/lib/common.sh` | Shared helpers; contains `find_worktrees_for_branch` (broken) |
| `scripts/cli/workspace/list` | Already uses the correct template; parse logic to be extracted as DRY helper |
| `scripts/cli/task/checkin` | The checkin command; contains redundant switch condition |
| `scripts/cli/task/checkin.test.sh` | Failing regression tests |
| `DESIGN.md` | Inaccurate sentence to be removed |

---

## Research Findings

### jj workspace list output format (jj 0.40.0)

**Default (no template):**
```
default: zmxytutn a523bd2b (empty) (no description set)
task/foo-abc12345: uvuwzyon c2bfe299 (empty) (no description set)
```
The second word is now a change-ID, not a path.

**With `-T 'name ++ ": " ++ root ++ "\n"'`:**
```
default: <Error: Workspace has no recorded path: default>
task/foo-abc12345: /private/var/.../repo
project/proj-deadbeef: /private/var/.../worktree
task/missing-abc12345: <Error: Failed to resolve workspace root: ...>
```
- Valid paths are absolute canonical paths (with symlinks resolved by jj on macOS: `/private/var/...`)
- Error lines appear for workspaces with no recorded path or deleted paths
- Error line format: `<name>: <Error: ...>` — the path portion starts with `<Error:`

### Existing parse logic in `workspace/list`

`scripts/cli/workspace/list` already uses this template and parses each line with:
```bash
ws_name="$(printf '%s' "$line" | sed 's/: .*//')"
ws_path="$(printf '%s' "$line" | sed 's/^[^:]*: //')"
if [[ "$ws_path" == '<Error:'* ]]; then
  ws_path='(none)'
fi
```

This exact logic should be extracted into a shared helper in `common.sh` so that `find_worktrees_for_branch` and `workspace/list` use the same DRY implementation.

### canonical_path — NOT needed as a standalone helper; fix belongs in `resolve_repo`

All worktree paths returned by jj are canonical:
- `jj workspace root` → canonical (e.g. `/private/var/...`)
- `jj workspace list -T root` → canonical
- `find_repo_root` → `pwd -P` → canonical

However, `$repo` has three sources:

| Source | Canonical? |
|--------|------------|
| `find_repo_root` (CWD walk, `pwd -P`) | ✅ Always |
| `TT_REPO` env var | ❌ User-supplied, could be `/var/...` |
| `--repo` flag | ❌ User-supplied, could be `/var/...` |

`$repo` flows into `target_ws="$repo"` (the 0-worktrees fallback in `checkin`, `delete`, `publish`), which is then compared against `current_worktree` (always canonical). If `TT_REPO=/var/...` and no dedicated worktree exists for the parent branch, `target_ws="/var/..."` vs `current_worktree="/private/var/..."` → false inequality → spurious HEAD switch.

The right fix is to canonicalize `$repo` at the end of `resolve_repo`, which is the single chokepoint where all three sources converge. This gives every caller a canonical `$repo` without any per-call-site changes, and makes all downstream comparisons safe.

### Switch condition in checkin

Current (broken/redundant):
```bash
if [[ "$target_ws" != "$current_worktree" ]] && [[ "$target_ws" != "$repo" || "$repo" != "$current_worktree" ]]; then
```

The second clause is logically redundant once `find_worktrees_for_branch` is fixed. Simplify to:
```bash
if [[ "$target_ws" != "$current_worktree" ]]; then
```

### Callers of `find_worktrees_for_branch` (scope assessment)

All scripts that call `find_worktrees_for_branch` benefit from the fix automatically since the helper is shared. No caller-level changes are needed beyond the switch condition simplification in `checkin`.

| File | Notes |
|------|-------|
| `lib/common.sh::resolve_task_worktree` | Calls `find_worktrees_for_branch`; no other changes needed |
| `task/checkin` | Calls `find_worktrees_for_branch`; switch condition to be simplified |
| `task/delete` | Calls `find_worktrees_for_branch`; no changes needed |
| `task/checkout` | Calls `find_worktrees_for_branch`; no changes needed |
| `task/complete` | Calls `find_worktrees_for_branch`; no changes needed |
| `task/context/add` | Calls `find_worktrees_for_branch`; no changes needed |
| `task/publish` | Calls `find_worktrees_for_branch`; no changes needed |
| `task/show` | Calls `find_worktrees_for_branch`; no changes needed |
| `workspace/worktree` | Calls `find_worktrees_for_branch`; no changes needed |
| `workspace/list` | Will use new shared helper instead of its own inline parse logic |

---

## Decision Log

| Question | Decision | Rationale |
|----------|----------|-----------|
| Error line handling | Extract shared DRY helper that checks `'<Error:'*` glob, matching existing `workspace/list` logic | Avoids duplication; `workspace/list` already has the correct pattern |
| `canonical_path` helper | Remove as standalone helper; instead canonicalize `$repo` in `resolve_repo` | Single chokepoint — fixes all callers; aligns `$repo` with jj's own path representation |
| Switch condition | Simplify to single `[[ "$target_ws" != "$current_worktree" ]]` | Redundant second clause; fixing `find_worktrees_for_branch` makes it correct |
| DESIGN.md update | Remove inaccurate sentence about switching user's working directory | The tool cannot change the user's shell CWD; the sentence is factually wrong |

---

## Implementation Steps

- [ ] **0. Create a new jj change** (`jj new -m "..."`) for this work
- [ ] **1. Canonicalize `$repo` in `resolve_repo`** in `scripts/cli/lib/common.sh`:
  - After the `.jj` existence check, add `repo="$(cd "$repo" && pwd -P)"`
- [ ] **2. Add `parse_workspace_list_line` helper** to `scripts/cli/lib/common.sh`:
  - Accepts one line from `jj workspace list -T 'name ++ ": " ++ root ++ "\n"'`
  - Outputs `name` to stdout on line 1, path (or empty string for error lines) on line 2
- [ ] **3. Fix `find_worktrees_for_branch`** in `scripts/cli/lib/common.sh`:
  - Use `-T 'name ++ ": " ++ root ++ "\n"'` template
  - Use `parse_workspace_list_line` to parse each line
  - Skip lines where the path is empty (error lines)
- [ ] **4. Refactor `workspace/list`** to use `parse_workspace_list_line` instead of inline sed
- [ ] **5. Simplify the switch condition** in `scripts/cli/task/checkin`
- [ ] **6. Update `DESIGN.md`**: remove the inaccurate sentence from §6.5
- [ ] **7. Run tests** to confirm failing tests pass; run full checkin and workspace/list suites

---

## Code: `resolve_repo` (canonicalize `$repo`)

In `scripts/cli/lib/common.sh`, after the `.jj` existence check in `resolve_repo`, add one line:

```bash
  if [[ ! -d "$repo/.jj" ]]; then
    log "Error: Not a jj repository: $repo"
    exit 1
  fi

  # Canonicalize to match jj's own path representation (e.g. /var → /private/var on macOS)
  repo="$(cd "$repo" && pwd -P)"
  printf '%s' "$repo"
}
```

---

## Code: `parse_workspace_list_line` helper

Add to `scripts/cli/lib/common.sh` (near `find_worktrees_for_branch`):

```bash
# Usage: parse_workspace_list_line LINE
# Parses one line from `jj workspace list -T 'name ++ ": " ++ root ++ "\n"'`.
# Outputs two lines to stdout:
#   line 1: workspace name
#   line 2: absolute filesystem path, or empty string if the path is an error
#            (i.e. the workspace has no recorded or resolvable path)
# Lines with error paths look like: "name: <Error: Workspace has no recorded path: name>"
parse_workspace_list_line() {
  local line="$1"
  local ws_name ws_path
  ws_name="$(printf '%s' "$line" | sed 's/: .*//')"
  ws_path="$(printf '%s' "$line" | sed 's/^[^:]*: //')"
  if [[ "$ws_path" == '<Error:'* ]]; then
    ws_path=''
  fi
  printf '%s\n%s\n' "$ws_name" "$ws_path"
}
```

---

## Code: `find_worktrees_for_branch` (fixed)

Replace the existing broken function in `scripts/cli/lib/common.sh`:

```bash
# Usage: find_worktrees_for_branch REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX
# Outputs one workspace root path per line for each jj workspace where
# BOOKMARK is the current branch (resolved via resolve_current).
# Uses jj template 'name ++ ": " ++ root ++ "\n"' to get workspace paths.
find_worktrees_for_branch() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  # Get all workspace names + root paths using explicit template.
  # Format per line: "name: /absolute/path" or "name: <Error: ...>" for missing paths.
  local ws_list
  ws_list="$(jj -R "$repo" --ignore-working-copy workspace list --no-pager \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || return 0
  while IFS= read -r ws_line; do
    [[ -z "$ws_line" ]] && continue
    local parsed ws_name ws_root
    parsed="$(parse_workspace_list_line "$ws_line")"
    ws_name="$(printf '%s' "$parsed" | sed -n '1p')"
    ws_root="$(printf '%s' "$parsed" | sed -n '2p')"
    [[ -z "$ws_root" ]] && continue
    [[ ! -d "$ws_root" ]] && continue
    # Resolve current bookmark in this workspace
    local resolve_out
    resolve_out="$(resolve_current "$ws_root" "$task_prefix" "$project_prefix" 2>/dev/null)" || continue
    local ws_bookmark
    ws_bookmark="$(printf '%s' "$resolve_out" | sed -n '3p')"
    if [[ "$ws_bookmark" == "$bookmark" ]]; then
      printf '%s\n' "$ws_root"
    fi
  done <<< "$ws_list"
}
```

---

## Code: `workspace/list` refactor (DRY)

In `scripts/cli/workspace/list`, replace the inline parse block:

```bash
# Before:
ws_name="$(printf '%s' "$line" | sed 's/: .*//')"
ws_path="$(printf '%s' "$line" | sed 's/^[^:]*: //')"
if [[ "$ws_path" == '<Error:'* ]]; then
  ws_path='(none)'
fi
```

With:

```bash
# After:
local parsed
parsed="$(parse_workspace_list_line "$line")"
ws_name="$(printf '%s' "$parsed" | sed -n '1p')"
ws_path="$(printf '%s' "$parsed" | sed -n '2p')"
if [[ -z "$ws_path" ]]; then
  ws_path='(none)'
fi
```

Note: `workspace/list` uses `'(none)'` as its sentinel for display purposes; `parse_workspace_list_line` returns empty string, so the `[[ -z "$ws_path" ]]` check replaces the old `'<Error:'*` glob.

---

## Code: Simplified switch condition in checkin

In `scripts/cli/task/checkin`, replace:
```bash
  if [[ "$target_ws" != "$current_worktree" ]] && [[ "$target_ws" != "$repo" || "$repo" != "$current_worktree" ]]; then
    # target_ws is a dedicated parent worktree different from current
```

With:
```bash
  if [[ "$target_ws" != "$current_worktree" ]]; then
    # target_ws is a different worktree from the current one; switch HEAD to parent
```

---

## DESIGN.md Change

In `DESIGN.md` line 595, the "After checkin" section currently reads:

> - **Complete checkin (task status `DONE`):** The tool switches the worktree to the parent (updates `HEAD` symlink, deletes the child worktree if it was dedicated). If the user's working directory was inside the deleted child path, the tool switches them to the equivalent path under the `HEAD` symlink.

Remove the final sentence (the tool cannot change the user's shell CWD). Result:

> - **Complete checkin (task status `DONE`):** The tool switches the worktree to the parent (updates `HEAD` symlink, deletes the child worktree if it was dedicated).

---

## Test Verification

The following tests should pass after the fix:

```
test_task_checkin__head_symlink_updated_from_worktree
```

This test:
1. Creates a project and task
2. Checks out the task with `--worktree --switch` (dedicated jj workspace)
3. Checkpoints from within the worktree
4. Asserts HEAD currently points to the task worktree
5. Runs checkin from within the task worktree (no `TT_REPO`)
6. Asserts HEAD was updated to point to the parent workspace (not the task worktree)

Run command:
```bash
scripts/test task/checkin --filter head_symlink_updated_from_worktree
```

Full checkin suite:
```bash
scripts/test task/checkin
```

Also run `workspace/list` suite to confirm the DRY refactor doesn't break anything:
```bash
scripts/test workspace/list
```

---

## Questions & Answers Transcript

**Q1:** How should `find_worktrees_for_branch` handle `<Error: ...>` lines?
**A:** Filter the entire output through grep before parsing — let's be precise about error format.

*Resolution:* Extract a shared `parse_workspace_list_line` helper matching the existing pattern in `workspace/list`, which checks `[[ "$ws_path" == '<Error:'* ]]`. Both callers use the same helper.

**Q2:** Where should `canonical_path` helper live?
**A:** Add to `common.sh` — assess all potential usages.

*Resolution:* Not needed as a standalone helper. The right fix is to canonicalize `$repo` at the end of `resolve_repo`, which is the single chokepoint for all three sources (`--repo` flag, `TT_REPO`, `find_repo_root`). This eliminates the entire class of non-canonical path comparison bugs across all callers.

**Q3:** Should the switch condition in checkin be simplified?
**A:** Yes — simplify to `if [[ "$target_ws" != "$current_worktree" ]]`.

**Q4:** What DESIGN.md changes are needed?
**A:** Update checkin section — high-level semantics only, no implementation details.

*Resolution:* Remove the inaccurate sentence about the tool switching the user's working directory, which the shell cannot do on behalf of a subprocess. Rest of the spec already correctly describes desired behavior.
