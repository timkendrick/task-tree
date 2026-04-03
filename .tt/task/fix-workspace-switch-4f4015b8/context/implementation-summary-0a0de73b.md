---
title: "Implementation summary"
created: 2026-04-03T18:17:02Z
updated: 2026-04-03T18:17:02Z
---
## Changes

### `scripts/cli/workspace/switch`

Fixed worktree detection in the `jj workspace list` parsing section.

**Bug 1 — invalid `--no-graph` flag:**
Replaced `jj workspace list --no-graph` (flag doesn't exist; error silently swallowed by
`2>/dev/null`, leaving `workspace_list` always empty) with a template query:

```bash
workspace_list="$(jj "${jj_opts[@]}" workspace list \
  -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || true
```

**Bug 2 — commit metadata extracted instead of path:**
The default output format is `<name>: <short-commit-id> <commit-id> ...`; the existing sed
was extracting commit metadata, not a filesystem path. The template fix above makes `.root()`
emit the actual worktree root path, which the existing sed correctly strips the name from.

Added a guard in the parse loop to skip workspaces without a recorded path (jj emits
`<Error: Workspace has no recorded path: ...>` for these):

```bash
[[ "$wt_path" == '<Error:'* ]] && continue
```

### `scripts/cli/workspace/switch.test.sh`

Added `test_workspace_switch__switches_to_existing_worktree`: creates a project + task,
checks out the task with `--worktree`, switches back to the project branch, then asserts
`tt workspace switch <task-id>` succeeds and the `HEAD` symlink resolves to the task worktree.
Uses `pwd -P` on both sides of the path comparison to handle macOS `/var` → `/private/var` symlinks.
