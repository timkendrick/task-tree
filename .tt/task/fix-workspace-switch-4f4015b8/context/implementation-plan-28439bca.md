---
title: "Implementation plan"
created: 2026-04-03T18:14:19Z
updated: 2026-04-03T18:14:19Z
---
# Plan: Fix `tt workspace switch` worktree detection

## Overview

`tt workspace switch <task-id>` always fails with "No worktree found" even when a dedicated jj
workspace exists for the task. There are two bugs in `scripts/cli/workspace/switch` in the section
that queries `jj workspace list` to find matching worktrees.

---

## Context & Research

### Relevant files

| File | Role |
|------|------|
| `scripts/cli/workspace/switch` | Command being fixed |
| `scripts/cli/workspace/switch.test.sh` | Test suite (currently only has two negative-path tests) |
| `scripts/harness/harness.sh` | Test harness helpers |
| `scripts/cli/task/checkout` | Creates dedicated worktrees via `jj workspace add` |

### How worktrees are created

`tt task checkout <task-id> --worktree` calls `jj workspace add -r "$task_id" "$target_worktree"`,
where `$target_worktree` is a path outside the main repo root (e.g.
`/some/base/task/<slug>-<hex>`).

### `jj workspace list` output format

The default (no template) output is:

```
<workspace-name>: <short-commit-id> <long-commit-id> (<flags>) (description)
```

e.g.

```
bootstrap-cli-d35756ce: qxlzuvvy 4a1db02d (empty) (no description set)
standardize-commit-messages-b542cab5: lynqxkqs 74e90488 (empty) (no description set)
```

The path after `:` is **not** a filesystem path.

### WorkspaceRef template API

`jj workspace list` accepts `-T <template>`. The `WorkspaceRef` type exposes:
- `.name()` → the workspace name (string)
- `.root()` → absolute path to the workspace root, or `<Error: Workspace has no recorded path: ...>` for workspaces without a stored path

Using `-T 'name ++ ": " ++ root ++ "\n"'` produces:

```
bootstrap-cli-d35756ce: <Error: Workspace has no recorded path: bootstrap-cli-d35756ce>
default: <Error: Workspace has no recorded path: default>
standardize-commit-messages-b542cab5: /Users/tim/Sites/task-tree/task/standardize-commit-messages-b542cab5
```

Lines with `<Error:` in the path must be skipped.

### Bug 1: `--no-graph` is not a valid flag for `jj workspace list`

```bash
# BUGGY — produces an error that is silently swallowed by 2>/dev/null
workspace_list="$(jj "${jj_opts[@]}" workspace list --no-graph 2>/dev/null)" || true
```

`--no-graph` only exists on log-style commands. The error is suppressed and `workspace_list`
is empty, so the loop over it finds zero worktrees.

### Bug 2: Wrong output parsing extracts commit info instead of path

Even if `--no-graph` were removed, the sed expression `'s/^[^:]*: //'` correctly strips the
workspace name but leaves the rest of the default output — which is commit metadata, not a path.
That metadata string is then passed as `-R "$wt_path"` to jj, which also fails silently.

### Fix

Replace the `jj workspace list` call with a template-based query that emits `name: root` lines,
then skip lines whose root value starts with `<Error:`:

```bash
workspace_list="$(jj "${jj_opts[@]}" workspace list \
  -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || true
```

The existing sed `'s/^[^:]*: //'` then correctly extracts the absolute root path for worktrees
that have a recorded path, and error lines are skipped by a guard.

---

## Decision log

| Decision | Rationale |
|----------|-----------|
| Use `-T 'name ++ ": " ++ root ++ "\n"'` template | Only documented way to get the path from `jj workspace list`; `.root()` is the correct WorkspaceRef method |
| Skip `<Error:` lines | Workspaces without a recorded path (e.g. the initial default workspace) produce an error token rather than a path; these are never the target worktree |
| No change to downstream bookmark-matching logic | The bookmark query `jj -R "$wt_path" log -r 'heads(ancestors(@) & bookmarks())' ...` is correct; it was never reached due to Bug 1/2 |

---

## Task list

- [ ] **Step 1** — Confirm the bug with a dummy repo (manual shell commands)
- [ ] **Step 2** — Apply the one-line fix to `scripts/cli/workspace/switch`
- [ ] **Step 3** — Confirm the fix with a dummy repo (manual shell commands)
- [ ] **Step 4** — Add a passing test to `scripts/cli/workspace/switch.test.sh` that:
  1. Sets up a workspace
  2. Creates a project
  3. Creates a task under the project
  4. Checks out the project
  5. Checks out the task **with `--worktree`** to create a dedicated workspace
  6. Switches back to the project worktree
  7. Calls `tt workspace switch <task-id>` and asserts success
  8. Asserts the `HEAD` symlink points to the task worktree
- [ ] **Step 5** — Run the existing switch tests and new test; confirm all pass
- [ ] **Step 6** — Checkpoint

---

## Implementation details

### Step 2 — The fix (exact diff)

**File:** `scripts/cli/workspace/switch`

Find (around line 130):

```bash
  local workspace_list
  workspace_list="$(jj "${jj_opts[@]}" workspace list --no-graph 2>/dev/null)" || true
```

Replace with:

```bash
  local workspace_list
  workspace_list="$(jj "${jj_opts[@]}" workspace list \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || true
```

Find (around line 135, inside the while loop):

```bash
    local wt_path
    wt_path="$(printf '%s' "$line" | sed 's/^[^:]*: //')"
    [[ -z "$wt_path" ]] && continue
```

Replace with:

```bash
    local wt_path
    wt_path="$(printf '%s' "$line" | sed 's/^[^:]*: //')"
    [[ -z "$wt_path" ]] && continue
    # Skip workspaces without a recorded path (jj emits "<Error: ...>" for these)
    [[ "$wt_path" == '<Error:'* ]] && continue
```

### Step 4 — New test function

Add to `scripts/cli/workspace/switch.test.sh` before `run_tests`:

```bash
test_workspace_switch__switches_to_existing_worktree() {
  setup_workspace "switch-worktree"
  local proj_id task_id
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true

  # Check out the task with a dedicated worktree
  local worktree_path="$_TEST_ROOT/switch-worktree-task-wt"
  run_tt task checkout "$task_id" --worktree="$worktree_path" >/dev/null 2>&1 || true

  # Switch back to the main repo (project worktree)
  jj -R "$REPO" new "$proj_id" >/dev/null 2>&1 || true

  # Now switch HEAD to the task worktree via tt workspace switch
  output="" exit_code=0
  output=$(run_tt workspace switch "$task_id" 2>&1) || exit_code=$?
  assert_success "workspace switch succeeds" "$exit_code"

  # HEAD symlink should now point to the task worktree
  local virtual_dir
  virtual_dir="$(sed -n 's/^workspace_dir *= *//p' "$REPO/.tt/config.toml" | tr -d '"')"
  local head_target
  head_target="$(readlink "$virtual_dir/HEAD" 2>/dev/null || true)"
  # Resolve to absolute path
  if [[ "$head_target" != /* ]]; then
    head_target="$virtual_dir/$head_target"
  fi
  local resolved_head
  resolved_head="$(cd "$head_target" 2>/dev/null && pwd)" || true
  assert_eq "HEAD points to task worktree" "$resolved_head" "$worktree_path"
}
```

---

## Dummy repo verification commands

### Before fix — reproduce the bug

```bash
# 1. Create a temp jj repo
TMPDIR=$(mktemp -d)
jj git init "$TMPDIR/repo"
cd "$TMPDIR/repo"
echo "initial" > README.md
jj commit -m "Initial commit"

# 2. Init tt workspace
tt workspace init "$TMPDIR/repo" "$TMPDIR/virtual"
printf '\nworkspace_dir = "%s"\n' "$TMPDIR/virtual" >> .tt/config.toml
jj commit -m "Configure workspace_dir"

# 3. Create project + task
proj_id=$(TT_REPO="$TMPDIR/repo" tt task create --project --slug proj --title "Project" <<< "" | tail -1)
TT_REPO="$TMPDIR/repo" tt task checkout "$proj_id" >/dev/null 2>&1
task_id=$(TT_REPO="$TMPDIR/repo" tt task create --slug my-task --title "My Task" <<< "" | tail -1)

# 4. Checkout task with dedicated worktree
TT_REPO="$TMPDIR/repo" tt task checkout "$task_id" --worktree="$TMPDIR/task-wt" >/dev/null 2>&1

# 5. Switch back to main repo WC
jj -R "$TMPDIR/repo" new "$proj_id"

# 6. Reproduce bug
TT_REPO="$TMPDIR/repo" tt workspace switch "$task_id"
# Expected (buggy): Error: No worktree found for '...'
```

### After fix — confirm it works

Same steps, then:

```bash
TT_REPO="$TMPDIR/repo" tt workspace switch "$task_id"
# Expected: Switched to <task_id>
readlink "$TMPDIR/virtual/HEAD"
# Expected: symlink pointing to $TMPDIR/task-wt
```
