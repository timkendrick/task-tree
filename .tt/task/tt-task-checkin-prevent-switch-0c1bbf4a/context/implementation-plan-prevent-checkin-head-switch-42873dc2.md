---
title: "Implementation plan: prevent checkin HEAD switch"
created: 2026-05-13T20:18:32Z
updated: 2026-05-13T20:18:32Z
---
# Plan: Prevent `tt task checkin` from incorrectly switching worktree

## Summary

When `tt task checkin <task-id>` is run for a task that is NOT the currently active task (HEAD points elsewhere), the HEAD symlink should be left untouched. Currently it always switches HEAD to the parent worktree.

## Changes

### 1. Add failing test (`scripts/cli/task/checkin.test.sh`)

Add `test_task_checkin__head_not_switched_when_checkin_non_active_task`:

```bash
test_task_checkin__head_not_switched_when_checkin_non_active_task() {
  # Bug: when checking in a task that is NOT the active task (HEAD points to
  # a different task), HEAD should be left untouched.
  setup_workspace "ci-head-no-switch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "Task A") || true
  task_b=$(create_task "b" "Task B") || true

  # Work on task A (in shared worktree)
  checkout_task "$task_a" >/dev/null || true
  checkpoint_task "Work on A" >/dev/null || true
  complete_task >/dev/null || true

  # Switch to task B — HEAD now tracks task B's worktree
  checkout_task "$task_b" >/dev/null || true

  local head_before
  head_before="$(readlink "$VIRTUAL/HEAD")"

  # Checkin task A by explicit ID (we are NOT on task A)
  local exit_code=0
  output=$(run_tt task checkin "$task_a" 2>&1) || exit_code=$?
  assert_success "checkin of non-active task succeeds" "$exit_code"

  # HEAD should still point to wherever it was before (task B's context)
  local head_after
  head_after="$(readlink "$VIRTUAL/HEAD")"
  assert_eq "HEAD unchanged after checkin of non-active task" "$head_after" "$head_before"
}
```

### 2. Fix the bug (`scripts/cli/task/checkin`, ~line 436)

Replace the HEAD-switch logic. Instead of comparing `target_ws` vs `current_worktree`, compare the active worktree (what HEAD points to) against the child's worktree. Only switch if HEAD currently points to the child task's worktree.

**Before:**
```bash
  # --- Post-checkin cleanup ---
  # Always switch to the parent branch after checkin, regardless of task status.
  if [[ "$target_ws" != "$current_worktree" ]]; then
    # target_ws is a different worktree from the current one; switch HEAD to parent
    perform_workspace_switch "$repo" "${workspace_dir:-}" "$parent_bookmark" \
      "$target_ws" "$current_worktree" "$task_id"

  else
    # target_ws is same as current workspace — WC is already on parent branch
    log "Now on parent branch: $parent_bookmark"
  fi
```

**After:**
```bash
  # --- Post-checkin cleanup ---
  # Switch HEAD to the parent worktree only if HEAD currently points to the
  # child task's worktree.  If HEAD points elsewhere (e.g. the user is working
  # on a sibling task), leave it untouched.
  local active_ws=""
  if active_ws="$(get_active_worktree "${workspace_dir:-}")"; then
    active_ws="$(resolve_path_symlinks "$active_ws")"
  fi
  local resolved_child_ws
  resolved_child_ws="$(resolve_path_symlinks "$child_worktree")"

  if [[ "$active_ws" == "$resolved_child_ws" ]]; then
    if [[ "$target_ws" != "$current_worktree" ]]; then
      perform_workspace_switch "$repo" "${workspace_dir:-}" "$parent_bookmark" \
        "$target_ws" "$current_worktree" "$task_id"
    else
      log "Now on parent branch: $parent_bookmark"
    fi
  else
    log "HEAD points to a different task; not switching worktree."
  fi
```

### 3. Update DESIGN.md (§6.5 command reference)

Change "The user is always switched to the parent worktree after the merge." to:
"The user is switched to the parent worktree after the merge only if the `HEAD` worktree symlink currently points to the child task being checked in; if `HEAD` points to a different task, it is left untouched."

## Decision Log

- Compare fully-resolved paths (via `resolve_path_symlinks`) to avoid false negatives from symlinks
- Use existing `get_active_worktree` helper to read HEAD target
- `child_worktree` variable is already available in scope (set at line ~184)

## Task List

- [ ] Checkpoint current state
- [ ] Add failing test
- [ ] Run test to confirm it fails
- [ ] Fix the bug in `scripts/cli/task/checkin`
- [ ] Run test to confirm it passes
- [ ] Run full checkin test suite to confirm no regressions
- [ ] Update DESIGN.md §6.5
- [ ] Final commit
