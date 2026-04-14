---
title: "Implementation Plan"
created: 2026-04-14T21:33:29Z
updated: 2026-04-14T21:33:29Z
---
---
# Plan: `--reorder` flag for `tt task checkin`

## Overview

Add an optional `--reorder` flag to `tt task checkin` that, after the merge commit is written to the parent branch, calls `tt task reorder <parent-id>` in **tidy mode** (no modifier) to canonicalise the parent's subtask frontmatter (sorts subtasks by status: IN-PROGRESS → TODO → DONE). Also update `DESIGN.md` to document the new flag.

---

## Relevant files

| File | Purpose |
|------|---------|
| `scripts/cli/task/checkin` | Main implementation — add flag parsing, sequencing, and call |
| `scripts/cli/task/checkin.test.sh` | Test suite — add new test cases (red → green → refactor) |
| `scripts/cli/task/reorder` | Delegate target (read-only reference; no changes) |
| `scripts/cli/lib/common.sh` | Shared helpers (read-only reference) |
| `DESIGN.md` | Documentation — update `tt task checkin` spec |

---

## Research findings

### `checkin` sequence (current)

```
1.  Resolve repo / task / worktree
2.  Validate WC clean, bookmark up-to-date
3.  tt_begin_transaction               ← transaction opens here
4.  (optional) delegate to `complete`
5.  Read task state from bookmark
6.  Validate --delete requires DONE
7.  Find parent branch
8.  (optional) rebase/merge propagation
9.  Validate unmerged range (task-file diff check)
10. Determine target workspace (parent worktree)
11. Run pre-checkin hook
12. Create handoff commit
13. Run pre-receive hook
14. Create merge commit on parent; advance parent bookmark
15. Run post-receive hook
16. Switch worktree to parent / update HEAD
17. Log completion message
18. tt_commit_transaction              ← transaction closes here
19. (optional) delegate to `delete`
20. (optional) delegate to `propagate`
21. (optional) forget child worktree
```

**`--reorder` inserts between steps 17 and 18** (after the merge commit, before `--delete`; inside the transaction).

### `reorder` tidy-mode invocation

`tt task reorder <parent-id> --repo <repo>` — no modifier. This runs `reorder_frontmatter`, which:
- Reads the parent task file from its canonical branch
- Sorts subtasks by status (IN-PROGRESS first, then TODO, then DONE)
- If already canonical, exits 0 with no commit (no-op)
- Otherwise commits `Reorder task: <title> (<parent-id>)` on the parent branch and advances the parent bookmark

The reorder script calls `tt_begin_transaction` internally. Because the checkin transaction is already open, the nested call becomes a no-op (transactions are not re-entrant — `tt_begin_transaction` is idempotent when already inside one, per the existing pattern used by `--complete`).

### Flag naming and conflicts

No existing flag in checkin starts with `--reorder`; no conflict.

### Transaction scope decision

`--reorder` runs **inside** the checkin transaction (before `tt_commit_transaction`). This matches the `--complete` delegation pattern. The reorder's own `tt_begin_transaction` call will be a no-op.

### Timing decision

`--reorder` runs **after the merge commit** (step 17) and **before `--delete`** (step 19). Concretely: after the log message confirming the checkin, just before `tt_commit_transaction`.

---

## Questionnaire transcript

| # | Question | Answer |
|---|----------|--------|
| 1 | What does `--reorder` call? | Tidy mode only — `tt task reorder <parent-id>` (no modifier) |
| 2 | When in the sequence? | After the merge commit, before `--delete` |
| 3 | Transaction scope? | Inside the checkin transaction (before `tt_commit_transaction`) |
| 4 | Multiple parent worktrees? | Inherit checkin's existing resolution (no special handling) |
| 5 | Appear in `--help`? | Yes |

---

## Decision log

- **Tidy mode only.** The child just changed status (potentially to DONE), so the most useful tidy action is to reorder by status. No need for modifier pass-through.
- **Inside transaction.** Keeps the reorder atomic with the checkin from the history/undo perspective. Matches how `--complete` is handled.
- **After merge, before --delete.** The parent's subtask list is freshest at this point. Running before `--delete` means the reorder sees the entry (which `--delete` then removes). Running before `--propagate` means siblings get the tidied parent.
- **No worktree special-casing.** Checkin already rejects multiple parent worktrees; this situation is unreachable for `--reorder`.

---

## Implementation details

### 1. Flag parsing in `checkin`

Add a `do_reorder=false` local variable and a `--reorder)` case in the `while [[ $# -gt 0 ]]; do` argument parsing loop:

```bash
local do_reorder=false
# … inside the while loop:
      --reorder)     do_reorder=true; shift ;;
```

### 2. Usage string update

In the `usage()` function, add `--reorder` to the options table:

```
  --reorder                 Tidy parent subtask order after checkin (tidy mode).
```

And add `[--reorder]` to the one-line Usage: synopsis.

Also update the comment block at the top of the file:

```bash
#           [--reorder]
```

### 3. Reorder call — placement in `main()`

Insert immediately after the completion log message and **before** `tt_commit_transaction`:

```bash
  # --- Optional: tidy parent subtask order ---
  if [[ "$do_reorder" == true ]]; then
    log "Reordering parent subtask list: $parent_bookmark"
    "$SCRIPT_DIR/reorder" "$parent_bookmark" --repo "$repo"
  fi
```

The full relevant section of `main()` after this change:

```bash
  if [[ "$task_status" != "DONE" ]]; then
    log "Partial checkin complete: $task_id -> $parent_bookmark"
  else
    log "Checkin complete: $task_id -> $parent_bookmark"
  fi

  # --- Optional: tidy parent subtask order ---
  if [[ "$do_reorder" == true ]]; then
    log "Reordering parent subtask list: $parent_bookmark"
    "$SCRIPT_DIR/reorder" "$parent_bookmark" --repo "$repo"
  fi

  # Commit transaction now — before any worktree deletion …
  tt_commit_transaction "$repo"

  # --- Delegate --delete …
  if [[ "$delete" == true ]]; then
    …
  fi
```

### 4. DESIGN.md updates

**Section 5.4 — `tt task checkin` command signature:**

Current:
```
tt task checkin [<task-id>] [--context <markdown>] [--complete] [--rebase | --merge] [--force] [--delete] [--retain-worktree] [--worktree=<path>] [--propagate [--propagate-rebase | --propagate-merge] [--propagate-shallow] [--propagate-force] [--propagate-dry-run] [--propagate-to <child-id>]]
```

Updated — add `[--reorder]` after `[--delete]`:
```
tt task checkin [<task-id>] [--context <markdown>] [--complete] [--rebase | --merge] [--force] [--delete] [--reorder] [--retain-worktree] [--worktree=<path>] [--propagate [--propagate-rebase | --propagate-merge] [--propagate-shallow] [--propagate-force] [--propagate-dry-run] [--propagate-to <child-id>]]
```

Also add `--reorder` to the prose description:

> With `--reorder`: after the merge commit lands on the parent branch (and before `--delete` if also specified), runs `tt task reorder <parent-id>` in tidy mode to canonicalise the parent's subtask frontmatter (sorts subtasks by status: IN-PROGRESS → TODO → DONE). This is a no-op if the parent's subtask list is already in canonical order.

---

## Test cases to add (`checkin.test.sh`)

All new tests go in `scripts/cli/task/checkin.test.sh`, following the existing pattern.

### Red (failing) tests to write first

```bash
test_task_checkin__reorder_flag_tidies_parent() {
  # --reorder should sort the parent's subtask list after checkin.
  # Setup: project with task_b (DONE, checked in) then task_a (TODO).
  # Result: parent has [x] task_b, [ ] task_a — DONE before TODO = non-canonical.
  # After checkin task_c (new task) with --reorder, parent should have:
  #   [ ] task_a, [ ] task_c, [x] task_b
  setup_workspace "ci-reorder"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # Create and checkin task_b (DONE)
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_b" >/dev/null || true
  run_tt task complete "$task_b" >/dev/null 2>&1 || true
  run_tt task checkin "$task_b" >/dev/null 2>&1 || true
  # proj_id now has: [x] task_b

  # Create task_a and task_c (TODO)
  task_a=$(create_task "ta" "Task A") || true
  task_c=$(create_task "tc" "Task C") || true
  # proj_id now has: [x] task_b, [ ] task_a, [ ] task_c

  # Checkout task_c and do some work
  checkout_task "$task_c" >/dev/null || true
  checkpoint_task "Work C" >/dev/null || true

  # Checkin task_c with --reorder
  output="" exit_code=0
  output=$(run_tt task checkin --reorder "$task_c" 2>&1) || exit_code=$?
  assert_success "checkin --reorder succeeds" "$exit_code"

  # Verify canonical order: TODO (task_a) before DONE (task_b, task_c)
  local order
  order="$(subtask_order "$proj_id")"
  # task_a [ ] first, then task_b [x] and task_c [x] — both DONE but order among them is stable
  assert_contains "task_a is first (TODO before DONE)" "$order" "$task_a"
  local idx_a idx_b idx_c
  idx_a="$(echo "$order" | tr ' ' '\n' | grep -n "$task_a" | cut -d: -f1)"
  idx_b="$(echo "$order" | tr ' ' '\n' | grep -n "$task_b" | cut -d: -f1)"
  idx_c="$(echo "$order" | tr ' ' '\n' | grep -n "$task_c" | cut -d: -f1)"
  assert_lt "task_a (TODO) before task_b (DONE)" "$idx_a" "$idx_b"
  assert_lt "task_a (TODO) before task_c (DONE)" "$idx_a" "$idx_c"
}


test_task_checkin__reorder_flag_noop_when_already_canonical() {
  # --reorder should not create an extra commit when order is already canonical.
  setup_workspace "ci-reorder-noop"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true
  checkpoint_task "Work A" >/dev/null || true
  complete_task >/dev/null || true

  # Capture parent bookmark before checkin
  local bm_before
  bm_before=$(get_bookmark_commit "$proj_id")

  # task_a is DONE, task_b is TODO — already canonical (TODO before DONE after reorder)
  # Wait: after checkin task_a with --reorder, subtasks are [ ] task_b then [x] task_a
  # which IS canonical (TODO before DONE). So the reorder step is a no-op.
  output="" exit_code=0
  output=$(run_tt task checkin --reorder "$task_a" 2>&1) || exit_code=$?
  assert_success "checkin --reorder noop succeeds" "$exit_code"

  # Exactly ONE new commit on parent (the Merge subtask: commit; no extra Reorder commit)
  local bm_after
  bm_after=$(get_bookmark_commit "$proj_id")
  # Verify that the merge commit happened
  assert_neq "parent advanced" "$bm_after" "$bm_before"
  # Verify the top commit is Merge subtask (not Reorder)
  assert_commit_message "top commit is Merge subtask" "@-" "Merge subtask:"
}


test_task_checkin__reorder_flag_in_help() {
  setup_workspace "ci-reorder-help"
  output="" exit_code=0
  output=$(run_tt task checkin --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_optional_usage_argument "argument: --reorder" "$output" "--reorder"
}


test_task_checkin__reorder_single_transaction() {
  # --reorder should not add an extra history entry; still one entry for the whole checkin.
  setup_workspace "ci-reorder-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_b" >/dev/null || true
  run_tt task complete "$task_b" >/dev/null 2>&1 || true
  run_tt task checkin "$task_b" >/dev/null 2>&1 || true

  task_a=$(create_task "ta" "Task A") || true
  checkout_task "$task_a" >/dev/null || true
  checkpoint_task "Work A" >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task checkin --reorder "$task_a" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new history entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after checkin --reorder"
}
```

**Note on `assert_lt`:** The harness may not have `assert_lt`. Check `harness.sh` before writing the test; if absent, use an inline comparison instead:
```bash
[[ "$idx_a" -lt "$idx_b" ]] || fail "task_a (TODO) should come before task_b (DONE) in order: $order"
```

---

## Implementation order (red/green/refactor)

### Red phase
1. Add the four new test functions to `checkin.test.sh`
2. Run `scripts/test task/checkin --filter reorder` and confirm all four tests fail

### Green phase
3. Add `do_reorder=false` local variable to `main()` in `checkin`
4. Add `--reorder)` case to the argument parsing loop
5. Add `--reorder` to usage string and options table
6. Add `--reorder` to the comment block at top of file
7. Add the reorder call block between the log message and `tt_commit_transaction`
8. Run `scripts/test task/checkin --filter reorder` and confirm all four tests pass
9. Run full `scripts/test task/checkin` to confirm no regressions

### Refactor phase
10. Review implementation for any clean-up opportunities
11. Run `scripts/test task/checkin` one final time to confirm clean

### Documentation
12. Update `DESIGN.md` — command signature and prose description

---

## Task list

- [ ] **RED** — Add failing test `test_task_checkin__reorder_flag_tidies_parent`
- [ ] **RED** — Add failing test `test_task_checkin__reorder_flag_noop_when_already_canonical`
- [ ] **RED** — Add failing test `test_task_checkin__reorder_flag_in_help`
- [ ] **RED** — Add failing test `test_task_checkin__reorder_single_transaction`
- [ ] **RED** — Confirm all four new tests fail
- [ ] **GREEN** — Add `do_reorder=false` variable to `main()` in `checkin`
- [ ] **GREEN** — Add `--reorder)` case to arg-parsing loop in `checkin`
- [ ] **GREEN** — Update usage string and comment block in `checkin`
- [ ] **GREEN** — Add reorder delegation block (after log, before `tt_commit_transaction`)
- [ ] **GREEN** — Confirm all four new tests pass
- [ ] **GREEN** — Run full checkin suite; confirm no regressions
- [ ] **REFACTOR** — Review and clean up if needed
- [ ] **REFACTOR** — Final full checkin test suite run
- [ ] **DOCS** — Update `DESIGN.md` command signature
- [ ] **DOCS** — Update `DESIGN.md` prose description of `--reorder`
