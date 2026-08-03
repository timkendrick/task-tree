---
title: "Implementation Plan"
created: 2026-08-03T16:55:43Z
updated: 2026-08-03T16:55:43Z
---
# Plan: Add `--rebase` / `--merge` arguments to `tt task checkout`

Task: `task/tt-task-checkout-rebase-merge-83ec3101`

---

## 1. Background & Motivation

`tt` is a task-tree CLI whose bootstrap implementation lives in `scripts/cli/`. It uses
`jj` (Jujutsu) as its backing VCS store. Each task in the tree is a jj bookmark
(branch) named `task/<slug>-<8hex>` (or `project/<slug>-<8hex>` for parentless
projects). A task's parent is discovered by scanning all bookmarks for a task file
containing a `subtask: [ ] <task-id>` frontmatter entry.

Today, `tt task checkout <task-id>` simply moves the working copy onto the task's
bookmark. It does **not** bring in any commits that have landed on the parent branch
since the child was forked. If the parent has moved on, the user starts work on a
stale base and only discovers the divergence at checkin time.

`tt task checkin` already solves the equivalent problem with mutually-exclusive
`--rebase` / `--merge` flags, which delegate to `tt task propagate` before performing
the checkin. This task adds the same pair of flags to `tt task checkout`.

---

## 2. Existing code — research findings

### 2.1 `scripts/cli/task/checkout` — current flow

The script is a single `main()` function. The relevant ordering is:

1. **Argument parsing** — a `while [[ $# -gt 0 ]]` loop over `--worktree`,
   `--worktree=*`, `--switch`, `--force`, `--repo`, `-h|--help`, a catch-all `-*`
   that prints usage and exits 1, and a positional `<task-id>`.
2. **Post-parse validation** — `task_id` required; `--switch` requires `--worktree`.
3. `repo="$(resolve_repo "$repo")"`, then `task_prefix`/`project_prefix` are read via
   `get_task_prefix` / `get_project_prefix`.
4. **ID format validation** — must satisfy `is_task_branch` or `is_project_branch`.
5. **Bookmark existence check** — `jj log -r "$task_id"`.
6. **Derive slug and task file path**:
   ```bash
   local task_slug task_file
   if is_task_branch "$task_id" "$task_prefix"; then
     task_slug="${task_id#"$task_prefix"}"
   else
     task_slug="${task_id#"$project_prefix"}"
   fi
   task_file="$(task_file_path "$task_slug")"
   ```
7. **Read task frontmatter from the bookmark** (this block will MOVE — see §3.4):
   ```bash
   local task_file_content task_title task_status
   task_file_content="$(jj_show_at_revision "$repo" "$task_id" "$task_file")" || true
   task_title="$(parse_quoted_frontmatter_field "$task_file_content" "title")"
   task_status="$(parse_frontmatter_field "$task_file_content" "status")"

   local needs_begin=false
   if [[ "$task_status" == "TODO" ]]; then
     needs_begin=true
   fi
   ```
8. Resolve `workspace_dir`, `current_worktree`, `previous_task_id`,
   `previous_task_branch`.
9. **Determine `target_worktree`** and run the dirty-working-copy gate. Two paths:
   - `--worktree` given: locate/derive the workspace path, guard against a second
     workspace at a different path, then either mark `new_worktree=true` (fresh) or,
     for an existing workspace, run `is_wc_clean "$target_worktree"` and **error unless
     `--force`** (with `--force` it logs a warning and continues).
   - No `--worktree`: `target_worktree="$current_worktree"`, same
     `is_wc_clean` / `--force` gate.
10. `tt_begin_transaction "$repo"`
11. **Perform the checkout** — one of `jj workspace add`, `jj -R "$target_worktree" new
    "$task_id"`, or `jj -R "$repo" new "$task_id"`.
12. **"Begin task" commit** when `needs_begin` — creates the `TASK.md` symlink, flips
    `status: TODO` → `status: IN-PROGRESS` via `awk`, describes the WC with
    `[tt:task:<id>:checkout] <title>`, sets the bookmark, then `jj new @`.
13. HEAD symlink update + `pre-checkout` / `post-checkout` hooks (or hooks-only when
    `--worktree` without `--switch`).
14. `setup` hook for new worktrees.
15. `tt_commit_transaction "$repo"`, log messages, and finally
    `printf '%s\n' "$target_worktree"` to stdout.

### 2.2 `scripts/cli/task/checkin` — the pattern to mirror

Argument parsing (mutual exclusion enforced by rejecting a conflicting second value):

```bash
--rebase)
  [[ -n "$strategy" && "$strategy" != rebase ]] && { usage >&2; exit 1; }
  strategy='rebase'; shift ;;
--merge)
  [[ -n "$strategy" && "$strategy" != merge ]] && { usage >&2; exit 1; }
  strategy='merge'; shift ;;
```

Note this idiom permits a repeated identical flag (`--rebase --rebase`) but rejects
`--rebase --merge`. We will reuse it verbatim for consistency.

The propagation block, run after `tt_begin_transaction`:

```bash
if [[ -n "$strategy" ]]; then
  log "Propagating parent ($strategy) into child before checkin..."
  "$SCRIPT_DIR/propagate" \
    --from "$parent_bookmark" \
    --to "$child_bookmark" \
    --"$strategy" \
    ${force:+--force} \
    --repo "$repo"
  # Re-check WC is clean after propagation
  if ! is_wc_clean "$child_worktree"; then
    log "Error: Working copy not clean after propagation."
    exit 1
  fi
fi
```

Parent resolution in checkin:

```bash
local parent_bookmark
parent_bookmark="$(find_parent_branch "$repo" "$task_id" "$task_prefix" "$project_prefix")" || {
  local rc=$?
  [[ $rc -eq 1 ]] && log "Error: No parent branch found containing subtask entry for '$task_id'."
  exit 1
}
```

### 2.3 `find_parent_branch` (`scripts/cli/lib/common.sh:490`)

Enumerates all local bookmarks, skips non-task/project bookmarks and `$task_id`
itself, reads each candidate's task file, and greps for
`^subtask:[[:space:]]*\[[[:space:]x\-]\][[:space:]]+${task_id}([[:space:]]|$)`.
Prints the parent bookmark name on stdout. Exit code `1` means "not found"; other
non-zero codes indicate ambiguity (multiple parents), for which the helper logs its own
error message. This is why checkin only prints the "No parent branch found" message
when `rc -eq 1`.

### 2.4 `scripts/cli/task/propagate` — behaviour relied upon

- Invocation form used here: `propagate --from <parent> --to <child> --rebase|--merge --repo <repo>`.
- `--to` is repeatable and restricts propagation to the named child/children.
- `propagate_one_rebase` runs `jj rebase -s "roots(::${child} ~ ::${from})" -d "$from"`,
  then, **unless `--force`**, checks `has_conflicts "$repo" "${child}::"` and
  `exit 1`s with `Error: Conflicts detected in <child> after rebase onto <from>.`
- `propagate_one_merge` runs `jj new "$child" "$from"` + `jj bookmark set "$child"`,
  then, unless `--force`, checks `has_conflicts "$repo" "$child"` and `exit 1`s with
  `Error: Conflicts in <child> after merging <from>.` It restores the working copy with
  `jj edit "$original_rev"` afterwards.
- `is_up_to_date` short-circuits the whole thing when the child has nothing to pull, so
  passing `--rebase` on an already-current task is a cheap no-op.

Because propagate already refuses on conflict and we deliberately **do not** forward
`--force`, no additional `has_conflicts` guard is needed in `checkout`.

### 2.5 Transactions (`DESIGN.md` §… "Transactions")

`tt_begin_transaction REPO` records a before-op ID in `.tt/history` and installs an
`ERR` trap. Any non-zero exit triggers `tt_rollback_transaction`, which runs
`jj op restore <before-op-id>`, atomically undoing every jj operation performed since.
Nested sub-commands inherit `TT_TRANSACTION_ID` via the environment and their
`tt_begin_transaction` becomes a no-op, so a `propagate` invoked from inside checkout's
transaction is covered by checkout's rollback. This is precisely why the propagate step
must sit **after** `tt_begin_transaction`.

### 2.6 Test harness

- Harness: `scripts/harness/harness.sh`. Suites are `scripts/cli/**/<cmd>.test.sh`,
  each ending with `run_tests "tt task <cmd>"`.
- Runner: `scripts/test`, e.g. `scripts/test task/checkout`, or
  `scripts/test task/checkout --filter <pattern>`.
- Relevant helpers: `setup_workspace`, `create_project`, `create_task`,
  `create_task_under`, `checkout_task`, `checkpoint_task`, `edit_file`, `run_tt`,
  `get_bookmark_commit`, `read_file_at_rev`, `file_exists_at_rev`.
- Relevant assertions: `assert_success`, `assert_failure`, `assert_eq`,
  `assert_contains`, `assert_is_ancestor`, `assert_not_ancestor`, `assert_task_status`,
  `assert_current_task`, `assert_wc_clean`, `assert_no_conflicts`,
  `assert_file_on_branch`, `assert_no_pending_transaction`, `assert_history_integrity`,
  `assert_required_usage_argument`, `assert_optional_usage_argument`,
  `assert_usage_command_name`.
- Existing suite: `scripts/cli/task/checkout.test.sh` (14 tests, ending with
  `test_task_checkout__help`).

---

## 3. Design decisions

### 3.1 Flags

Add two new mutually-exclusive optional flags to `tt task checkout`:

| Flag | Meaning |
| --- | --- |
| `--rebase` | Before checking out, rebase this task's unmerged commits onto the parent branch's current tip. |
| `--merge` | Before checking out, merge the parent branch's current tip into this task's branch. |

Neither flag is required. When neither is given, `checkout` behaves exactly as it does
today (no parent lookup, no propagation, no new failure modes).

### 3.2 Placement in the flow

The propagation runs **inside the transaction, immediately after
`tt_begin_transaction` and before the `jj new` / `jj workspace add` step** (between
current steps 10 and 11 in §2.1).

Rationale:
- Being inside the transaction means a propagation failure (e.g. a rebase conflict)
  triggers checkout's `ERR` trap → `tt_rollback_transaction` → `jj op restore`,
  leaving the repository exactly as it was.
- Running before `jj new` means the working copy is created on top of the *updated*
  bookmark tip, so the user lands directly on the propagated state.

All pre-existing validation (ID format, bookmark existence, dirty-WC gate, worktree
conflict checks) happens *before* propagation, so we never mutate history for a
checkout that was going to fail anyway.

### 3.3 Error cases (only when `--rebase` / `--merge` is given)

Both of these are gated on `-n "$strategy"` — i.e. a plain `tt task checkout` of a
project branch, or of an orphaned task, keeps working exactly as today.

1. **Project branch.** Projects are parentless by definition. Passing `--rebase` or
   `--merge` with a `project/…` ID exits 1:
   ```
   Error: --rebase/--merge require a task branch.
     'project/foo-abc12345' is a project branch and has no parent.
   ```
   This is checked early, right after the existing ID-format validation, so it fails
   before any repository mutation and before the transaction opens.

2. **No parent found.** For a task branch whose subtask entry cannot be located,
   `find_parent_branch` fails and we exit 1 with the same message checkin uses:
   ```
   Error: No parent branch found containing subtask entry for 'task/foo-abc12345'.
   ```

### 3.4 `--force` is NOT forwarded to propagate

Unlike `checkin`, `checkout` does **not** pass `${force:+--force}` to `propagate`.
`checkout --force` means "clobber/ignore a dirty working copy"; it should not silently
also mean "accept a conflicted rebase". Propagation therefore always refuses on
conflict, and the user must resolve the conflict (or run `tt task propagate --force`
explicitly) before checking out.

### 3.5 Post-propagation working-copy check

`checkin` hard-fails on a dirty WC with no escape hatch, so its post-propagation
`is_wc_clean` is a pure invariant assertion. `checkout` has `--force`, which
*deliberately* permits a dirty WC — copying the check verbatim would make
`checkout --force --rebase` always fail.

Propagation can only dirty a previously-clean working copy when the target workspace's
WC commit is a descendant of a branch propagate rewrites (i.e. re-checking-out a task
you are already sitting on, or a descendant of it); `jj` rebases the WC commit along
with the branch and materializes conflict markers into the files.

The check is therefore made conditional on `--force` not having been given:

```bash
if [[ "$force" != true ]] && ! is_wc_clean "$target_worktree"; then
  log "Error: Working copy not clean after propagation."
  exit 1
fi
```

### 3.6 No explicit conflict guard

`propagate` already exits 1 on conflicts when `--force` is absent (§2.4), and we never
forward `--force`, so it always fails loudly first. No `has_conflicts` call is added to
`checkout`.

### 3.7 Frontmatter read moves after propagation

The `task_file_content` / `task_title` / `task_status` / `needs_begin` block (§2.1
step 7) is relocated to sit immediately **after** the propagation step, so state is
read from the post-propagation bookmark tip.

**Verified safe.** An audit of the intervening code confirms none of these four
variables is referenced between their current definition site and the new one:

- `task_slug` and `task_file` are derived purely from `$task_id` and the configured
  prefixes; they are *not* moved (they stay at step 6) because `task_file` is an input
  to the frontmatter read and `task_slug` is used later in the "Begin task" block.
- `needs_begin` is read only in the "Begin task" block (step 12) — after the new site.
- `task_title` is read only in the `format_commit_message` call inside the "Begin task"
  block — after the new site.
- `task_status` is read only to compute `needs_begin`.
- Steps 8–11 (`workspace_dir`, `current_worktree`, `previous_task_id`,
  `target_worktree` determination, dirty-WC gate, `tt_begin_transaction`, `jj new`)
  reference none of them.

---

## 4. Implementation

### 4.1 `scripts/cli/task/checkout` — header comment

Replace the usage comment block near the top:

```bash
# tt task checkout — switch to a task or project branch.
#
# Usage:
#   checkout <task-id> [--worktree[=<path>] [--switch]] [--rebase | --merge] [--force] [--repo PATH]
#
# Options:
#   <task-id>            Task or project ID (required)
#   --worktree[=<path>]  Use or create a dedicated jj workspace for this task.
#                        Without =<path>, derives path from <workspace-dir>/<task-id>.
#   --switch             (only with --worktree) Also update the HEAD symlink to the new
#                        worktree. Without this flag, HEAD is not updated when --worktree
#                        is used.
#   --rebase             Rebase the task onto its parent's tip before checking out.
#   --merge              Merge the parent's tip into the task before checking out.
#   --force              Proceed even if the target workspace has local changes.
#   --repo PATH          Repository root (overrides TT_REPO; default: walk up from CWD to find .jj).
```

### 4.2 `scripts/cli/task/checkout` — `usage()`

```bash
usage() {
  cat <<EOF
Usage: ${COMMAND_NAME:-$SCRIPT_NAME} <task-id> [--worktree[=<path>] [--switch]] [--rebase | --merge] [--force] [--repo PATH]

Switch to the given task or project branch.

Arguments:
  <task-id>  Task or project ID (e.g. task/foo-abc12345, project/bar-deadbeef)

Options:
  --worktree[=<path>]  Use or create a dedicated jj workspace for this task.
                        If no path given, defaults to <workspace-dir>/<task-id>
                        (resolved from the .tt/workspace symlink).
  --switch              (only with --worktree) Also update the HEAD symlink to the
                        new worktree. Without this flag, HEAD is not updated when
                        --worktree is used.
  --rebase              Rebase the task onto its parent's current tip before
                        checking out. Not valid for project branches.
  --merge               Merge the parent's current tip into the task before
                        checking out. Not valid for project branches.
  --force               Proceed even if the target workspace has local changes.
  --repo PATH           Repository root (overrides TT_REPO; default: walk up from CWD to find .jj).

Examples:
  ${COMMAND_NAME:-$SCRIPT_NAME} task/foo-abc12345
  ${COMMAND_NAME:-$SCRIPT_NAME} task/foo-abc12345 --worktree
  ${COMMAND_NAME:-$SCRIPT_NAME} task/foo-abc12345 --worktree --switch
  ${COMMAND_NAME:-$SCRIPT_NAME} task/foo-abc12345 --worktree=/path/to/workspace
  ${COMMAND_NAME:-$SCRIPT_NAME} task/foo-abc12345 --rebase
  ${COMMAND_NAME:-$SCRIPT_NAME} task/foo-abc12345 --merge
  ${COMMAND_NAME:-$SCRIPT_NAME} task/foo-abc12345 --force

EOF
}
```

### 4.3 `scripts/cli/task/checkout` — local declaration

Add to the block of `local` declarations at the top of `main()`:

```bash
  local strategy=''
```

### 4.4 `scripts/cli/task/checkout` — argument parsing

Insert two new cases into the `while` loop, after the `--switch` case and before
`--force`:

```bash
      --rebase)
        [[ -n "$strategy" && "$strategy" != rebase ]] && { usage >&2; exit 1; }
        strategy='rebase'
        shift
        ;;
      --merge)
        [[ -n "$strategy" && "$strategy" != merge ]] && { usage >&2; exit 1; }
        strategy='merge'
        shift
        ;;
```

### 4.5 `scripts/cli/task/checkout` — project-branch rejection

Immediately after the existing ID-format validation block (which ends with
`exit 1` / `fi`), and before the `local jj_opts=(-R "$repo")` line, insert:

```bash
  # --rebase/--merge pull changes from the parent branch; project branches have no parent.
  if [[ -n "$strategy" ]] && is_project_branch "$task_id" "$project_prefix"; then
    log "Error: --rebase/--merge require a task branch."
    log "  '$task_id' is a project branch and has no parent."
    exit 1
  fi
```

### 4.6 `scripts/cli/task/checkout` — remove the early frontmatter read

Delete this block (currently sitting just after the `task_file=` assignment):

```bash
  # Read task frontmatter from the bookmark
  local task_file_content task_title task_status
  task_file_content="$(jj_show_at_revision "$repo" "$task_id" "$task_file")" || true
  task_title="$(parse_quoted_frontmatter_field "$task_file_content" "title")"
  task_status="$(parse_frontmatter_field "$task_file_content" "status")"

  # Determine if "Begin task" commit is needed.
  # Status TODO means the task hasn't been initialized via checkout yet.
  # (TASK.md may exist on the branch via ancestor inheritance but point to a different task.)
  local needs_begin=false
  if [[ "$task_status" == "TODO" ]]; then
    needs_begin=true
  fi
```

### 4.7 `scripts/cli/task/checkout` — propagation + relocated read

Immediately after `tt_begin_transaction "$repo"` and before the
`# Perform the checkout` comment, insert:

```bash
  # --- Optional: rebase/merge parent into this task before checking out ---
  # Runs inside the transaction so a propagation failure rolls the whole command back.
  if [[ -n "$strategy" ]]; then
    local parent_bookmark
    parent_bookmark="$(find_parent_branch "$repo" "$task_id" "$task_prefix" "$project_prefix")" || {
      local rc=$?
      [[ $rc -eq 1 ]] && log "Error: No parent branch found containing subtask entry for '$task_id'."
      exit 1
    }

    log "Propagating parent ($strategy) into task before checkout..."
    "$SCRIPT_DIR/propagate" \
      --from "$parent_bookmark" \
      --to "$task_id" \
      --"$strategy" \
      --repo "$repo"

    # If the working copy was clean going in, it must still be clean. Skipped under
    # --force, where a dirty working copy was explicitly permitted up front.
    if [[ "$force" != true ]] && ! is_wc_clean "$target_worktree"; then
      log "Error: Working copy not clean after propagation."
      exit 1
    fi
  fi

  # Read task frontmatter from the bookmark (after any propagation, so the values
  # reflect the branch's current tip).
  local task_file_content task_title task_status
  task_file_content="$(jj_show_at_revision "$repo" "$task_id" "$task_file")" || true
  task_title="$(parse_quoted_frontmatter_field "$task_file_content" "title")"
  task_status="$(parse_frontmatter_field "$task_file_content" "status")"

  # Determine if "Begin task" commit is needed.
  # Status TODO means the task hasn't been initialized via checkout yet.
  # (TASK.md may exist on the branch via ancestor inheritance but point to a different task.)
  local needs_begin=false
  if [[ "$task_status" == "TODO" ]]; then
    needs_begin=true
  fi
```

> **Note on `is_wc_clean "$target_worktree"` for a brand-new worktree.** When
> `new_worktree=true` the directory does not exist yet at this point. Guard against
> that by only running the check when the worktree already exists:
> `if [[ "$force" != true ]] && [[ "$new_worktree" != true ]] && ! is_wc_clean ...`.
> This is included in the final code.

Final form of the guard:

```bash
    if [[ "$force" != true ]] && [[ "$new_worktree" != true ]] && ! is_wc_clean "$target_worktree"; then
      log "Error: Working copy not clean after propagation."
      exit 1
    fi
```

### 4.8 `DESIGN.md`

Three edits.

**(a) §5 command reference, the `tt task checkout` bullet (currently line ~322).**
Replace:

> - **`tt task checkout <task-id> [--worktree [=<path>] [--switch]] [--force]`** — Switch to the given task branch. …

with:

> - **`tt task checkout <task-id> [--worktree [=<path>] [--switch]] [--rebase | --merge] [--force]`** — Switch to the given task branch. With `--worktree`, uses or creates a dedicated jj workspace for that task; otherwise uses the closest ancestor task workspace or the current workspace. With `--rebase` or `--merge` (mutually exclusive), first pulls any changes from the parent task into this task by running `tt task propagate --from <parent> --to <task-id>` with the chosen strategy, before switching the working copy; only valid for task branches (project branches have no parent). Refuses if the target workspace has local changes unless `--force`. Updates task status to IN-PROGRESS if TODO, runs `setup` hook when creating a new worktree. Without `--worktree`, always updates the virtual project's `HEAD` symlink; with `--worktree`, only updates `HEAD` if `--switch` is also provided (`--switch` is only valid with `--worktree`). On success, prints the worktree path to stdout (all other output is on stderr). See §6.2.

**(b) §6.2 "Checkout behavior".** Insert a new paragraph after the
"Multiple worktree prevention." paragraph and before the "**Output:**" paragraph:

> **Pulling parent changes (`--rebase` / `--merge`).** By default, checking out a task does not bring in commits that have landed on its parent branch since the task was forked. The mutually-exclusive `--rebase` and `--merge` flags change this: before switching the working copy, the tool locates the task's parent branch (the branch whose task file registers a `subtask:` entry for this task) and runs `tt task propagate --from <parent> --to <task-id>` with the chosen strategy, so the working copy is created on top of the updated tip. Both flags are only valid for task branches; passing either with a project branch is an error, since projects are parentless. If no parent branch can be found for the task, the command fails. Propagation runs inside the command's transaction, so a rebase or merge conflict aborts the whole checkout and rolls the repository back to its prior state. `--force` is **not** forwarded to the propagation step: it only governs the dirty-working-copy check, and conflicts always abort. To check out a task despite propagation conflicts, run `tt task propagate --force` explicitly first. Passing `--rebase` or `--merge` when the task is already up to date with its parent is a no-op.

**(c) §9 workflow walkthrough, step 4 "Begin a task" (currently line ~1003).**
Replace the signature and add a clause:

> 4. **Begin a task** — `tt task checkout <task-id> [--worktree [=<path>] [--switch]] [--rebase | --merge] [--force]`. The tool checks the target workspace is clean (or clobbers changes if `--force` is specified), verifies the task or project branch exists, optionally pulls parent changes into the task with `--rebase` or `--merge` (see §6.2), uses or creates the appropriate workspace per §6.2, sets task status to IN-PROGRESS in a new commit if the task status is currently TODO, runs `setup` when initializing a new worktree, and updates the `HEAD` symlink (unless `--worktree` is used without `--switch`). See §6.2.

### 4.9 `scripts/cli/task/checkout.test.sh`

Insert the following tests immediately before `test_task_checkout__help`, and extend
the help test.

```bash
test_task_checkout__rebase_pulls_parent_changes() {
  setup_workspace "checkout-rebase"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  # Initialize the child branch, then return to the parent and add a commit there.
  checkout_task "$task_id" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true
  edit_file "parent-file.txt" "from parent"
  checkpoint_task "Parent update" >/dev/null || true

  assert_not_ancestor "parent tip not yet in child" "$proj_id" "$task_id"

  output="" exit_code=0
  output=$(run_tt task checkout "$task_id" --rebase 2>&1) || exit_code=$?
  assert_success "checkout --rebase succeeds" "$exit_code"
  assert_is_ancestor "parent tip is ancestor of child" "$proj_id" "$task_id"
  assert_file_on_branch "parent file present on child" "$task_id" "parent-file.txt"
  assert_current_task "WC on task branch" "$task_id"
  assert_no_conflicts "no conflicts after rebase"
  assert_no_pending_transaction "transaction closed"
}


test_task_checkout__merge_pulls_parent_changes() {
  setup_workspace "checkout-merge"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true

  checkout_task "$task_id" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true
  edit_file "parent-file.txt" "from parent"
  checkpoint_task "Parent update" >/dev/null || true

  assert_not_ancestor "parent tip not yet in child" "$proj_id" "$task_id"

  output="" exit_code=0
  output=$(run_tt task checkout "$task_id" --merge 2>&1) || exit_code=$?
  assert_success "checkout --merge succeeds" "$exit_code"
  assert_is_ancestor "parent tip is ancestor of child" "$proj_id" "$task_id"
  assert_file_on_branch "parent file present on child" "$task_id" "parent-file.txt"
  assert_current_task "WC on task branch" "$task_id"
  assert_no_conflicts "no conflicts after merge"
  assert_no_pending_transaction "transaction closed"
}


test_task_checkout__rebase_and_merge_together_rejected() {
  setup_workspace "checkout-rebase-merge-conflict"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task checkout "$task_id" --rebase --merge 2>&1) || exit_code=$?
  assert_failure "--rebase --merge rejected" "$exit_code"
  assert_contains "usage shown" "$output" "Usage:"
}


test_task_checkout__rebase_on_project_branch_rejected() {
  setup_workspace "checkout-rebase-project"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt task checkout "$proj_id" --rebase 2>&1) || exit_code=$?
  assert_failure "--rebase on project branch rejected" "$exit_code"
  assert_contains "error mentions task branch" "$output" "require a task branch"
}


test_task_checkout__merge_on_project_branch_rejected() {
  setup_workspace "checkout-merge-project"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt task checkout "$proj_id" --merge 2>&1) || exit_code=$?
  assert_failure "--merge on project branch rejected" "$exit_code"
  assert_contains "error mentions task branch" "$output" "require a task branch"
}


test_task_checkout__rebase_conflict_rolls_back() {
  setup_workspace "checkout-rebase-conflict"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # Shared file on the parent, established before the child is forked.
  edit_file "shared.txt" "base"
  checkpoint_task "Add shared file" >/dev/null || true

  task_id=$(create_task "mytask" "My Task") || true

  # Child edits the shared file one way...
  checkout_task "$task_id" >/dev/null || true
  edit_file "shared.txt" "child version"
  checkpoint_task "Child edit" >/dev/null || true

  # ...and the parent edits it another way.
  checkout_task "$proj_id" >/dev/null || true
  edit_file "shared.txt" "parent version"
  checkpoint_task "Parent edit" >/dev/null || true

  task_before=$(get_bookmark_commit "$task_id")
  proj_before=$(get_bookmark_commit "$proj_id")

  output="" exit_code=0
  output=$(run_tt task checkout "$task_id" --rebase 2>&1) || exit_code=$?
  assert_failure "conflicting --rebase rejected" "$exit_code"
  assert_contains "error mentions conflicts" "$output" "Conflicts"

  assert_eq "task bookmark unchanged" "$task_before" "$(get_bookmark_commit "$task_id")"
  assert_eq "project bookmark unchanged" "$proj_before" "$(get_bookmark_commit "$proj_id")"
  assert_current_task "still on parent branch" "$proj_id"
  assert_no_pending_transaction "no dangling transaction"
}


test_task_checkout__rebase_when_already_up_to_date_is_no_op() {
  setup_workspace "checkout-rebase-noop"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mytask" "My Task") || true
  checkout_task "$task_id" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  bm_before=$(get_bookmark_commit "$task_id")

  output="" exit_code=0
  output=$(run_tt task checkout "$task_id" --rebase 2>&1) || exit_code=$?
  assert_success "checkout --rebase succeeds" "$exit_code"
  assert_eq "task bookmark unchanged" "$bm_before" "$(get_bookmark_commit "$task_id")"
  assert_current_task "WC on task branch" "$task_id"
}
```

Extend `test_task_checkout__help` with:

```bash
  assert_required_usage_argument "argument: --rebase" "$output" "--rebase"
  assert_required_usage_argument "argument: --merge" "$output" "--merge"
```

> If `assert_required_usage_argument` proves to be the wrong matcher for a bracketed
> alternation like `[--rebase | --merge]`, fall back to
> `assert_contains "usage lists --rebase" "$output" "--rebase"` (and likewise for
> `--merge`). Verify against the harness implementation at
> `scripts/harness/harness.sh:1461` during implementation.

### 4.10 Verification

```bash
shellcheck scripts/cli/task/checkout
scripts/test task/checkout
scripts/test task/checkin
scripts/test task/propagate
scripts/test task/create      # exercises `create --checkout`
scripts/test                  # full suite
```

---

## 5. Task list

- [ ] Create a VCS checkpoint commit before starting.
- [ ] `scripts/cli/task/checkout`: update the header usage comment (§4.1).
- [ ] `scripts/cli/task/checkout`: update `usage()` (§4.2).
- [ ] `scripts/cli/task/checkout`: add `local strategy=''` (§4.3).
- [ ] `scripts/cli/task/checkout`: add `--rebase` / `--merge` parsing cases (§4.4).
- [ ] `scripts/cli/task/checkout`: add the project-branch rejection (§4.5).
- [ ] `scripts/cli/task/checkout`: remove the early frontmatter read (§4.6).
- [ ] `scripts/cli/task/checkout`: add the propagation block and relocated frontmatter
      read after `tt_begin_transaction` (§4.7).
- [ ] Run `shellcheck scripts/cli/task/checkout`; fix any warnings.
- [ ] Commit the CLI change.
- [ ] `DESIGN.md`: update the §5 command-reference bullet (§4.8a).
- [ ] `DESIGN.md`: add the §6.2 "Pulling parent changes" paragraph (§4.8b).
- [ ] `DESIGN.md`: update the §9 step-4 walkthrough (§4.8c).
- [ ] Commit the docs change.
- [ ] `scripts/cli/task/checkout.test.sh`: add the seven new tests (§4.9).
- [ ] `scripts/cli/task/checkout.test.sh`: extend `test_task_checkout__help` (§4.9).
- [ ] Run `scripts/test task/checkout` and make it pass.
- [ ] Run the full `scripts/test` suite and confirm no regressions.
- [ ] Commit the tests.
- [ ] Present a summary for review (RAPID Phase 2).

---

## 6. Decision log

| # | Decision | Rationale |
| --- | --- | --- |
| 1 | Propagate runs inside the transaction, after `tt_begin_transaction`, before `jj new`. | Failures roll back cleanly via the existing `ERR` trap; the working copy lands on the updated tip. |
| 2 | `--rebase`/`--merge` on a project branch is an error. | Projects are parentless; silently ignoring would hide a user mistake. |
| 3 | The project-branch and no-parent errors fire **only** when `--rebase`/`--merge` is given. | Plain `tt task checkout` of a project or an orphaned task must keep working exactly as today. |
| 4 | No parent found → exit 1 with checkin's wording. | Consistency with `tt task checkin`. |
| 5 | `--force` is **not** forwarded to `propagate`. | `--force` means "ignore a dirty working copy", not "accept a conflicted rebase". |
| 6 | Post-propagation `is_wc_clean` assertion, skipped under `--force` (and for brand-new worktrees). | Preserves checkin's invariant ("clean in ⇒ clean out") without breaking `--force --rebase`. |
| 7 | No explicit `has_conflicts` guard in `checkout`. | `propagate` already refuses on conflict and `--force` is never forwarded, so it always fails first. |
| 8 | Propagate is invoked as `--from <parent> --to <task-id> --<strategy>`. | Mirrors `checkin` exactly; `--to` scopes propagation to just this branch. `--shallow` is redundant given `--to`. |
| 9 | Frontmatter read (`task_title`/`task_status`/`needs_begin`) moves to after propagation. | Reads current state once, post-mutation. Audited as safe — no intervening consumer (§3.7). |
| 10 | Mutual exclusion uses checkin's `[[ -n "$strategy" && "$strategy" != X ]]` idiom. | Consistency; tolerates a repeated identical flag, rejects conflicting flags. |

---

## 7. Questionnaire transcript

**Round 1**

- *Where in the checkout flow should the propagate step run?*
  → **Inside transaction, before `jj new`** (recommended option).
- *`tt task checkout` also accepts project branches, which have no parent. What should `--rebase`/`--merge` do there?*
  → **Error out.** User note: *"only error out when `--rebase` or `--merge` are specified; keep existing behavior for checking-out orphaned subtasks when these flags are not present."*
- *For a task branch where `find_parent_branch` finds no parent, what should happen?*
  → **Error out.**
- *Should checkout's `--force` be forwarded to the propagate call?*
  → **No, never force propagate.**

**Round 2**

- *Which arguments should the propagate invocation use?*
  → **`--from <parent> --to <task> --<strategy>`.**
- *After propagation, should checkout re-verify the target working copy is clean?*
  → *"this sounds tricky, talk me through the sequence of actions here and let's discuss"* → after the walkthrough in §3.5: **assert only when `--force` was not given.**
- *Should checkout verify the task branch is conflict-free after propagation?*
  → **No, rely on propagate's own check.**
- *Which test scenarios should be added?*
  → `--merge` on a project branch rejected; transaction rollback behaviour when the workspace contains changes/conflicts. (The `--rebase`/`--merge` happy paths and the mutual-exclusion test are retained as baseline coverage.)

**Round 3**

- *Given the above, how should the post-propagation working-copy check behave?*
  → **Assert only when `--force` was not given.**
- *Should `task_status`/`task_title`/`needs_begin` be re-read after propagation?*
  → **Move the read to after propagate.** User note: *"determine that this won't break existing logic."* → audited in §3.7.
- *Which failure should the rollback test exercise?*
  → **Propagate conflict rolls back checkout.**
