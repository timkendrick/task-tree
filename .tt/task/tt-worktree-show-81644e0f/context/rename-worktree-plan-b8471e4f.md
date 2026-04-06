---
title: "Implementation plan: Rename  to "
created: 2026-04-06T13:37:40Z
updated: 2026-04-06T13:37:40Z
---
# Plan: Rename `tt workspace worktree` to `tt worktree show`

## Task

Rename the CLI command `tt workspace worktree <task-id>` to `tt worktree show <task-id>`. Remove backward compatibility and the old shorthand alias entirely.

## User Decisions

1. **Shorthand alias** — Do NOT keep `tt worktree <task-id>` as a shorthand. Only `tt worktree show <task-id>` works.
2. **Backward compatibility** — Do NOT keep `tt workspace worktree <task-id>` as a hidden alias. Remove it entirely.

## Files to Change

| File | Change |
|------|--------|
| `scripts/cli/workspace/worktree` | **Delete** — old command location |
| `scripts/cli/workspace/worktree.test.sh` | **Delete** — old test file |
| `scripts/cli/worktree/show` | **Create** — new command location (moved from `workspace/worktree`) |
| `scripts/cli/worktree/show.test.sh` | **Create** — new test file (updated references) |
| `scripts/cli/tt` | **Edit** — remove `worktree` alias from dispatcher |
| `DESIGN.md` | **Edit** — update alias table and command reference |

## Implementation Steps

### Step 1: Create new directory and move command script

Create `scripts/cli/worktree/` directory and move `scripts/cli/workspace/worktree` → `scripts/cli/worktree/show`.

The script content itself needs no changes — only the help text references to `SCRIPT_NAME` and the path are affected, but since `SCRIPT_NAME` is derived from `${0##*/}` (which will be `show`), the usage text will automatically show `show` instead of `worktree`.

However, the script header comment and usage examples should be updated to reflect the new command path:

```bash
# In scripts/cli/worktree/show, update:
# - Header comment from "tt workspace worktree" to "tt worktree show"
# - Usage text (the usage() function content stays the same since SCRIPT_NAME auto-resolves)
```

### Step 2: Update and move test file

Create `scripts/cli/worktree/show.test.sh` based on `scripts/cli/workspace/worktree.test.sh`. Update:
- All references from `workspace worktree` to `worktree show`
- The `run_tests` label from `"tt workspace worktree"` to `"tt worktree show"`

New test file content:

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_worktree_show__no_dedicated_worktree_falls_back_to_repo() {
  setup_workspace "worktree-default"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true

  output="" exit_code=0
  output=$(run_tt worktree show "$task_id" 2>&1) || exit_code=$?
  assert_success "worktree lookup succeeds" "$exit_code"
  assert_contains "output is repo root" "$output" "$REPO"
}


test_worktree_show__non_existent_bookmark() {
  setup_workspace "worktree-noexist"
  output="" exit_code=0
  output=$(run_tt worktree show "task/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent bookmark rejected" "$exit_code"
}


run_tests "tt worktree show"
```

### Step 3: Update the `tt` dispatcher

In `scripts/cli/tt`:

1. **Remove** the `worktree` alias line:
   ```
   worktree)    set -- workspace worktree    "${@:2}" ;;
   ```

2. **Remove** the `worktree` line from the usage help text:
   ```
   ${SCRIPT_NAME} worktree     →  tt workspace worktree
   ```

3. **Remove** the `worktree` line from the alias table in DESIGN.md (see Step 5).

### Step 4: Delete old files

- Delete `scripts/cli/workspace/worktree`
- Delete `scripts/cli/workspace/worktree.test.sh`

### Step 5: Update DESIGN.md

Update the following sections in DESIGN.md:

1. **Alias table** (§5): Remove the row:
   ```
   | `tt worktree` | `tt workspace worktree` |
   ```

2. **Workspace commands** (§5.3): Change the command definition from:
   ```
   - **`tt workspace worktree <task-id> [--repo PATH]`** — ...
   ```
   to:
   ```
   - **`tt worktree show <task-id> [--repo PATH]`** — ...
   ```

## Task List

- [ ] Step 1: Create `scripts/cli/worktree/show` from `scripts/cli/workspace/worktree`
- [ ] Step 2: Create `scripts/cli/worktree/show.test.sh` from `scripts/cli/workspace/worktree.test.sh`
- [ ] Step 3: Update `scripts/cli/tt` dispatcher (remove alias + usage help)
- [ ] Step 4: Delete old files (`scripts/cli/workspace/worktree` and `.test.sh`)
- [ ] Step 5: Update DESIGN.md (alias table + command reference)
- [ ] Step 6: Run tests to verify
- [ ] Step 7: Commit changes
