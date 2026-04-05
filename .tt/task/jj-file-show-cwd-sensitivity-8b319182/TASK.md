---
title: "`jj file show` fails when CWD is outside the -R repo directory tree"
status: TODO
created: 2026-04-05T20:38:26Z
updated: 2026-04-05T20:38:26Z
---
## Bug

`jj file show` (jj 0.40.0) resolves file path arguments relative to CWD, not relative to the repo root passed via `-R`. It fails with "Invalid file pattern" whenever CWD is not inside the `-R` repo's directory tree.

This affects every `jj file show` call across the codebase (33 call sites in 14 files) because all existing commands resolve `$repo` via `TT_REPO` or `find_repo_root`, meaning `$repo` can differ from CWD when:

1. The jj workspace root is a different path from the shell CWD (e.g. running `tt` from a parent directory)
2. CWD is the symlinked path (`/var/...`) while `-R` receives the canonical path (`/private/var/...`) — which happens today because `find_worktrees_for_branch` returns jj template output, which is always canonical

## Repro

The bug surfaces in any `tt` command called with `--repo <path>` (or `TT_REPO=<path>`) where `<path>` is the canonical form (`/private/var/...`) and CWD is the symlink form (`/var/...`) of the same directory:

```bash
# In test harness:
repo="/var/folders/.../repo"       # from mktemp / TT_REPO
canonical="/private/var/.../repo"  # from cd "$repo" && pwd -P

jj -R "$canonical" file show -r some-bookmark -- ".tt/task/xxx/TASK.md"
# Error: Failed to parse fileset: Invalid file pattern
# Caused by: Path ".tt/task/xxx/TASK.md" is not in the repo
# Hint: Consider using root:".tt/task/xxx/TASK.md" to specify repo-relative path
```

This was discovered while fixing `find_worktrees_for_branch` (which must return canonical paths from jj template output). The fix to that function causes `target_ws` in `checkin` to be the canonical path, which then causes every `jj -R "$target_ws" file show` call to fail when CWD is the non-canonical path.

## Affected call sites

All 33 `jj file show` call sites in `scripts/cli/` need `root:` prefixed to their path argument:

- `scripts/cli/lib/common.sh` (3 sites)
- `scripts/cli/task/checkin` (3 sites)
- `scripts/cli/task/checkout` (1 site)
- `scripts/cli/task/checkpoint` (1 site)
- `scripts/cli/task/complete` (1 site)
- `scripts/cli/task/context/get` (2 sites)
- `scripts/cli/task/context/list` (1 site)
- `scripts/cli/task/create` (1 site — uses different arg order, no `--`)
- `scripts/cli/task/delete` (4 sites)
- `scripts/cli/task/edit` (2 sites)
- `scripts/cli/task/move` (2 sites)
- `scripts/cli/task/prompt` (2 sites)
- `scripts/cli/task/propagate` (2 sites)
- `scripts/cli/task/publish` (1 site)
- `scripts/cli/task/rename` (2 sites — one uses `--at-operation`, no `--`)
- `scripts/cli/task/show` (4 sites)
- `scripts/cli/task/tree` (1 site)

## Fix

Prefix all file path arguments to `jj file show` with `root:` so jj interprets them relative to the repo root regardless of CWD:

```bash
# Before:
jj -R "$repo" file show -r "$branch" -- "$task_file"

# After:
jj -R "$repo" file show -r "$branch" -- "root:$task_file"
```

The `root:` prefix is the canonical jj solution (jj itself suggests it in the error hint). It works regardless of CWD.

## Notes

- `jj file show` with `root:` has been verified to work correctly in all cases tested (CWD == repo, CWD == sibling worktree, CWD == canonical path when -R is symlink, and vice versa).
- The two call sites in `create` and `rename` that don't use `--` before the path argument need to be updated to either use `--` or use `root:` as a positional argument.
- Write failing tests first (use `--repo canonical_path` while CWD is the symlinked path, or run from inside a worktree that differs from the `-R` repo).
