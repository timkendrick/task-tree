---
title: "Architecture: locate worktree show target by --name"
created: 2026-08-28T10:16:04Z
updated: 2026-08-28T10:16:04Z
---
# Architecture: Locate `tt worktree show` target by `--name`

Requirements: task context `context/requirements-cee1558e`
("Refined requirements: locate worktree show target by --name").

## Overview

`tt worktree show` becomes a pure workspace-name lookup. All task-centric machinery is
removed from the command; a new `resolve_workspace_path` helper in `scripts/cli/lib/common.sh`
provides the name→path direction, mirroring the existing path→name `resolve_workspace_name`.
A thin `jj_workspace_list` wrapper de-duplicates the `jj workspace list` invocation now shared
by four helpers.

## Control flow

```
tt worktree show --name <name>
  └─ scripts/cli/worktree/show : main()
       ├─ resolve_repo                     (common.sh)
       ├─ resolve_workspace_path           (common.sh, NEW)
       │    └─ jj_workspace_list           (common.sh, NEW)
       │         └─ jj workspace list -T 'name ++ ": " ++ root ++ "\n"'
       │    └─ parse_workspace_list_line   (common.sh, existing)
       ├─ resolve_path_symlinks            (common.sh)
       ├─ resolve_canonical_repo           (common.sh)
       └─ printf '%s\n' "$ws_path"         → stdout
```

Removed from the call graph: `get_task_prefix`, `get_project_prefix`, `is_task_branch`,
`is_project_branch`, `find_worktrees_for_branch`, and the `jj log -r <task-id>` bookmark
existence probe. All of these remain in use by other commands, so nothing in `common.sh`
becomes dead.

## `scripts/cli/lib/common.sh`

### 1. New `jj_workspace_list` (extraction)

```bash
# Usage: jj_workspace_list REPO
# Prints one line per jj workspace in REPO, formatted as "name: /absolute/path",
# or "name: <Error: ...>" when the workspace has no resolvable path.
# Parse each line with parse_workspace_list_line.
jj_workspace_list() {
  local repo="$1"
  jj -R "$repo" --ignore-working-copy workspace list --no-pager \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null
}
```

Placed immediately above `parse_workspace_list_line`, whose doc comment already describes
this exact line format.

Failure handling stays with each caller, preserving current semantics:

| Caller | Existing failure behavior | New line |
|---|---|---|
| `find_worktrees_for_branch` | `return 0` (treat as no workspaces) | `ws_list="$(jj_workspace_list "$repo")" \|\| return 0` |
| `resolve_workspace_name` | `return 1` | `ws_list="$(jj_workspace_list "$repo")" \|\| return 1` |
| `list_workspaces` | `return 0` | `ws_raw="$(jj_workspace_list "$repo")" \|\| return 0` |
| `resolve_workspace_path` (new) | `return 1` | `ws_list="$(jj_workspace_list "$repo")" \|\| return 1` |

`--no-pager` becomes uniform. Previously only `find_worktrees_for_branch` passed it; the
other three capture output in a command substitution, so paging never engaged for them
either. No observable change.

### 2. New `resolve_workspace_path`

Placed directly after `resolve_workspace_name`, its mirror image.

```bash
# Usage: resolve_workspace_path REPO WS_NAME
# Prints the recorded filesystem path of the jj workspace named WS_NAME.
# Prints an empty string if the workspace has no recorded path.
# Returns 0 if found, 1 if no workspace bears that name.
resolve_workspace_path() {
  local repo="$1" ws_name="$2"
  local ws_list
  ws_list="$(jj_workspace_list "$repo")" || return 1
  while IFS= read -r ws_line; do
    [[ -z "$ws_line" ]] && continue
    local parsed name root
    parsed="$(parse_workspace_list_line "$ws_line")"
    name="$(printf '%s' "$parsed" | sed -n '1p')"
    root="$(printf '%s' "$parsed" | sed -n '2p')"
    if [[ "$name" == "$ws_name" ]]; then
      printf '%s' "$root"
      return 0
    fi
  done <<< "$ws_list"
  return 1
}
```

Error signalling deliberately splits along "does the name exist" (exit status) rather than
"is the path usable" (empty output). This matches `parse_workspace_list_line` and
`list_workspaces`, which already represent an unresolvable path as an empty string, and it
lets `show` emit the `invalid path` message from a single site covering both an unrecorded
path and a recorded path that is no longer a directory.

Note the here-string (`<<< "$ws_list"`) rather than a pipe: the loop runs in the function's
own shell, so `return` from inside it exits the function.

## `scripts/cli/worktree/show`

### Argument parsing

`--task` is replaced by `--name`. Everything else in the parser is unchanged: `--repo`,
`-h|--help`, `-*` → usage/exit 1, bare positional → usage/exit 1, and a missing required
value → usage/exit 1.

```bash
  local name=''
  local repo=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ $# -lt 2 ]] && { usage >&2; exit 1; }
        name="$2"; shift 2 ;;
      --repo)
        [[ $# -lt 2 ]] && { usage >&2; exit 1; }
        repo="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*)
        usage >&2; exit 1 ;;
      *)
        usage >&2; exit 1 ;;
    esac
  done

  if [[ -z "$name" ]]; then
    usage >&2; exit 1
  fi
```

### Resolution and checks

Order is load-bearing: `resolve_path_symlinks` is `(cd "$1" && pwd -P)`, which fails on a
missing directory, so the invalid-path check must precede the repository-root comparison.

```bash
  repo="$(resolve_repo "$repo")"

  local ws_path
  if ! ws_path="$(resolve_workspace_path "$repo" "$name")"; then
    log "Error: No worktree named '$name'"
    exit 1
  fi

  if [[ -z "$ws_path" || ! -d "$ws_path" ]]; then
    log "Error: Worktree '$name' has an invalid path"
    exit 1
  fi
  ws_path="$(resolve_path_symlinks "$ws_path")"

  # $repo is whichever workspace resolve_repo landed on, which is not necessarily
  # the canonical repo: invoked from inside a dedicated worktree without TT_REPO
  # set, find_repo_root walks up to the worktree's own .jj and returns the
  # worktree. Resolve to the canonical repo before comparing.
  #
  # Compare canonical paths so a symlinked root (e.g. /var -> /private/var on
  # macOS) does not defeat the comparison.
  local canonical_repo resolved_canonical_repo
  canonical_repo="$(resolve_canonical_repo "$repo")" || canonical_repo="$repo"
  resolved_canonical_repo="$(resolve_path_symlinks "$canonical_repo" 2>/dev/null)" \
    || resolved_canonical_repo="$canonical_repo"

  if [[ "$ws_path" == "$resolved_canonical_repo" ]]; then
    log "Error: Worktree '$name' is the repository root, not a dedicated worktree"
    exit 1
  fi

  printf '%s\n' "$ws_path"
```

### Header comment and usage text

Both are rewritten to describe name-based lookup only, with no reference to task IDs as the
lookup key. Examples use the workspace names produced by `jj workspace add --name <task-id>`:

```
Usage: tt worktree show --name <worktree-name> [--repo PATH]

Output the path of the dedicated worktree with the given jj workspace name.
Names are listed in the NAME column of `tt worktree list`. The repository root
is not a dedicated worktree and is never a valid result.

Options:
  --name <worktree-name>  jj workspace name (required)
  --repo PATH             Repository root (overrides TT_REPO; default: walk up from CWD to find .jj)
  -h, --help              Show this help

Examples:
  tt worktree show --name task/foo-abc12345
  tt worktree show --name project/bar-def12345
```

## Test approach (`scripts/cli/worktree/show.test.sh`)

Integration tests only; `resolve_workspace_path` is exercised through the command. This
matches existing practice — `common.test.sh` has no unit tests for the sibling
`resolve_workspace_name` or `list_workspaces` helpers either.

Two scenarios need setup beyond the existing harness helpers:

- **Name decoupled from checked-out task.** Create worktree A for task A via
  `create_task_worktree`, then run `run_tt_in_worktree "$worktree_a" task checkout "$task_b"`
  so worktree A holds task B. `--name <task-A-id>` must still return worktree A;
  `--name <task-B-id>` must fail with `No worktree named` (no workspace bears that name).
- **Invalid path.** `rm -rf "$worktree_path"` after `create_task_worktree`, leaving the jj
  workspace registered. `jj workspace list` still reports the recorded root, so `-d` fails and
  the `has an invalid path` branch is reached.

Assertions on `--help` switch from `--task` to `--name` via the existing
`assert_required_usage_argument` helper.

## Regression surface

`jj_workspace_list` is consumed by `find_worktrees_for_branch`, `resolve_workspace_name` and
`list_workspaces`, which back `tt worktree list`, `tt worktree delete`, `tt worktree switch`,
`tt task delete`, `tt task checkin` and `resolve_task_worktree`. The full
`scripts/cli/worktree/` and `scripts/cli/task/` suites must pass, not just `show.test.sh`.

## Files touched

| File | Change |
|---|---|
| `scripts/cli/lib/common.sh` | Add `jj_workspace_list` and `resolve_workspace_path`; route three existing helpers through the wrapper |
| `scripts/cli/worktree/show` | Replace `--task` with `--name`; remove prefix/bookmark logic; rewrite header comment and usage |
| `scripts/cli/worktree/show.test.sh` | Rewrite all scenarios for `--name`; add decoupling and invalid-path tests |
| `DESIGN.md` | Rewrite the §5.5 `tt worktree show` bullet |
| `.agents/skills/tt/SKILL.md` | Update the `tt worktree show` signature and drop the stale fallback sentence |
