---
title: "Implementation Plan"
created: 2026-08-03T20:19:59Z
updated: 2026-08-03T20:19:59Z
---
# Plan: Allow `tt task checkout` of already-completed tasks

Task: `task/tt-task-checkout-completed-f90d8d12`

## 1. Goal

1. `tt task checkout <task-id>` on a task whose `status` is `DONE` must **reopen** it: create a
   `[tt:task:<task-id>:checkout] <title>` commit on the task branch that sets `status: IN-PROGRESS`,
   advance the task bookmark, and leave a clean working copy on top — i.e. exactly the flow used
   today for a `TODO` task's first checkout.
2. Reopening must **not** pull anything from the parent branch. The commit is appended to the
   existing task branch. (Propagation stays opt-in via the existing `--rebase` / `--merge` flags.)
3. `tt task create --parent <parent-id>` against a `DONE` parent must no longer fail. It must first
   reopen the parent by delegating to `tt task checkout <parent-id>`, then create the child as usual.
4. Update `DESIGN.md` and the test suites.

## 2. Research findings (current state of the code)

### `scripts/cli/task/checkout`

Relevant excerpt (around lines 290-345 of 388):

```bash
  # Read task frontmatter from the bookmark (after any propagation, so the values
  # reflect the branch's current tip).
  local task_file_content task_title task_status
  task_file_content="$(jj_show_at_revision "$repo" "$task_id" "$task_file")" || true
  task_title="$(parse_quoted_frontmatter_field "$task_file_content" "title")"
  task_status="$(parse_frontmatter_field "$task_file_content" "status")"

  # Determine if "Begin task" commit is needed.
  local needs_begin=false
  if [[ "$task_status" == "TODO" ]]; then
    needs_begin=true
  fi

  # Perform the checkout
  if [[ "$new_worktree" == true ]]; then
    ...
    jj "${jj_opts[@]}" workspace add --name "$task_id" -r "$task_id" "$target_worktree" >&2
    ...
  elif [[ "$worktree_flag" == true ]]; then
    jj -R "$target_worktree" new "$task_id" >&2
  else
    jj "${jj_opts[@]}" new "$task_id" >&2
  fi

  # Create "Begin task" commit if TASK.md doesn't yet exist on the branch
  if [[ "$needs_begin" == true ]]; then
    log "Initializing task: $task_id"

    ln -sf ".tt/task/${task_slug}/TASK.md" "$target_worktree/TASK.md"
    log "Created TASK.md -> .tt/task/${task_slug}/TASK.md"

    local tmpfile
    tmpfile="$(mktemp)"
    awk '
      /^---$/ { n++; print; next }
      n == 1 && /^status:/ { print "status: IN-PROGRESS"; next }
      { print }
    ' "$target_worktree/$task_file" > "$tmpfile"
    mv "$tmpfile" "$target_worktree/$task_file"

    jj -R "$target_worktree" describe -m "$(format_commit_message "task" "checkout" "$task_id" "$task_title")" >&2
    jj -R "$target_worktree" bookmark set "$task_id" >&2
    jj -R "$target_worktree" new "@" >&2
  fi
```

So today a `DONE` task falls through to a plain `jj new "$task_id"`: the working copy moves onto the
branch tip but nothing is committed and the status stays `DONE`. The whole "begin" block is already
worktree-agnostic and idempotent w.r.t. the `TASK.md` symlink (`ln -sf` produces no diff when the
symlink already exists on the branch, which it always does for a previously checked-out task).

### `scripts/cli/task/create`

Lines 352-360 (the check to remove):

```bash
  # Refuse to create a child under a completed (DONE) parent task.
  if [[ -n "$parent_task_file" ]]; then
    local parent_status
    parent_status="$(jj_show_at_revision "$repo" "$parent_bookmark" "$parent_task_file" \
      | awk '/^status:/ { print $2; exit }')"
    if [[ "$parent_status" == "DONE" ]]; then
      log "Error: Parent task '$parent_bookmark' has status DONE. Completed tasks are immutable; create new tasks under a different parent."
      exit 1
    fi
  fi
```

Ordering constraints inside `create` `main()`:

* `parent_rev`, `parent_task_file`, `parent_bookmark` are resolved early (lines ~266-274) via
  `resolve_parent`. `parent_rev` is a **commit id**, so it becomes stale once the parent bookmark
  advances. Reopening the parent advances that bookmark, so `parent_rev` must be re-resolved after
  the reopen.
* `original_rev` / `current_bookmark` / `restore_to_parent` are captured immediately after the DONE
  check (lines ~362-378). These must be captured **before** the reopen, because the reopen moves the
  working copy.
* `tt_begin_transaction "$repo"` happens after the bookmark-exists check. The reopen must run
  **inside** the transaction so a later failure rolls it back. Nested `tt` commands inherit
  `TT_TRANSACTION_ID` via the environment (`scripts/cli/lib/common.sh:1206`, `:1239`), so calling
  `"$SCRIPT_DIR/checkout"` inside the transaction is a no-op w.r.t. transaction bookkeeping — exactly
  how `--checkout` is already handled at the end of `create`.
* The main task creation then runs `jj "${jj_opts[@]}" new "$parent_rev"` and edits
  `$repo/$parent_task_file` in the working copy, so the parent file already contains the reopened
  `status: IN-PROGRESS` — no extra handling needed.

### DESIGN.md touch points

| Line | Content |
|---|---|
| 267 | `tt task create` command reference |
| 322 | `tt task checkout` command reference ("Updates task status to IN-PROGRESS if TODO") |
| 398 | Commit-message table row for `[tt:task:<task-id>:checkout] <title>` |
| 471 | §6.1 rule: "The parent task's `status` must not be `DONE`. Completed tasks are immutable…" |
| 508-522 | §6.2 Checkout behavior |
| 606 | §6.4 note about `tt task complete` |
| 1003, 1005 | §11 workflow walkthrough steps 3 and 4 |

## 3. Decisions (from user questionnaire)

| Question | Decision |
|---|---|
| Commit message for the reopen commit | Reuse the existing `[tt:task:<id>:checkout] <title>` kind; no new commit kind |
| Which statuses trigger the status-updating commit | `TODO` **or** `DONE` (`IN-PROGRESS` stays a plain no-op checkout) |
| Reset parent's `subtask: [x]` entry to `[-]` on reopen? | No — checkout never touches the parent branch; the next `tt task checkin` handoff already writes `[-]` for an `IN-PROGRESS` child |
| Missing-bookmark handling | Unchanged — checkout still errors with "Task not found". "New branch created as per standard flow" refers to the pre-existing fresh-branch path |
| How should `create` reopen a `DONE` parent | Delegate to `scripts/cli/task/checkout` (DRY, single implementation) |
| Automatic or opt-in reopen in `create` | Automatic (replaces the error with a log message) |
| Working-copy position after creating under a reopened parent | Existing restore logic, unchanged |
| Test coverage | Focused scenarios **plus** edge cases (`--worktree`, reopen→checkin, DONE project branch, `--rebase`) |

### Questionnaire transcript

1. *What commit message should the reopen commit use?* → **Reuse `:checkout` commit kind**
2. *Which statuses should trigger the status-updating checkout commit?* → **TODO or DONE**
3. *Should the parent's `subtask: [x]` entry be reset to `[-]`?* → **No — leave parent untouched**
4. *"If the task branch does not already exist…" interpretation?* → **No change to missing-bookmark handling**
5. *How should `tt task create --parent <DONE parent>` reopen the parent?* → **Delegate to `scripts/cli/task/checkout`**
6. *Automatic or opt-in?* → **Automatic**
7. *Working-copy position afterwards?* → **Existing restore logic, unchanged**
8. *Test coverage?* → **Focused + edge cases**

## 4. Implementation

### 4.1 `scripts/cli/task/checkout`

Change the `needs_begin` computation and the log message inside the begin block.

```bash
  # Determine if a status-updating checkout commit is needed.
  # TODO means the task has never been checked out (not yet initialized).
  # DONE means the task was completed and is now being reopened: the commit
  # returns the task to IN-PROGRESS on its existing branch. Nothing is pulled
  # from the parent branch (use --rebase/--merge for that).
  local needs_begin=false
  local reopening=false
  if [[ "$task_status" == "TODO" ]]; then
    needs_begin=true
  elif [[ "$task_status" == "DONE" ]]; then
    needs_begin=true
    reopening=true
  fi
```

and inside the `needs_begin` block, replace the two leading `log` lines:

```bash
  if [[ "$needs_begin" == true ]]; then
    if [[ "$reopening" == true ]]; then
      log "Reopening completed task: $task_id"
    else
      log "Initializing task: $task_id"
    fi

    # Create TASK.md symlink in the worktree root (idempotent when reopening).
    ln -sf ".tt/task/${task_slug}/TASK.md" "$target_worktree/TASK.md"
    log "Created TASK.md -> .tt/task/${task_slug}/TASK.md"
    ...
```

Everything else in the block (the `awk` status rewrite to `IN-PROGRESS`, `jj describe`,
`jj bookmark set`, `jj new "@"`) is reused verbatim.

Also update the `--worktree` / usage comment header? No change needed there. Update the
`checkout` script's top-of-file comment block to mention the reopen behavior:

```bash
# tt task checkout — switch to a task or project branch.
#
# Checking out a task whose status is TODO (never checked out) or DONE (completed)
# creates a [tt:task:<task-id>:checkout] commit setting status to IN-PROGRESS and
# advances the task bookmark. Reopening a DONE task appends this commit to the task's
# existing branch; no parent changes are pulled in unless --rebase/--merge is given.
```

### 4.2 `scripts/cli/task/create`

**Delete** the DONE-refusal block (lines 352-360) and **replace** it with a `parent_is_done` flag
computed at the same place:

```bash
  # Detect a completed (DONE) parent task: it is reopened via `tt task checkout`
  # before the child is created (see §6.1 of DESIGN.md).
  local parent_is_done=false
  if [[ -n "$parent_task_file" ]]; then
    local parent_status
    parent_status="$(jj_show_at_revision "$repo" "$parent_bookmark" "$parent_task_file" \
      | awk '/^status:/ { print $2; exit }')"
    if [[ "$parent_status" == "DONE" ]]; then
      parent_is_done=true
    fi
  fi
```

Then, immediately **after** `tt_begin_transaction "$repo"` and **before**
`jj "${jj_opts[@]}" new "$parent_rev"`, insert the reopen:

```bash
  # Reopen a completed parent before adding the child. `tt task checkout` creates the
  # status -> IN-PROGRESS commit and advances the parent bookmark, so parent_rev
  # (a commit id captured before the reopen) must be re-resolved afterwards.
  if [[ "$parent_is_done" == true ]]; then
    log "Parent task '$parent_bookmark' is DONE; reopening before creating child..."
    "$SCRIPT_DIR/checkout" "$parent_bookmark" --repo "$repo" >/dev/null
    parent_rev="$(jj "${jj_opts[@]}" log -r "$parent_bookmark" -n 1 --no-graph -T 'commit_id')"
  fi
```

Notes:
* `original_rev`, `current_bookmark` and `restore_to_parent` are computed before this point and are
  therefore unaffected; the existing restore logic at the end of `create` runs unchanged.
* `checkout` inherits the transaction via `TT_TRANSACTION_ID`, so a later failure rolls the reopen
  back together with the rest of the command.
* `checkout` prints the worktree path on stdout; it is discarded with `>/dev/null` so `create`'s own
  stdout contract (task ID only) is preserved.
* `checkout` requires a clean working copy; if it is dirty, the reopen fails and the transaction
  rolls back — acceptable and consistent with the rest of the tool.

Update `create`'s usage/comment text if it mentions the DONE restriction (grep for `DONE` in the
file after editing).

### 4.3 DESIGN.md

1. **Line 322** (`tt task checkout` reference) — replace
   "Updates task status to IN-PROGRESS if TODO" with
   "Updates task status to `IN-PROGRESS` if the task is `TODO` (first checkout) or `DONE`
   (reopening a completed task), creating a `[tt:task:<task-id>:checkout] <title>` commit and
   advancing the task bookmark".
2. **Line 398** (commit table) — change the description to
   "First checkout: creates `TASK.md` symlink and sets status → `IN-PROGRESS`; also emitted when
   reopening a `DONE` task (status → `IN-PROGRESS`); advances task bookmark".
3. **§6.2** — add a new paragraph after the "Multiple worktree prevention" paragraph:

   > **Reopening completed tasks.** Checking out a task whose `status` is `DONE` reopens it: the
   > tool creates a `[tt:task:<task-id>:checkout] <title>` commit on the task's existing branch that
   > sets `status` back to `IN-PROGRESS`, advances the task bookmark, and leaves a clean working copy
   > on top — the same flow as the first checkout of a `TODO` task. Reopening never pulls changes
   > from the parent branch: the commit is appended to the branch as it stands. Pass `--rebase` or
   > `--merge` to bring the parent's tip in as well. The parent branch is not modified, so its
   > `subtask:` entry for the task remains `[x]` until the next `tt task checkin`, which rewrites it
   > to `[-]` for an `IN-PROGRESS` child. Checking out a task that is already `IN-PROGRESS` remains a
   > no-op with respect to history.
4. **Line 471** (§6.1 parent rules) — replace the immutability bullet with:

   > - If the parent task's `status` is `DONE`, the parent is **reopened** before the child is
   >   created: the tool runs `tt task checkout <parent-id>` (creating a
   >   `[tt:task:<parent-id>:checkout] <title>` commit that sets the parent's status back to
   >   `IN-PROGRESS`, see §6.2) and then proceeds with the normal creation flow on the updated parent
   >   tip. The working copy is restored to its original position afterwards as usual.
5. **Line 267** (`tt task create` reference) — append a sentence: "If the resolved parent task's
   status is `DONE`, the parent is first reopened by running `tt task checkout <parent-id>` (see
   §6.2), then the child is created on the updated parent tip."
6. **Line 1005** (§11 step 4) — mention "sets task status to IN-PROGRESS in a new commit if the task
   status is currently `TODO` or `DONE` (reopening a completed task)".
7. **Line 1003** (§11 step 3) — append "If the parent is `DONE`, it is reopened first (see §6.2)."

### 4.4 Tests

Harness: `scripts/harness/harness.sh`, sourced by each `*.test.sh`. Existing helpers used below:
`setup_workspace`, `create_project`, `create_task`, `create_task_under`, `checkout_task`,
`complete_task`, `checkin_task`, `run_tt`, `assert_task_status`, `assert_current_task`,
`assert_success`, `assert_failure`, `assert_eq`, `assert_wc_clean`, `get_bookmark_commit`,
`edit_file`. Run with `scripts/test task/checkout` / `scripts/test task/create`.

Add to `scripts/cli/task/checkout.test.sh`:

* `test_task_checkout__reopens_completed_task` — create project + task, checkout, complete, checkout
  the project, then checkout the task again. Assert: success, status `IN-PROGRESS`, bookmark commit
  changed, top commit description is `[tt:task:<id>:checkout] <title>`, WC clean, current task is the
  task.
* `test_task_checkout__reopen_does_not_pull_parent_changes` — after completing the task, add a commit
  on the parent (e.g. `edit_file` + checkpoint on the parent branch), then reopen the child; assert
  the parent's new file is **not** present in the child worktree, and that the reopen commit's parent
  is the previous child bookmark commit.
* `test_task_checkout__reopen_with_worktree` — reopen a completed task with `--worktree`; assert
  status `IN-PROGRESS` and the workspace is created/reused.
* `test_task_checkout__reopen_with_rebase_pulls_parent` — reopen with `--rebase`; assert status
  `IN-PROGRESS` **and** the parent's new file is present.
* `test_task_checkout__reopen_then_checkin_marks_subtask_in_progress` — reopen a completed task, make
  a change, checkin; assert the parent's `subtask:` entry is `[-]`.
* `test_task_checkout__reopens_completed_project` — complete a project branch and check it out again;
  assert status `IN-PROGRESS`.

Add to `scripts/cli/task/create.test.sh` (replacing/adjusting any existing test asserting the DONE
parent error — grep for `DONE` in that file):

* `test_task_create__reopens_completed_parent` — complete a parent task, then
  `tt task create --parent <parent-id> …`; assert: success, parent status `IN-PROGRESS`, parent
  bookmark advanced, the parent's task file contains `subtask: [ ] <child-id>`, and the child branch
  exists with `status: TODO`.

## 5. Verification

```bash
scripts/test task/checkout
scripts/test task/create
scripts/test task/checkin
scripts/test task/complete
scripts/test                # full suite before finishing
shellcheck scripts/cli/task/checkout scripts/cli/task/create
```

## 6. Task list

- [ ] Create a checkpoint commit before starting
- [ ] `scripts/cli/task/checkout`: `needs_begin` covers `DONE`; add `reopening` flag + log message; update header comment
- [ ] `scripts/cli/task/create`: replace the DONE-refusal block with `parent_is_done`; reopen via `checkout` inside the transaction; re-resolve `parent_rev`
- [ ] Add checkout tests (reopen, no parent propagation, `--worktree`, `--rebase`, reopen→checkin, project branch)
- [ ] Add/adjust create tests (reopen completed parent; remove the old error-path test)
- [ ] Update DESIGN.md (§6.1, §6.2, command reference lines 267/322, commit table line 398, §11 steps 3-4)
- [ ] Run `scripts/test` and `shellcheck`; fix any failures
- [ ] Commit
