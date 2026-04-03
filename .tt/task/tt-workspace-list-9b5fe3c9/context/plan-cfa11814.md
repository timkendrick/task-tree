---
title: "Implementation plan"
created: 2026-04-03T20:54:46Z
updated: 2026-04-03T20:54:46Z
---
# Plan: Implement `tt workspace list` CLI command

## Overview

Add a new `tt workspace list` subcommand that enumerates all jj workspaces for the current repository and shows their corresponding tt task/project IDs (resolved via `resolve_current`) alongside their filesystem paths.

---

## Research findings

### Codebase structure

- `scripts/cli/tt` — main dispatcher. Subdirectories = namespaces; executables = commands.
- `scripts/cli/workspace/` — workspace subcommands: `init`, `switch`, `branch`, `worktree` (plus `.test.sh` counterparts).
- `scripts/cli/lib/common.sh` — shared helpers sourced by all workspace commands.
- `scripts/harness/harness.sh` — test harness. Key helpers: `setup_workspace`, `create_project`, `create_task`, `checkout_task`, `run_tt`, `assert_*`.
- Test files live alongside each command: `scripts/cli/workspace/<cmd>.test.sh`.

### Key helpers in `common.sh` relevant to this command

| Helper | Purpose |
|--------|---------|
| `resolve_repo REPO_ARG` | Resolves `--repo` / `TT_REPO` / CWD walk-up to absolute repo path |
| `get_task_prefix REPO` | Reads `task_prefix` from `.tt/config.toml` (default `task/`) |
| `get_project_prefix REPO` | Reads `project_prefix` from `.tt/config.toml` (default `project/`) |
| `is_task_branch NAME PREFIX` | Returns true if name matches task ID pattern |
| `is_project_branch NAME PREFIX` | Returns true if name matches project ID pattern |
| `resolve_current REPO TASK_PREFIX PROJECT_PREFIX` | Outputs 3 lines: `rev`, `task_file`, `bookmark` – the nearest tt bookmark in ancestry of `@` |

### How `jj workspace list` is used elsewhere

In `workspace/switch`, a template is used to get paths:
```bash
workspace_list="$(jj "${jj_opts[@]}" workspace list \
  -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)"
```
- Format: `<name>: <absolute-path>` (one line per workspace)
- If workspace has no recorded path: `<name>: <Error: Workspace has no recorded path: ...>`
- `root` is the workspace's filesystem root path

### How `resolve_current` works

`resolve_current REPO TASK_PREFIX PROJECT_PREFIX` outputs 3 lines to stdout:
- Line 1: `rev` — commit ID at nearest bookmark, or `@` if none
- Line 2: `task_file` — path to `.tt/task/<slug>-<hex>/TASK.md`, or empty
- Line 3: `bookmark` — bookmark name (e.g. `task/foo-abc12345`), or empty

Called per worktree: `resolve_current "$wt_path" "$task_prefix" "$project_prefix"` (pass the worktree path as first arg, not the main repo path, so it reads `@` from that workspace's working copy). `resolve_current` already uses `--ignore-working-copy` internally, so there is no snapshot side-effect.

### Workspace name = task ID convention

When a worktree is created by `tt task checkout --worktree`, jj workspace name is set to the full task ID (e.g. `task/my-task-abc12345`). So for task workspaces, `name == task_id`. The `default` workspace has no task.

### Current workspace detection

`jj workspace root` (without `--ignore-working-copy`) outputs the root path of the workspace containing the current working directory. By comparing this to each workspace's path, we identify which workspace is "current". Edge case: if `current_ws_root` is empty (command fails), no workspace is marked current — acceptable graceful degradation.

---

## Questionnaire transcript

**Q: Output format?**
A: Tabular with header (columns aligned).

**Q: Mark current workspace?**
A: Yes — `*` prefix in a dedicated marker column (like `git branch`), plus ANSI bold when stdout is a TTY.

**Q: Path display?**
A: Abbreviate `$HOME` as `~`.

**Q: No-task display?**
A: Show `(none)` in the TASK ID column.

**Q: Both NAME and TASK ID columns?**
A: Always show both columns (no deduplication).

**Q: No-path workspace display?**
A: Show `(none)` in the PATH column.

**Q: Additional features (follow-up)?**
A: Add `--task <task-id>` flag to filter to workspaces matching the given task, and `--quiet` flag for machine-readable output (workspace names only, one per line, no header).

---

## Decision log

| Decision | Rationale |
|----------|-----------|
| Tabular output with header | Most readable for human use; consistent with common CLI tools |
| `*` current marker in dedicated column | Mirrors `git branch` convention |
| ANSI bold on current row when stdout is TTY | Visual pop without sacrificing readability |
| `(none)` placeholder for missing task/path | Explicit vs blank; avoids confusing empty cells |
| `~` home abbreviation | Saves horizontal space for long paths |
| Always show both NAME and TASK ID | Simplest; no deduplication logic needed |
| No dedicated alias | `tt workspace list` is clear; no alias needed in `tt` dispatcher |
| `--repo` option | Consistent with `workspace branch` and `workspace worktree` |
| `--task <task-id>` filter flag | Allows scripting: find the workspace for a given task without parsing tabular output |
| `--quiet` flag outputs workspace names only | Machine-readable; one name per line; pairs naturally with `--task` for scripting |

---

## Flags reference

| Flag | Type | Description |
|------|------|-------------|
| `--repo PATH` | optional | Repo root override (consistent with other workspace commands) |
| `--task <task-id>` | optional | Filter to workspaces whose resolved TASK ID matches this value |
| `--quiet` | optional | Machine-readable: print workspace names only, no header or table |
| `-h, --help` | optional | Show usage and exit |

---

## Output format specification

### Normal mode (no `--quiet`)

```
  NAME                             TASK ID                              PATH
* task/tt-workspace-list-9b5fe3c9  task/tt-workspace-list-9b5fe3c9     ~/Sites/task-tree/task/tt-workspace-list-9b5fe3c9
  project/bootstrap-cli-d35756ce   project/bootstrap-cli-d35756ce      ~/Sites/task-tree/project/bootstrap-cli-d35756ce
  default                          (none)                               (none)
```

- Column order: `<marker> NAME  TASK ID  PATH`
- Marker column: 2 characters wide (`* ` for current, `  ` for others)
- All columns left-aligned, padded with spaces to the widest value in each column
- Header row: `NAME`, `TASK ID`, `PATH` (uppercased)
- Header marker cell is blank (2 spaces)
- Current workspace: ANSI bold (`\033[1m...\033[0m`) when stdout is a TTY, no color when not
- Workspaces with no recorded path: show `(none)` in PATH column
- Workspaces with no tt task in ancestry: show `(none)` in TASK ID column
- `$HOME` abbreviated to `~` in PATH column
- When `--task` is given, only rows whose TASK ID matches are printed (header still shown)

### Quiet mode (`--quiet`)

```
task/tt-workspace-list-9b5fe3c9
project/bootstrap-cli-d35756ce
default
```

- Prints the jj workspace **name** only, one per line
- No header, no ANSI, no alignment
- Compatible with `--task`: only matching names are printed
- Intended for shell command substitution

### `--task` validation

When `--task <task-id>` is given, `task-id` must match `is_task_branch` or `is_project_branch`; otherwise exit 1 with an error message. If the filter is valid but no workspace matches, exit successfully with no data rows (header still shown in normal mode, empty output in quiet mode).

### ANSI bold

```bash
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  BOLD=''; RESET=''
fi
```

When printing the current row (normal mode), wrap the entire printf output with `${BOLD}` and `${RESET}` using `printf '%b'`.

---

## Implementation plan

### Files to create/modify

| File | Action |
|------|--------|
| `scripts/cli/workspace/list` | Create (new command) |
| `scripts/cli/workspace/list.test.sh` | Create (new test file) |
| `DESIGN.md` | Update §5.3 Workspace to document `tt workspace list` |

### Step-by-step

#### 1. Add `jj_commit` helper to `scripts/harness/harness.sh`

Insert a new helper in the **VCS Introspection Helpers** section (around line 180). This creates a plain `jj` commit in the current repo/workspace — it finalizes the current working-copy commit and opens a new empty one on top, **without advancing any bookmarks**.

```bash
# Create a plain jj commit in the current repo (does not advance any bookmarks).
# Usage: jj_commit MESSAGE [REPO]
jj_commit() {
  local msg="$1"
  jj -R "$REPO" commit -m "$msg" >/dev/null 2>&1
}
```

#### 2. Create `scripts/cli/workspace/list`

Full script:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

# tt workspace list — List all jj workspaces and their corresponding tt task IDs.
#
# Usage:
#   list [--task <task-id>] [--quiet] [--repo PATH]
#
# Options:
#   --task <task-id>  Filter to workspaces matching the given task or project ID.
#   --quiet           Machine-readable: print workspace names only, one per line.
#   --repo PATH       Repository root (overrides TT_REPO; default: walk up from CWD to find .jj).
#   -h, --help        Show this help.

readonly SCRIPT_NAME="${0##*/}"

usage() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} [--task <task-id>] [--quiet] [--repo PATH]

List all jj workspaces for the current repository and their corresponding
tt task or project IDs.

Output columns:
  (marker)  *  marks the current workspace
  NAME      jj workspace name
  TASK ID   tt task or project ID (nearest ancestor bookmark), or (none)
  PATH      filesystem path to the workspace root (~-abbreviated), or (none)

Options:
  --task <task-id>  Filter to only workspaces whose TASK ID matches <task-id>
  --quiet           Print workspace names only (one per line); no header or table
  --repo PATH       Repository root (overrides TT_REPO; default: walk up from CWD to find .jj)
  -h, --help        Show this help

Examples:
  ${SCRIPT_NAME}
  ${SCRIPT_NAME} --task task/foo-abc12345
  ${SCRIPT_NAME} --task task/foo-abc12345 --quiet
  ${SCRIPT_NAME} --repo /path/to/repo

EOF
  exit 1
}

main() {
  local repo=''
  local task_filter=''
  local quiet=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -lt 2 ]] && { log "Error: --repo requires an argument"; usage; }
        repo="$2"; shift 2 ;;
      --task)
        [[ $# -lt 2 ]] && { log "Error: --task requires an argument"; usage; }
        task_filter="$2"; shift 2 ;;
      --quiet)
        quiet=true; shift ;;
      -h|--help) usage 0 ;;
      -*)
        log "Error: Unknown option: $1"; usage ;;
      *)
        log "Error: Unexpected argument: $1"; usage ;;
    esac
  done

  repo="$(resolve_repo "$repo")"

  local task_prefix project_prefix
  task_prefix="$(get_task_prefix "$repo")"
  project_prefix="$(get_project_prefix "$repo")"

  # Validate --task filter if provided
  if [[ -n "$task_filter" ]]; then
    if ! is_task_branch "$task_filter" "$task_prefix" && \
       ! is_project_branch "$task_filter" "$project_prefix"; then
      log "Error: '$task_filter' is not a recognized task or project ID"
      log "  Expected prefix '$task_prefix' or '$project_prefix' with 8-hex suffix"
      exit 1
    fi
  fi

  # Determine current workspace root (to mark with *)
  local current_ws_root
  current_ws_root="$(jj -R "$repo" workspace root 2>/dev/null)" || current_ws_root=""

  # Collect workspace list from jj
  # Template: "name: path\n" — path may be "<Error: ...>" for workspaces without a recorded path
  local ws_raw
  ws_raw="$(jj -R "$repo" --ignore-working-copy workspace list \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || ws_raw=""

  # Parse into parallel arrays
  local -a ws_names=()
  local -a ws_paths=()
  local -a ws_task_ids=()
  local -a ws_is_current=()

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local ws_name ws_path
    ws_name="$(printf '%s' "$line" | sed 's/: .*//')"
    ws_path="$(printf '%s' "$line" | sed 's/^[^:]*: //')"

    # Normalize path: if error, use (none)
    if [[ "$ws_path" == '<Error:'* ]]; then
      ws_path='(none)'
    fi

    # Resolve tt task ID for this workspace
    local task_id='(none)'
    if [[ "$ws_path" != '(none)' && -d "$ws_path" ]]; then
      local resolve_out
      resolve_out="$(resolve_current "$ws_path" "$task_prefix" "$project_prefix" 2>/dev/null)" || true
      local bm
      bm="$(printf '%s' "$resolve_out" | sed -n '3p')"
      if [[ -n "$bm" ]]; then
        task_id="$bm"
      fi
    fi

    # Apply --task filter
    if [[ -n "$task_filter" && "$task_id" != "$task_filter" ]]; then
      continue
    fi

    # Abbreviate $HOME in path
    local display_path="$ws_path"
    if [[ "$ws_path" != '(none)' ]]; then
      display_path="${ws_path/#$HOME/~}"
    fi

    # Is this the current workspace?
    local is_current=false
    if [[ -n "$current_ws_root" && "$ws_path" == "$current_ws_root" ]]; then
      is_current=true
    fi

    ws_names+=("$ws_name")
    ws_paths+=("$display_path")
    ws_task_ids+=("$task_id")
    ws_is_current+=("$is_current")
  done <<< "$ws_raw"

  # --quiet mode: print workspace names only, one per line
  if [[ "$quiet" == true ]]; then
    for (( i=0; i<${#ws_names[@]}; i++ )); do
      printf '%s\n' "${ws_names[$i]}"
    done
    return 0
  fi

  # Compute column widths (max of header and each row value)
  local header_name="NAME" header_task="TASK ID" header_path="PATH"
  local max_name=${#header_name}
  local max_task=${#header_task}
  local max_path=${#header_path}

  local i
  for (( i=0; i<${#ws_names[@]}; i++ )); do
    local n=${#ws_names[$i]}
    local t=${#ws_task_ids[$i]}
    local p=${#ws_paths[$i]}
    (( n > max_name )) && max_name=$n
    (( t > max_task )) && max_task=$t
    (( p > max_path )) && max_path=$p
  done

  # ANSI bold (only when stdout is a TTY)
  local BOLD='' RESET=''
  if [[ -t 1 ]]; then
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
  fi

  # Print header (marker column is 2 chars wide)
  printf '  %-*s  %-*s  %s\n' \
    "$max_name" "$header_name" \
    "$max_task" "$header_task" \
    "$header_path"

  # Print rows
  for (( i=0; i<${#ws_names[@]}; i++ )); do
    local marker='  '
    if [[ "${ws_is_current[$i]}" == true ]]; then
      marker='* '
      printf '%b%s%-*s  %-*s  %s%b\n' \
        "$BOLD" \
        "$marker" \
        "$max_name" "${ws_names[$i]}" \
        "$max_task" "${ws_task_ids[$i]}" \
        "${ws_paths[$i]}" \
        "$RESET"
    else
      printf '%s%-*s  %-*s  %s\n' \
        "$marker" \
        "$max_name" "${ws_names[$i]}" \
        "$max_task" "${ws_task_ids[$i]}" \
        "${ws_paths[$i]}"
    fi
  done
}

main "$@"
```

#### 3. Create `scripts/cli/workspace/list.test.sh`

Tests (11 cases):
1. `test_workspace_list__basic_output_has_header` — output includes NAME / TASK ID / PATH header.
2. `test_workspace_list__default_workspace_has_none_task` — default workspace shows `(none)` for task ID.
3. `test_workspace_list__shows_task_id_for_task_workspace` — task worktree shows correct task ID.
4. `test_workspace_list__task_inferred_from_ancestry` — workspace tip is NOT on the task bookmark itself (extra `jj` commit on top via new `jj_commit` harness helper), so the task bookmark sits in the direct ancestry of `@` but is not `@` itself. `resolve_current` (`heads(ancestors(@) & bookmarks())`) should still infer the correct task ID.
5. `test_workspace_list__repo_flag` — `--repo` flag works.
6. `test_workspace_list__unknown_option_fails` — unknown option exits non-zero.
7. `test_workspace_list__task_filter` — `--task <id>` shows only matching workspace row, omits others.
8. `test_workspace_list__task_filter_no_match` — `--task` with valid-format ID that has no workspace: succeeds, header shown, no data rows for that task.
9. `test_workspace_list__task_filter_invalid_id` — `--task` with bad ID format exits non-zero.
10. `test_workspace_list__quiet_mode` — `--quiet` prints workspace names only, no header.
11. `test_workspace_list__quiet_with_task_filter` — `--quiet --task` prints only matching workspace name.

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_workspace_list__basic_output_has_header() {
  setup_workspace "list-header"
  output="" exit_code=0
  output=$(run_tt workspace list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "output has NAME header" "$output" "NAME"
  assert_contains "output has TASK ID header" "$output" "TASK ID"
  assert_contains "output has PATH header" "$output" "PATH"
}

test_workspace_list__default_workspace_has_none_task() {
  setup_workspace "list-none-task"
  output="" exit_code=0
  output=$(run_tt workspace list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "default row shows (none) for task" "$output" "(none)"
}

test_workspace_list__shows_task_id_for_task_workspace() {
  setup_workspace "list-task-id"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt workspace list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "output contains task ID" "$output" "$task_id"
}

test_workspace_list__task_inferred_from_ancestry() {
  # The workspace working copy has a plain jj commit on top of the task bookmark tip.
  # resolve_current should still find the task bookmark in the ancestry.
  setup_workspace "list-ancestry"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  # Add a plain jj commit on top of the task bookmark tip (does NOT advance the bookmark)
  jj_commit "Extra work beyond bookmark tip" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt workspace list 2>&1) || exit_code=$?
  assert_success "list succeeds" "$exit_code"
  assert_contains "output infers task ID from ancestry" "$output" "$task_id"
}

test_workspace_list__repo_flag() {
  setup_workspace "list-repo-flag"
  output="" exit_code=0
  output=$(run_tt workspace list --repo "$REPO" 2>&1) || exit_code=$?
  assert_success "list with --repo succeeds" "$exit_code"
  assert_contains "output has header" "$output" "NAME"
}

test_workspace_list__unknown_option_fails() {
  setup_workspace "list-unknown-opt"
  output="" exit_code=0
  output=$(run_tt workspace list --unknown 2>&1) || exit_code=$?
  assert_failure "unknown option fails" "$exit_code"
}

test_workspace_list__task_filter() {
  setup_workspace "list-filter"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt workspace list --task "$task_id" 2>&1) || exit_code=$?
  assert_success "list --task succeeds" "$exit_code"
  assert_contains "filtered output contains task ID" "$output" "$task_id"
  assert_not_contains "filtered output omits other workspaces" "$output" "default"
}

test_workspace_list__task_filter_no_match() {
  setup_workspace "list-filter-nomatch"
  proj_id=$(create_project "proj" "Project") || true

  # proj_id exists as a bookmark but has no worktree checked out with that task
  # (only the repo's default workspace exists; it won't have proj_id as resolved task)
  output="" exit_code=0
  output=$(run_tt workspace list --task "$proj_id" 2>&1) || exit_code=$?
  assert_success "list with no-match task filter still succeeds" "$exit_code"
  assert_contains "header is still present" "$output" "NAME"
  assert_not_contains "proj_id row absent" "$output" "$proj_id"
}

test_workspace_list__task_filter_invalid_id() {
  setup_workspace "list-filter-invalid"
  output="" exit_code=0
  output=$(run_tt workspace list --task "not-a-task-id" 2>&1) || exit_code=$?
  assert_failure "invalid --task ID rejected" "$exit_code"
}

test_workspace_list__quiet_mode() {
  setup_workspace "list-quiet"
  output="" exit_code=0
  output=$(run_tt workspace list --quiet 2>&1) || exit_code=$?
  assert_success "list --quiet succeeds" "$exit_code"
  assert_not_contains "quiet output has no NAME header" "$output" "NAME"
  assert_not_contains "quiet output has no TASK ID header" "$output" "TASK ID"
  assert_contains "quiet output lists a workspace name" "$output" "default"
}

test_workspace_list__quiet_with_task_filter() {
  setup_workspace "list-quiet-filter"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt workspace list --quiet --task "$task_id" 2>&1) || exit_code=$?
  assert_success "list --quiet --task succeeds" "$exit_code"
  assert_contains "quiet output contains workspace name" "$output" "$task_id"
  assert_not_contains "quiet output omits other workspaces" "$output" "default"
  assert_not_contains "quiet output has no header" "$output" "NAME"
}


run_tests "tt workspace list"
```

#### 4. Update `DESIGN.md`

In section **5.3 Workspace**, after the `tt workspace worktree` bullet, add:

```markdown
- **`tt workspace list [--task <task-id>] [--quiet] [--repo PATH]`** — List all jj workspaces for the current repository. For each workspace, shows: a `*` marker on the current workspace, the jj workspace name, the tt task or project ID (nearest ancestor tt bookmark in the working copy ancestry, or `(none)` if none), and the filesystem path (with `$HOME` abbreviated as `~`, or `(none)` if no path is recorded). Output is a columnar table with a header row. With `--task <task-id>`, filters to only workspaces whose resolved TASK ID matches the given task or project ID (exit 1 if the ID is not a valid task/project ID format). With `--quiet`, prints only the jj workspace names (one per line), with no header or table; compatible with `--task` for machine-readable lookups. Intended for quick overview of all active task workspaces and for scripting. See §5.3.
```

Do **not** add a new alias for this command.

---

## Task list

- [ ] 1. Create a new jj commit before making any changes (`jj new -m "Implement tt workspace list"`)
- [ ] 2. Add `jj_commit` helper to `scripts/harness/harness.sh`
- [ ] 3. Create `scripts/cli/workspace/list` (executable bash script)
- [ ] 4. Make the script executable: `chmod +x scripts/cli/workspace/list`
- [ ] 5. Create `scripts/cli/workspace/list.test.sh`
- [ ] 6. Make the test script executable: `chmod +x scripts/cli/workspace/list.test.sh`
- [ ] 7. Run the tests and confirm they pass: `bash scripts/cli/workspace/list.test.sh`
- [ ] 8. Update `DESIGN.md` §5.3 to document `tt workspace list`
- [ ] 9. Run full workspace test suite to confirm no regressions
- [ ] 10. Commit all changes
