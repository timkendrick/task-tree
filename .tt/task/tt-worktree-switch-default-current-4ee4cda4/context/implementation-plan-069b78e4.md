---
title: "Implementation Plan"
created: 2026-06-14T09:29:40Z
updated: 2026-06-14T09:29:40Z
---
# Plan: Default to current worktree in `tt worktree switch`

## Summary

Make `<worktree-path>` optional in `tt worktree switch`. When omitted, detect the current worktree from CWD using `resolve_current_worktree`. Extract a shared `list_workspaces` helper into `common.sh` that both `switch` and `list` use. Update DESIGN.md and tests.

## Decision Log

| Decision | Choice |
|----------|--------|
| Detect current worktree | `resolve_current_worktree` helper (uses `jj workspace root`) |
| DRY extraction | New `list_workspaces` helper in common.sh outputting tab-separated lines |
| Output format | `name\tpath\ttask_id` per line (empty string for missing) |
| Error when not in worktree | "Error: could not detect current worktree from working directory" |
| Help text | `switch [<worktree-path>] [--force] [--repo PATH]` |

## Task List

- [ ] 1. Create checkpoint commit
- [ ] 2. Add `list_workspaces` helper to `common.sh`
- [ ] 3. Refactor `worktree/list` to use `list_workspaces`
- [ ] 4. Update `worktree/switch` to make path optional with CWD detection
- [ ] 5. Update DESIGN.md
- [ ] 6. Add tests for the new default behavior
- [ ] 7. Run test suite and fix issues
- [ ] 8. Final commit

## Implementation Details

### Step 2: `list_workspaces` helper in `scripts/cli/lib/common.sh`

Add after the existing `resolve_workspace_name` function (~line 782):

```bash
# Usage: list_workspaces REPO TASK_PREFIX PROJECT_PREFIX
# Prints tab-separated workspace data, one line per workspace:
#   name\tpath\ttask_id
# path is empty string if unavailable; task_id is empty string if unresolved.
list_workspaces() {
  local repo="$1" task_prefix="$2" project_prefix="$3"
  local ws_raw
  ws_raw="$(jj -R "$repo" --ignore-working-copy workspace list \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || return 0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local parsed ws_name ws_path
    parsed="$(parse_workspace_list_line "$line")"
    ws_name="$(printf '%s' "$parsed" | sed -n '1p')"
    ws_path="$(printf '%s' "$parsed" | sed -n '2p')"

    local task_id=''
    if [[ -n "$ws_path" && -d "$ws_path" ]]; then
      task_id="$(resolve_current_bookmark "$ws_path" "$task_prefix" "$project_prefix" 2>/dev/null)" || true
    fi

    printf '%s\t%s\t%s\n' "$ws_name" "$ws_path" "$task_id"
  done <<< "$ws_raw"
}
```

### Step 3: Refactor `worktree/list`

Replace the inline workspace parsing loop with a call to `list_workspaces`, then iterate over its output to build the display arrays.

### Step 4: Update `worktree/switch`

In `main()`, after argument parsing, if `worktree_path` is empty:

```bash
if [[ -z "$worktree_path" ]]; then
  repo="$(resolve_repo "$repo")"
  local detected
  detected="$(resolve_current_worktree "$repo")"
  detected="$(resolve_path_symlinks "$detected")"
  # Validate it's a known workspace
  if ! resolve_workspace_name "$repo" "$detected" >/dev/null 2>&1; then
    log "Error: could not detect current worktree from working directory"
    exit 1
  fi
  worktree_path="$detected"
fi
```

Update usage text to show `[<worktree-path>]` and remove the early exit on empty path.

### Step 5: DESIGN.md

Change the `tt worktree switch` line from:
```
tt worktree switch <worktree-path> [--force]
```
to:
```
tt worktree switch [<worktree-path>] [--force]
```

Add note: "If `<worktree-path>` is omitted, defaults to the worktree containing the current working directory."

### Step 6: Tests

Add to `switch.test.sh`:

```bash
test_worktree_switch__defaults_to_current_worktree() {
  # Setup: create a task with a worktree, cd into it, run switch with no arg
  ...
}

test_worktree_switch__no_arg_outside_worktree_fails() {
  # Run switch with no arg from a non-worktree directory
  ...
}
```

## Relevant Files

- `scripts/cli/lib/common.sh` — shared helpers
- `scripts/cli/worktree/switch` — switch command
- `scripts/cli/worktree/list` — list command (to refactor)
- `scripts/cli/worktree/switch.test.sh` — tests
- `DESIGN.md` — design documentation

## Questions & Responses Transcript

1. **Detection method**: Use `resolve_current_worktree` (jj workspace root)
2. **DRY approach**: Extract `list_workspaces` helper into common.sh
3. **Error message**: "Error: could not detect current worktree from working directory"
4. **Helper format**: Tab-separated lines (name\tpath\ttask_id)
5. **Help text**: Make argument optional in usage
