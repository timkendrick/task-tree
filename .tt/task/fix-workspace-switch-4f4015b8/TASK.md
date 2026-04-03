---
title: "Fix `tt workspace switch` worktree detection"
status: DONE
created: 2026-04-03T18:10:51Z
updated: 2026-04-03T18:17:02Z
context: context/implementation-plan-28439bca
context: context/implementation-summary-0a0de73b
---
`tt workspace switch <task-id>` fails with "No worktree found" even when a dedicated worktree exists for the task.

## Root cause

Two bugs in `scripts/cli/workspace/switch`:

### Bug 1: `--no-graph` is an invalid flag for `jj workspace list`

```bash
workspace_list="$(jj "${jj_opts[@]}" workspace list --no-graph 2>/dev/null)" || true
```

`--no-graph` is not a valid flag for `jj workspace list` (it only exists for log-style commands). The error is silently swallowed by `2>/dev/null`, so `workspace_list` is always empty and no worktrees are ever matched.

### Bug 2: Wrong output parsing — commit info extracted instead of worktree path

The script parses worktree paths using:

```bash
wt_path="$(printf '%s' "$line" | sed 's/^[^:]*: //')"
```

But the default `jj workspace list` output format is:

```
<workspace-name>: <short-commit-id> <commit-id> (empty) (no description set)
```

So sed extracts the commit description (e.g. `qxlzuvvy 4a1db02d (empty) ...`) rather than a filesystem path. This is then passed as `-R "$wt_path"` to subsequent `jj` commands, which also fail silently.

## Fix

Use a `-T` template to emit `name: root` pairs, using the `.root()` method on `WorkspaceRef`:

```bash
workspace_list="$(jj "${jj_opts[@]}" workspace list -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || true
```

The existing sed parsing `'s/^[^:]*: //'` then correctly extracts the absolute worktree root path. Workspaces without a recorded path (those that report `<Error: Workspace has no recorded path: ...>`) should be skipped.
