---
title: "Root cause and research findings"
created: 2026-04-05T20:50:35Z
updated: 2026-04-05T20:50:35Z
---
## Root cause

`find_worktrees_for_branch` in `scripts/cli/lib/common.sh` is broken. It calls `jj workspace list` without a `-T` template, but jj 0.40.0's default output no longer includes filesystem paths:

```
# actual jj 0.40.0 default output:
default: <change-id> <commit-id> (description)
task/t-abc12345: <change-id> <commit-id> (description)
```

The comment in the code says `# Format: "name: /path/to/root (@ rev)"` — that was an older format. Parsing `awk '{print $2}'` for the path now yields a change-ID, not a directory. `[[ ! -d "$ws_root" ]]` is always true, so every workspace is skipped and the function always returns empty.

**Consequence in checkin**: `wt_count=0` → `target_ws = $repo`. When running from inside a task worktree (no `TT_REPO`), `$repo = task_worktree_path` = `$current_worktree`, so `target_ws == current_worktree`, the switch condition is false, and HEAD is never updated.

## Fix for find_worktrees_for_branch

Use `-T 'name ++ ": " ++ root ++ "\n"'` and parse with `awk -F': '` / `cut -d: -f2-`:

```bash
ws_list="$(jj -R "$repo" --ignore-working-copy workspace list --no-pager \
  -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)"
# parse:
ws_name="$(printf '%s' "$ws_line" | awk -F': ' '{print $1}')"
ws_root="$(printf '%s' "$ws_line" | cut -d: -f2- | sed 's/^ //')"
```

jj template `WorkspaceRef` fields: `name` = workspace name, `root` = absolute canonical filesystem path.

## macOS path canonicalization

jj template output always returns canonical paths (`/private/var/...`), while `mktemp` / `TT_REPO` return symlink paths (`/var/...`). A `canonical_path` helper using `cd "$path" && pwd -P` is needed whenever comparing shell paths against jj output.

## Blocker: jj file show CWD sensitivity

Once `find_worktrees_for_branch` returns canonical paths, `target_ws` in checkin becomes the canonical path. `jj -R "$target_ws" file show -- "$path"` then fails whenever CWD is not inside the canonical path's directory tree (jj resolves paths relative to CWD, not the repo root). Fix: prefix all `jj file show` path arguments with `root:`. Tracked in `task/jj-file-show-cwd-sensitivity-8b319182`.

## Switch condition simplification

The existing double-clause condition in the post-checkin cleanup block:
```bash
if [[ "$target_ws" != "$current_worktree" ]] && [[ "$target_ws" != "$repo" || "$repo" != "$current_worktree" ]]; then
```
The second clause is redundant. Once `find_worktrees_for_branch` is fixed, simplify to:
```bash
if [[ "$target_ws" != "$current_worktree" ]]; then
```
