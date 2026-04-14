---
title: "Implementation status and failing test analysis"
created: 2026-04-09T08:04:26Z
updated: 2026-04-09T08:04:26Z
---
# Implementation Status

## Completed

1. **`parse_task_frontmatter` helper** added to `lib/common.sh` — parses all known frontmatter fields into `PARSED_*` globals, rejects unknown keys. Edit tests pass (18/18).

2. **`edit` migrated** to use `parse_task_frontmatter` — replaced ~25 lines of inline parsing with a single call.

3. **`scripts/cli/task/reorder` script created** — full implementation with:
   - `write_task_file()` — canonical frontmatter order (title, status, created, updated, labels, contexts, subtasks)
   - `sort_subtasks_by_status()` — groups `[-]` / `[ ]` / `[x]`
   - `array_move_element()` — bash nameref array manipulation
   - `reorder_subtask()` — modifier mode (--up, --down, --before, --after)
   - `reorder_frontmatter()` — tidy mode (no modifier)
   - `main()` — arg parsing, defaults, validation

4. **`scripts/cli/tt` updated** — `reorder` alias added to dispatcher and usage.

5. **`scripts/cli/task/reorder.test.sh` created** — 26 tests (modifier mode, tidy mode, alias, help).

## Failing Tests (14/44 assertions)

### Root Cause 1: Reorder modifier mode appears to be a no-op

The reorder modifier tests (`up_basic`, `down_basic`, `before_basic`, `after_basic`, `alias`) all show the subtask order unchanged after running the command. This suggests the `reorder_subtask()` function either:
- Is not finding the child in the parent's subtask list (wrong branch being read)
- The swap/move logic runs but the write doesn't take effect
- The parent branch is being read correctly but written to the wrong place

Evidence: `test_task_reorder__down_already_last` says `'task/tb-...' is not a subtask of 'project/proj-...'` — the child is not being found in the parent's subtask list at all. Same for `up_already_first`.

**Likely cause:** When `checkout_task "$task_a"` is called in tests, the WC moves to `task_a`'s branch. The parent project branch has the subtask entries, but `find_parent_branch` scans bookmarks for `subtask:` entries. The issue is that the project branch's subtask lines may use a different format than what the regex expects, OR the parent branch is being resolved to the right bookmark but the subtask content is being read from a worktree that hasn't synced.

**Debugging approach:** Add `set -x` temporarily in `reorder_subtask` to trace which branch `find_parent_branch` returns, what `parent_content` looks like, and what `subtask_lines` contains.

### Root Cause 2: Cross-worktree issue — reading from wrong branch

The `jj_show_at_revision "$repo" "$parent_id" "$parent_task_file"` reads from the parent bookmark revision. But after tasks are created on the project branch, the project bookmark may have been advanced by the task creation itself. Need to verify that `$parent_id` (which is a bookmark name) resolves to the correct commit that contains the subtask entries.

### Root Cause 3: Tidy mode — subtask sort not matching test expectations

`test_task_reorder__tidy_basic` expects `task_a (IN-PROGRESS) task_c (TODO) task_b (DONE)` but gets `task_a task_b task_c`. The `sort_subtasks_by_status` regex may not match the actual checkbox format in the subtask lines, OR the subtask lines in `PARSED_SUBTASKS` don't start with the checkbox.

**Key detail:** `PARSED_SUBTASKS` is parsed with `sub(/^subtask:[[:space:]]*/, "")` which strips the `subtask: ` prefix but leaves `[ ] task/id`. The `sort_subtasks_by_status` checks `^\[-\]` and `^\[[[:space:]]\]` on these lines — this should work. Need to verify the actual content of subtask_lines.

### Root Cause 4: Transaction not recorded

`test_task_reorder__transaction_recorded` and `tidy_transaction_recorded` show 0 new entries. This is likely because the commands are failing silently (exit code not checked) — the `|| true` in test helpers swallows the error. The reorder command may be erroring out before `tt_begin_transaction`.

### Root Cause 5: Commit message tests read wrong revision

`test_task_reorder__commit_message` checks `@-` which is the WC parent in the test repo — but the reorder creates a commit on the *parent* branch, not the current WC branch. The test needs to check the parent branch's latest commit, not `@-`.

### Root Cause 6: Error message tests

`test_task_reorder__before_sibling_not_found` expects "not found" but gets "is not a subtask of" — the sibling lookup code runs after the child lookup, so the child-not-found error fires first. The test creates `task_a` and `task_b` under a project, then tries `--before task/nonexistent-12345678` — but `find_parent_branch` for `task_a` returns the project, then the code looks for `task_a` in the project's subtask list and... wait, it should find it. Unless the same root cause as #1 applies.

For `up_already_first` and `down_already_last`: same issue — child not found in parent's subtask list.

## Summary of Fixes Needed

1. **Primary:** Debug why `find_parent_branch` + subtask lookup fails. The child task's subtask entry on the parent branch is not being found. Likely a worktree/branch sync issue — the bookmark may point to a commit that doesn't include the subtask entries yet (the task creation commits may not be visible from the worktree being used).

2. **Tests:** Fix commit message assertions to check the parent branch bookmark tip, not `@-`.

3. **Tests:** Fix error message assertions to match actual error text (or fix the error text to match).

4. **Tidy sort:** Verify `sort_subtasks_by_status` regex matches actual subtask line format from `PARSED_SUBTASKS`.
