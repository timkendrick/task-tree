---
title: "Implementation Plan"
created: 2026-06-14T10:12:35Z
updated: 2026-06-14T10:12:35Z
---
# Plan: Return worktree path in `tt task checkout` stdout

## Summary

Modify `tt task checkout` so that:
1. The **only** stdout output is the bare worktree path on success
2. All jj command stdout is redirected to stderr (`>&2`)
3. `--help` remains on stdout (standard convention)
4. Tests are updated to capture and assert the stdout path
5. DESIGN.md is updated to document the output behavior

## Decision Log

| Decision | Choice |
|----------|--------|
| stdout format | Bare path only (no label) |
| jj stdout | Redirect to stderr (not suppress) |
| --help output | Stays on stdout |

## Questionnaire Transcript

- **stdout format**: Just the bare path → selected
- **jj output handling**: Redirect to stderr → selected
- **--help output**: Keep on stdout → selected

## Files to Modify

1. `scripts/cli/task/checkout` — main implementation
2. `scripts/cli/task/checkout.test.sh` — tests
3. `DESIGN.md` — documentation

## Implementation Details

### 1. `scripts/cli/task/checkout`

Redirect all 6 `jj` command invocations' stdout to stderr by appending `>&2`:

```bash
jj "${jj_opts[@]}" workspace add --name "$task_id" -r "$task_id" "$target_worktree" >&2
jj -R "$target_worktree" new "$task_id" >&2
jj "${jj_opts[@]}" new "$task_id" >&2
jj -R "$target_worktree" describe -m "..." >&2
jj -R "$target_worktree" bookmark set "$task_id" >&2
jj -R "$target_worktree" new "@" >&2
```

Note: `describe` and `bookmark set` likely produce no stdout, but redirect for safety.

Add at the very end of `main()`, just before the closing `}`:

```bash
  # Print the worktree path to stdout for piping
  printf '%s\n' "$target_worktree"
```

### 2. `scripts/cli/task/checkout.test.sh`

Add a new test that captures stdout and asserts it equals the worktree path:

```bash
test_task_checkout__prints_worktree_path_to_stdout() {
  setup_workspace "checkout-stdout-path"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  local stdout_output
  stdout_output=$(run_tt task checkout "$task_id" 2>/dev/null)
  # Should print the repo root (current worktree) path
  local expected_path="$REPO"
  assert_eq "stdout is worktree path" "$stdout_output" "$expected_path"
}
```

Add a worktree variant:

```bash
test_task_checkout__worktree_prints_worktree_path_to_stdout() {
  setup_workspace "checkout-wt-stdout"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  local stdout_output
  stdout_output=$(run_tt task checkout "$task_id" --worktree --switch 2>/dev/null)
  local expected_path="$VIRTUAL/$task_id"
  assert_eq "stdout is worktree path" "$stdout_output" "$expected_path"
}
```

Update `checkout_task` in `scripts/harness/harness.sh` — it already does `>/dev/null 2>&1`, so it discards the new stdout. No change needed there.

### 3. `DESIGN.md`

Update §6.2 and the checkout command description to note:

> **Output:** On success, prints the worktree path to stdout. All other output (progress messages, jj output) is written to stderr. This allows piping into other commands, e.g. `cd "$(tt task checkout task/foo-12345678)"`.

## Task List

- [ ] Checkpoint before changes
- [ ] Redirect jj stdout to stderr in `scripts/cli/task/checkout`
- [ ] Add `printf '%s\n' "$target_worktree"` at end of `main()`
- [ ] Add stdout path tests to `scripts/cli/task/checkout.test.sh`
- [ ] Update DESIGN.md §5.4 checkout entry and §6.2
- [ ] Run tests and confirm passing
- [ ] Commit changes
