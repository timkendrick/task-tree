---
title: "Implementation Plan"
created: 2026-04-06T14:18:20Z
updated: 2026-04-06T14:18:20Z
---
# Plan: Implement `tt worktree delete` CLI command

## Task

Allow deleting previously-checked-out task worktrees via `tt worktree delete --task <task-id> [--worktree=<worktree-path>] [--force]`.

## User decisions

1. **Safety checks**: Both dirty WC and commits after the task bookmark should be refused unless `--force` is provided.
2. **HEAD symlink**: If the deleted worktree is the one pointed to by HEAD, reset HEAD to the repo root.
3. **Bookmark**: Do NOT delete the jj bookmark; only forget the workspace and remove files.
4. **DESIGN.md placement**: Add a new §5.5 "Worktree" section after §5.4 Task, which includes both `tt worktree show` (moved from §5.3) and the new `tt worktree delete`.

## Codebase context

### Key existing helpers in `scripts/cli/lib/common.sh`

- `find_worktrees_for_branch REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX` — finds workspace root paths where BOOKMARK is the nearest ancestor bookmark. Returns one path per line.
- `parse_workspace_list_line LINE` — parses a `jj workspace list` line into name + path.
- `is_wc_clean REPO_OR_WORKTREE` — returns 0 if working copy has no pending changes.
- `assert_bookmark_up_to_date REPO BOOKMARK` — exits 1 if commits exist between BOOKMARK and @-; **but** hardcodes an error message about checkpointing, so it can't be reused directly for worktree delete.
- `resolve_repo`, `get_task_prefix`, `get_project_prefix`, `is_task_branch`, `is_project_branch` — standard arg parsing helpers.
- `get_workspace_dir REPO` — reads `.tt/workspace` symlink to find virtual project dir.
- `update_head_symlink WORKSPACE_DIR TARGET_PATH` — updates `<workspace-dir>/HEAD` symlink.
- `tt_begin_transaction REPO`, `tt_commit_transaction REPO` — transaction management.
- `make_absolute_symlink TARGET_PATH SYMLINK_PATH` — creates/replaces a symlink with absolute target.

### Patterns from existing code

- `scripts/cli/task/delete` lines 335–358: workspace forget logic — resolves ws_name from path via `jj workspace list`, then `jj workspace forget`, leaving files on disk with a warning.
- `scripts/cli/workspace/switch` lines 185–191: resolving HEAD symlink target with relative path handling.
- `scripts/cli/workspace/list`: full workspace listing with task ID resolution.

### File structure

```
scripts/cli/worktree/
  show            — existing: outputs worktree path for a task
  show.test.sh    — existing: tests for show
  delete          — NEW: the command to implement
  delete.test.sh  — NEW: tests for delete
```

## Shared helpers to add to `scripts/cli/lib/common.sh`

### Helper 1: `resolve_workspace_name`

Resolves the jj workspace name for a given worktree path. Used by worktree delete and task/delete.

```bash
# Usage: resolve_workspace_name REPO WORKTREE_PATH
# Prints the jj workspace name for the workspace at WORKTREE_PATH.
# Returns 0 and prints name if found, returns 1 if not found.
resolve_workspace_name() {
  local repo="$1" worktree_path="$2"
  local ws_list
  ws_list="$(jj -R "$repo" --ignore-working-copy workspace list \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || return 1
  while IFS= read -r ws_line; do
    [[ -z "$ws_line" ]] && continue
    local parsed ws_name ws_root
    parsed="$(parse_workspace_list_line "$ws_line")"
    ws_name="$(printf '%s' "$parsed" | sed -n '1p')"
    ws_root="$(printf '%s' "$parsed" | sed -n '2p')"
    if [[ "$ws_root" == "$worktree_path" ]]; then
      printf '%s' "$ws_name"
      return 0
    fi
  done <<< "$ws_list"
  return 1
}
```

### Helper 2: `forget_worktree`

Forgets a jj workspace by name and optionally removes files. Used by worktree delete and potentially by task/delete.

```bash
# Usage: forget_worktree REPO WORKSPACE_NAME [WORKTREE_PATH]
# Forgets the jj workspace from the repository model.
# If WORKTREE_PATH is provided, also removes all files from disk.
forget_worktree() {
  local repo="$1" ws_name="$2" worktree_path="${3:-}"
  jj -R "$repo" workspace forget "$ws_name"
  if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
    rm -rf "$worktree_path"
  fi
}
```

### Helper 3: Refactor `assert_bookmark_up_to_date` → `check_bookmark_up_to_date`

The existing `assert_bookmark_up_to_date` in `common.sh` hardcodes an error message and calls `exit 1`. We refactor it into a pure predicate `check_bookmark_up_to_date` that returns 0/1, and move the error messaging to the call site.

**Current code (lines 268–284 of `common.sh`):**
```bash
# Usage: assert_bookmark_up_to_date REPO BOOKMARK
# Exits 1 if there are any commits between BOOKMARK and the working-copy parent
# (@-) that are not tracked by the bookmark. Used by commands that operate on
# the implicit current branch to ensure all work has been checkpointed.
#
# Skip this check when the user passes an explicit task-id, as that constitutes
# an intentional acknowledgement that the bookmark may be behind.
assert_bookmark_up_to_date() {
  local repo="$1" bookmark="$2"
  local ahead_commits
  ahead_commits="$(jj -R "$repo" log \
    -r "(::@- & ~::${bookmark})" \
    --no-graph -T 'change_id ++ "\n"' 2>/dev/null)" || return 0
  if [[ -n "$ahead_commits" ]]; then
    log "Error: There are commits since the last checkpoint that are not tracked by the task bookmark."
    log "  Run 'tt task checkpoint' to record them before checking in."
    log "  Alternatively, pass the task ID explicitly to skip this check:"
    log "    tt task checkin ${bookmark}"
    exit 1
  fi
}
```

**New code:**
```bash
# Usage: check_bookmark_up_to_date REPO BOOKMARK
# Returns 0 if there are no commits between BOOKMARK and the working-copy parent
# (@-) that are not tracked by the bookmark. Returns 1 if commits exist.
check_bookmark_up_to_date() {
  local repo="$1" bookmark="$2"
  local ahead_commits
  ahead_commits="$(jj -R "$repo" log \
    -r "(::@- & ~::${bookmark})" \
    --no-graph -T 'change_id ++ "\n"' 2>/dev/null)" || return 0
  [[ -z "$ahead_commits" ]]
}

# Usage: assert_bookmark_up_to_date REPO BOOKMARK
# Exits 1 if there are any commits between BOOKMARK and the working-copy parent
# (@-) that are not tracked by the bookmark. Used by commands that operate on
# the implicit current branch to ensure all work has been checkpointed.
#
# Skip this check when the user passes an explicit task-id, as that constitutes
# an intentional acknowledgement that the bookmark may be behind.
assert_bookmark_up_to_date() {
  local repo="$1" bookmark="$2"
  if ! check_bookmark_up_to_date "$repo" "$bookmark"; then
    log "Error: There are commits since the last checkpoint that are not tracked by the task bookmark."
    log "  Run 'tt task checkpoint' to record them before checking in."
    log "  Alternatively, pass the task ID explicitly to skip this check:"
    log "    tt task checkin ${bookmark}"
    exit 1
  fi
}
```

This way:
- `assert_bookmark_up_to_date` keeps its existing behavior (log + exit) for the `checkin` call site
- `check_bookmark_up_to_date` is the reusable predicate that `worktree delete` uses
- No call site changes needed for `scripts/cli/task/checkin`

### Helper 4: `resolve_head_worktree`

Resolves the worktree path that the virtual project's HEAD symlink currently points to. Used by worktree delete and workspace/switch.

```bash
# Usage: resolve_head_worktree WORKSPACE_DIR REPO
# Resolves the worktree path that HEAD currently points to.
# Falls back to REPO if HEAD is not a symlink or doesn't exist.
# Always returns an absolute path.
resolve_head_worktree() {
  local workspace_dir="$1" repo="$2"
  local head_path="${workspace_dir}/HEAD"
  if [[ -n "$workspace_dir" && -L "$head_path" ]]; then
    local head_target
    head_target="$(readlink "$head_path")" || true
    if [[ -n "$head_target" ]]; then
      # Resolve relative symlink
      if [[ "$head_target" != /* ]]; then
        head_target="${workspace_dir}/${head_target}"
      fi
      # Canonicalize (returns repo if target doesn't exist)
      local resolved
      resolved="$(cd "$head_target" 2>/dev/null && pwd)" || resolved="$repo"
      printf '%s' "$resolved"
      return 0
    fi
  fi
  printf '%s' "$repo"
}
```

## Step-by-step implementation

### Step 1: Add shared helpers to `scripts/cli/lib/common.sh`

Add the four helpers above to `common.sh`, in the workspace/worktree section (after `find_worktrees_for_branch`).

Also refactor `scripts/cli/task/delete` to use `resolve_workspace_name` instead of its inline implementation (lines 340–348).

Also add `check_bookmark_up_to_date` predicate helper, keeping `assert_bookmark_up_to_date` as a thin wrapper.

### Step 2: Create `scripts/cli/worktree/delete` command script

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

# tt worktree delete — Delete a task's worktree.
#
# Usage:
#   delete --task <task-id> [--worktree=<path>] [--force] [--repo PATH]
#
# Forgets the jj workspace and removes all files from the worktree path.
# The task bookmark is NOT deleted.
#
# Options:
#   --task <task-id>       Required. Task or project ID.
#   --worktree=<path>      Disambiguate when task has multiple worktrees.
#   --force                Skip safety checks (dirty WC, commits after bookmark).
#   --repo PATH            Repository root.
#   -h, --help             Show this help.

readonly SCRIPT_NAME="${0##*/}"

usage() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} --task <task-id> [--worktree=<path>] [--force] [--repo PATH]

Delete a task's worktree. Forgets the jj workspace and removes all files.
The task bookmark is NOT deleted.

Arguments:
  --task <task-id>       Task or project ID (required)

Options:
  --worktree=<path>      Disambiguate when task has multiple worktrees.
  --force                Skip safety checks (dirty WC, commits after bookmark).
  --repo PATH            Repository root (overrides TT_REPO; default: find .jj).
  -h, --help             Show this help.

Examples:
  ${SCRIPT_NAME} --task task/foo-abc12345
  ${SCRIPT_NAME} --task task/foo-abc12345 --worktree=/path/to/worktree
  ${SCRIPT_NAME} --task task/foo-abc12345 --force

EOF
  exit 1
}

main() {
  local task_id=''
  local worktree_arg=''
  local force=false
  local repo=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task)
        [[ $# -lt 2 ]] && { log "Error: --task requires an argument"; usage; }
        task_id="$2"; shift 2 ;;
      --worktree=*)
        worktree_arg="${1#--worktree=}"; shift ;;
      --force)
        force=true; shift ;;
      --repo)
        [[ $# -lt 2 ]] && { log "Error: --repo requires an argument"; usage; }
        repo="$2"; shift 2 ;;
      -h|--help) usage ;;
      *)
        log "Error: Unknown option: $1"; usage ;;
    esac
  done

  if [[ -z "$task_id" ]]; then
    log "Error: --task <task-id> is required"
    usage
  fi

  repo="$(resolve_repo "$repo")"

  local task_prefix project_prefix
  task_prefix="$(get_task_prefix "$repo")"
  project_prefix="$(get_project_prefix "$repo")"

  # Validate task_id format
  if ! is_task_branch "$task_id" "$task_prefix" && ! is_project_branch "$task_id" "$project_prefix"; then
    log "Error: '$task_id' is not a recognized task or project ID"
    log "  Expected prefix '$task_prefix' or '$project_prefix' with 8-hex suffix"
    exit 1
  fi

  # Verify the bookmark exists
  if ! jj -R "$repo" log -r "$task_id" --no-graph -T '' 2>/dev/null; then
    log "Error: Task '$task_id' not found in repository"
    exit 1
  fi

  # Resolve workspace dir via .tt/workspace symlink
  local workspace_dir
  workspace_dir="$(get_workspace_dir "$repo")" || true

  # Find worktrees for this task
  local found_worktrees wt_count
  found_worktrees="$(find_worktrees_for_branch "$repo" "$task_id" "$task_prefix" "$project_prefix")"
  wt_count="$(printf '%s' "$found_worktrees" | grep -c . 2>/dev/null || true)"

  local target_worktree

  if [[ "$wt_count" -eq 0 ]]; then
    log "Error: No worktree found for '$task_id'"
    exit 1
  fi

  # Disambiguation
  if [[ "$wt_count" -gt 1 ]]; then
    if [[ -z "$worktree_arg" ]]; then
      log "Error: Multiple worktrees found for '$task_id'; use --worktree=<path>:"
      printf '%s\n' "$found_worktrees" | while IFS= read -r p; do log "  $p"; done
      exit 1
    fi
    if ! printf '%s\n' "$found_worktrees" | grep -qxF "$worktree_arg"; then
      log "Error: --worktree=$worktree_arg is not a worktree for '$task_id'"
      log "  Available worktrees:"
      printf '%s\n' "$found_worktrees" | while IFS= read -r p; do log "    $p"; done
      exit 1
    fi
    target_worktree="$worktree_arg"
  else
    target_worktree="$(printf '%s' "$found_worktrees" | head -1)"
    if [[ -n "$worktree_arg" && "$worktree_arg" != "$target_worktree" ]]; then
      log "Error: --worktree=$worktree_arg does not match the worktree for '$task_id'"
      log "  Found worktree: $target_worktree"
      exit 1
    fi
  fi

  # Safety checks (skip with --force)
  if [[ "$force" != true ]]; then
    if ! is_wc_clean "$target_worktree"; then
      log "Error: Worktree '$target_worktree' has uncommitted changes."
      log "  Commit or discard changes first, or use --force."
      exit 1
    fi
    if ! check_bookmark_up_to_date "$target_worktree" "$task_id"; then
      log "Error: Worktree has commits after the task bookmark '$task_id'."
      log "  Checkpoint or discard these commits first, or use --force."
      exit 1
    fi
  fi

  # Resolve jj workspace name
  local ws_name
  ws_name="$(resolve_workspace_name "$repo" "$target_worktree")" || {
    log "Error: Could not resolve jj workspace name for '$target_worktree'"
    exit 1
  }

  # Begin transaction
  tt_begin_transaction "$repo"

  # Forget workspace and remove files
  forget_worktree "$repo" "$ws_name" "$target_worktree"

  # If HEAD points to the deleted worktree, reset it to repo root
  if [[ -n "$workspace_dir" ]]; then
    local head_worktree
    head_worktree="$(resolve_head_worktree "$workspace_dir" "$repo")"
    if [[ "$head_worktree" == "$target_worktree" ]]; then
      update_head_symlink "$workspace_dir" "$repo"
    fi
  fi

  # Commit transaction
  tt_commit_transaction "$repo"

  log "Deleted worktree: $target_worktree"
  log "  Task: $task_id"
  log "  Workspace '$ws_name' forgotten from jj"
}

main "$@"
```

### Step 3: Create `scripts/cli/worktree/delete.test.sh`

Test scenarios (13 tests):

1. **Basic delete** — Create task, checkout with --worktree, delete worktree. Verify workspace forgotten, files removed.
2. **Task with no worktree** — Error when no worktree exists for the task.
3. **Non-existent task** — Error for invalid/unknown task ID.
4. **Invalid task ID format** — Error for malformed task ID.
5. **Dirty WC** — Error when worktree has uncommitted changes.
6. **Dirty WC with --force** — Succeeds despite dirty WC.
7. **Commits after bookmark** — Error when worktree has commits after the task bookmark (without checkpoint).
8. **Commits after bookmark with --force** — Succeeds despite commits after bookmark.
9. **HEAD symlink reset** — HEAD is reset to repo root when the deleted worktree was the current HEAD.
10. **HEAD symlink not changed** — HEAD is left alone when it points to a different worktree.
11. **Transaction recording** — Verify the command records a history entry with integrity.
12. **Bookmark preserved** — Verify the task bookmark is NOT deleted after worktree delete.
13. **Multiple worktrees require disambiguation** — Error when multiple worktrees and no --worktree flag.

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_worktree_delete__basic_delete() {
  setup_workspace "wt-del-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  # Get worktree path
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  assert_not_eq "worktree is not repo" "$worktree_path" "$REPO"
  assert_file_exists "worktree dir exists" "$worktree_path"

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_success "delete succeeds" "$exit_code"
  assert_file_not_exists "worktree dir removed" "$worktree_path"
  assert_bookmark_exists "bookmark preserved" "$task_id"
}


test_worktree_delete__no_worktree_found() {
  setup_workspace "wt-del-noexist"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  # Don't checkout with --worktree

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "no worktree rejected" "$exit_code"
  assert_contains "error mentions no worktree" "$output" "No worktree found"
}


test_worktree_delete__nonexistent_task() {
  setup_workspace "wt-del-notask"
  output="" exit_code=0
  output=$(run_tt worktree delete --task "task/nonexistent-00000000" 2>&1) || exit_code=$?
  assert_failure "non-existent task rejected" "$exit_code"
}


test_worktree_delete__invalid_task_id() {
  setup_workspace "wt-del-invalid"
  output="" exit_code=0
  output=$(run_tt worktree delete --task "not-a-valid-id" 2>&1) || exit_code=$?
  assert_failure "invalid task ID rejected" "$exit_code"
}


test_worktree_delete__dirty_wc_rejected() {
  setup_workspace "wt-del-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  # Make the worktree dirty
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  echo "dirty" > "$worktree_path/dirty-file.txt"

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
  assert_contains "mentions uncommitted" "$output" "uncommitted changes"
}


test_worktree_delete__dirty_wc_force() {
  setup_workspace "wt-del-dirty-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  echo "dirty" > "$worktree_path/dirty-file.txt"

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" --force 2>&1) || exit_code=$?
  assert_success "--force succeeds with dirty WC" "$exit_code"
  assert_file_not_exists "worktree dir removed" "$worktree_path"
}


test_worktree_delete__commits_after_bookmark_rejected() {
  setup_workspace "wt-del-ahead"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  # Create a commit but don't checkpoint (bookmark falls behind)
  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  echo "some work" > "$worktree_path/work.txt"
  jj -R "$worktree_path" commit -m "Some work" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "commits after bookmark rejected" "$exit_code"
  assert_contains "mentions bookmark" "$output" "bookmark"
}


test_worktree_delete__commits_after_bookmark_force() {
  setup_workspace "wt-del-ahead-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true
  echo "some work" > "$worktree_path/work.txt"
  jj -R "$worktree_path" commit -m "Some work" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" --force 2>&1) || exit_code=$?
  assert_success "--force succeeds with commits after bookmark" "$exit_code"
  assert_file_not_exists "worktree dir removed" "$worktree_path"
}


test_worktree_delete__head_symlink_reset() {
  setup_workspace "wt-del-head"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  worktree_path=$(run_tt worktree show "$task_id" 2>/dev/null) || true

  # Verify HEAD points to the worktree
  local head_target
  head_target=$(readlink "$VIRTUAL/HEAD") || true
  assert_contains "HEAD points to worktree" "$head_target" "$task_id"

  run_tt worktree delete --task "$task_id" >/dev/null 2>&1 || true

  # Verify HEAD now points to repo
  head_target=$(readlink "$VIRTUAL/HEAD") || true
  assert_eq "HEAD reset to repo" "$head_target" "$REPO"
}


test_worktree_delete__head_symlink_unchanged() {
  setup_workspace "wt-del-head-no"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # Create two tasks with worktrees
  task_a=$(create_task "task-a" "Task A") || true
  run_tt task checkout "$task_a" --worktree --switch >/dev/null 2>&1 || true
  task_b=$(create_task "task-b" "Task B") || true
  run_tt task checkout "$task_b" --worktree --switch >/dev/null 2>&1 || true

  # HEAD now points to task_b's worktree. Delete task_a's worktree.
  worktree_a=$(run_tt worktree show "$task_a" 2>/dev/null) || true

  run_tt worktree delete --task "$task_a" >/dev/null 2>&1 || true

  # HEAD should still point to task_b
  local head_target
  head_target=$(readlink "$VIRTUAL/HEAD") || true
  assert_contains "HEAD unchanged, still task_b" "$head_target" "$task_b"
}


test_worktree_delete__records_transaction() {
  setup_workspace "wt-del-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt worktree delete --task "$task_id" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after delete"
}


test_worktree_delete__bookmark_preserved() {
  setup_workspace "wt-del-bm"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  checkpoint_task "Work" >/dev/null || true

  run_tt worktree delete --task "$task_id" >/dev/null 2>&1 || true

  assert_bookmark_exists "bookmark still exists" "$task_id"
}


test_worktree_delete__multiple_worktrees_requires_disambiguation() {
  setup_workspace "wt-del-multi"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "my-task" "My Task") || true

  # Create two worktrees for the same task
  run_tt task checkout "$task_id" --worktree="$VIRTUAL/${task_id}-a" >/dev/null 2>&1 || true
  run_tt task checkout "$task_id" --worktree="$VIRTUAL/${task_id}-b" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt worktree delete --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "multiple worktrees without disambiguation rejected" "$exit_code"
  assert_contains "mentions multiple" "$output" "Multiple worktrees"
}


run_tests "tt worktree delete"
```

### Step 4: Update DESIGN.md

#### 4a. Remove `tt worktree show` from §5.3 Workspace

Remove the line at approximately line 233:
```
- **`tt worktree show <task-id> [--repo PATH]`** — Output the worktree path for the given task or project ID to stdout. ...
```

#### 4b. Add new §5.5 Worktree section after §5.4 Task (before `## 6.`)

Insert between the end of §5.4 and `## 6. Task and branch operations`:

```markdown
### 5.5 Worktree

- **`tt worktree show <task-id> [--repo PATH]`** — Output the worktree path for the given task or project ID to stdout. Accepts a full task or project ID. Falls back to the repository root if no dedicated worktree exists for the task. Exits with an error if the task ID is not found in the repository. Intended for use in shell command substitution.

- **`tt worktree delete --task <task-id> [--worktree=<path>] [--force] [--repo PATH]`** — Delete a task's jj worktree. Locates the worktree via the mandatory `--task <task-id>` argument; with `--worktree=<path>`, used to disambiguate tasks checked out in multiple worktrees (the provided path must have the specified task as its most recent task bookmark). If the worktree cannot be located (no worktree exists with the task bookmark as its direct ancestor), exits with an error. If the worktree contains uncommitted changes or has commits more recent than the task bookmark, exits with an error unless `--force` is specified. Forgets the jj workspace and removes all files from the worktree path. The task bookmark is NOT deleted. If the virtual project's `HEAD` symlink points to the deleted worktree, it is reset to the repository root.
```

### Step 5: Refactor `scripts/cli/task/delete` to use `resolve_workspace_name`

Replace the inline workspace name resolution in `task/delete` (lines 340–348) with a call to `resolve_workspace_name`.

## File changes summary

| File | Action |
|------|--------|
| `scripts/cli/lib/common.sh` | Edit — add 3 shared helpers + refactor `assert_bookmark_up_to_date` into predicate + wrapper |
| `scripts/cli/worktree/delete` | Create — new command script |
| `scripts/cli/worktree/delete.test.sh` | Create — test suite (13 tests) |
| `scripts/cli/task/delete` | Edit — refactor to use `resolve_workspace_name` |
| `DESIGN.md` | Edit — add §5.5, remove worktree show from §5.3 |

## Task list

- [ ] Add shared helpers to `scripts/cli/lib/common.sh`
- [ ] Create `scripts/cli/worktree/delete` command script
- [ ] Create `scripts/cli/worktree/delete.test.sh` test suite
- [ ] Refactor `scripts/cli/task/delete` to use `resolve_workspace_name`
- [ ] Update DESIGN.md (add §5.5, move worktree show from §5.3)
- [ ] Run tests and verify all pass
- [ ] Commit changes
