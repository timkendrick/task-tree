---
title: "Implementation Plan"
created: 2026-04-23T07:14:54Z
updated: 2026-04-23T07:14:54Z
---
# Plan: Standardize Commit Messages Across All Commands

## Overview

All `jj` commit messages produced by `tt` CLI commands are to be standardized to a consistent machine-readable format:

```
[tt:<namespace>:<id>:<operation>] <human-readable description>
```

The bracket section identifies the operation in a structured, machine-parseable way. The description is taken from the relevant task/context title (or a fixed string for workspace init). For checkpoint commits, the user-supplied message is used directly as the description (and may be multi-line).

---

## Source Code Context

All command scripts live under:
```
scripts/cli/
  lib/common.sh          — shared helpers (no commit messages here)
  workspace/init         — workspace init command
  task/create            — task create command
  task/checkout          — task checkout command
  task/checkpoint        — task checkpoint command
  task/complete          — task complete command
  task/checkin           — task checkin command
  task/delete            — task delete command
  task/edit              — task edit command
  task/move              — task move command
  task/rename            — task rename command
  task/reorder           — task reorder command
  task/context/add       — task context add command
  task/context/delete    — task context delete command
```

There are no helper functions for commit message generation in `common.sh` — each command currently constructs its commit message inline.

---

## Complete Commit Message Mapping

### All current → new transformations

| Command | Commit type | Current message | New message |
|---|---|---|---|
| `workspace init` | init | `Create workspace` | `[tt:workspace:init] Create workspace` |
| `task create` (project) | create | `Create project: My project description` | `[tt:task:project/my-project-ab123456:create] My project description` |
| `task create` (child, on parent branch) | create | `Create task: My task description (task/my-task-ab123456)` | `[tt:task:task/my-task-ab123456:create] My task description` |
| `task edit` (also called by create for initial metadata) | edit | `Edit task: My updated title (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:edit] My updated title` |
| `task checkout` | checkout | `Begin task: My task description (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:checkout] My task description` |
| `task checkpoint` | checkpoint | `Checkpoint: Began implementing feature (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:checkpoint] Began implementing feature` |
| `task complete` | complete | `Complete task: My task description (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:complete] My task description` |
| `task checkin` (handoff, on child branch) | handoff | `Handoff: My task description (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:handoff] My task description` |
| `task checkin` (merge, on parent branch) | checkin | `Merge subtask: My task description (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:checkin] My task description` |
| `task delete` (on parent branch) | delete | `Remove subtask: My task description (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:delete] My task description` |
| `task context add` | context:add | `Add context: Implementation plan (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:context:add] Implementation plan` |
| `task context delete` | context:delete | `Delete context: Implementation plan (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:context:delete] Implementation plan` |
| `task move` (old parent branch, removing task) | remove | `Move task: My task description (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:remove] My task description` |
| `task move` (new parent branch, adding task) | move | `Move task: My task description (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:move] My task description` |
| `task rename` (parent branch commit) | rename | `<re-used existing commit message>` | `[tt:task:task/new-name-ab123456:rename] My task description` |
| `task reorder` modifier mode (on parent branch) | reorder | `Reorder subtask: My child task description (task/child-ab123456)` | `[tt:task:task/parent-ab123456:reorder] Parent task description` |
| `task reorder` tidy mode (on task's own branch) | reorder | `Reorder task: My task description (task/foo-ab123456)` | `[tt:task:task/foo-ab123456:reorder] My task description` |

### Notes on specific cases

**`task create`**: Two commits are made. First, on the parent branch (a `create` commit), which registers the stub and subtask entry — the message uses the **child** task ID (the task being created). Second, on the child branch (an `edit` commit) to set full metadata — this is handled by the `edit` subcommand and uses the `edit` operation.

**`task checkin`**: Produces two commits. The first (`handoff`) is on the child branch. The second (`checkin`) is on the parent branch. Both use the child task's ID as the identifier, since both relate to the task being checked in.

**`task move`**: Produces two commits. The first is on the old parent branch (removing the task from its subtask list) — uses `remove` operation. The second is on the new parent branch (adding the task) — uses `move` operation. Both use the task-being-moved's ID.

**`task rename`**: The parent branch commit currently re-uses the existing commit message verbatim. In the new format, it uses the **new** task ID (post-rename) with the `rename` operation.

**`task reorder` modifier mode**: The commit is on the **parent** branch (the file being modified is the parent's TASK.md). The identifier uses the **parent** task ID, and the description uses the **parent** task description.

**`task checkpoint`**: The description is the user-supplied checkpoint message, not the task title. Multi-line messages are supported (lines separated by a blank line following the first line).

**`task edit`** (called during `task create`): The `edit` subcommand is called after creating a task to set the title, body, and labels. The message uses the **updated** metadata (the newly-set title).

---

## Implementation Approach

### Helper function in `common.sh`

Add a single helper function `format_commit_message` to `scripts/cli/lib/common.sh` that constructs the standardized commit message:

```bash
# Usage: format_commit_message NAMESPACE OPERATION ENTITY_ID DESCRIPTION
#
# Constructs a standardized tt commit message:
#   [tt:<namespace>:<entity-id>:<operation>] <description>
#
# When ENTITY_ID is empty (e.g. workspace operations), uses:
#   [tt:<namespace>:<operation>] <description>
#
# DESCRIPTION may be multi-line for checkpoint commits.
#
# Arguments:
#   NAMESPACE   — the command namespace, e.g. "workspace", "task"
#   OPERATION   — the operation name, e.g. "create", "edit", "checkpoint", etc.
#   ENTITY_ID   — the full task ID, e.g. "task/foo-ab123456" or "project/my-ab123456"
#                 (empty string for workspace-level operations)
#   DESCRIPTION — human-readable description (title, user message, etc.)
#
# Outputs the formatted commit message to stdout.
format_commit_message() {
  local namespace="$1"
  local operation="$2"
  local entity_id="$3"
  local description="$4"

  if [[ -z "$entity_id" ]]; then
    printf '[tt:%s:%s] %s' "$namespace" "$operation" "$description"
  else
    printf '[tt:%s:%s:%s] %s' "$namespace" "$entity_id" "$operation" "$description"
  fi
}
```

This function is called at the point of each `jj commit` or `jj describe` invocation, replacing the inline string construction.

---

## Implementation Steps — File by File

### 1. `scripts/cli/lib/common.sh`

Add the `format_commit_message` helper function near the top of the "VCS file-read helpers" section (after the existing helpers, before the slug helpers).

### 2. `scripts/cli/workspace/init`

**Location**: line 223
```bash
# Before:
jj -R "$repo_abs" commit -m "Create workspace"

# After:
jj -R "$repo_abs" commit -m "$(format_commit_message "workspace" "init" "" "Create workspace")"
```

### 3. `scripts/cli/task/create`

Three locations:

**Line 421** (project task create):
```bash
# Before:
jj "${jj_opts[@]}" describe -m "Create project: $title"

# After:
jj "${jj_opts[@]}" describe -m "$(format_commit_message "task" "create" "$task_id" "$title")"
```

**Line 441** (child task with identifiable parent):
```bash
# Before:
jj "${jj_opts[@]}" describe -m "Create task: $title ($task_id)"

# After:
jj "${jj_opts[@]}" describe -m "$(format_commit_message "task" "create" "$task_id" "$title")"
```

**Line 454** (child task without identifiable parent):
```bash
# Before:
jj "${jj_opts[@]}" describe -m "Create task: $title ($task_id)"

# After:
jj "${jj_opts[@]}" describe -m "$(format_commit_message "task" "create" "$task_id" "$title")"
```

### 4. `scripts/cli/task/checkout`

**Line 295**:
```bash
# Before:
jj -R "$target_worktree" describe -m "Begin task: $task_title ($task_id)"

# After:
jj -R "$target_worktree" describe -m "$(format_commit_message "task" "checkout" "$task_id" "$task_title")"
```

### 5. `scripts/cli/task/checkpoint`

**Line ~132** (where `full_msg` is constructed) and **lines ~156/161/164** (where it is used):

```bash
# Before:
local full_msg="Checkpoint: ${message} (${bookmark})"

# After:
local full_msg
full_msg="$(format_commit_message "task" "checkpoint" "$bookmark" "$message")"
```

The three `jj commit -m "$full_msg"` calls at lines 156, 161, 164 remain unchanged (they already use `$full_msg`).

### 6. `scripts/cli/task/complete`

**Line 191**:
```bash
# Before:
jj -R "$target_worktree" commit -m "Complete task: $task_title ($bookmark)"

# After:
jj -R "$target_worktree" commit -m "$(format_commit_message "task" "complete" "$bookmark" "$task_title")"
```

### 7. `scripts/cli/task/checkin`

**Line 407** (handoff):
```bash
# Before:
jj -R "$target_ws" commit -m "Handoff: $task_title ($task_id)"

# After:
jj -R "$target_ws" commit -m "$(format_commit_message "task" "handoff" "$task_id" "$task_title")"
```

**Line 430** (merge/checkin):
```bash
# Before:
jj -R "$target_ws" describe -m "Merge subtask: $task_title ($task_id)"

# After:
jj -R "$target_ws" describe -m "$(format_commit_message "task" "checkin" "$task_id" "$task_title")"
```

### 8. `scripts/cli/task/complete`

Already covered above.

### 9. `scripts/cli/task/delete`

**Line 326**:
```bash
# Before:
jj -R "$target_ws" commit -m "Remove subtask: $task_title ($task_id)"

# After:
jj -R "$target_ws" commit -m "$(format_commit_message "task" "delete" "$task_id" "$task_title")"
```

### 10. `scripts/cli/task/edit`

Two locations (cross-branch and same-branch):

**Line 319** (cross-branch):
```bash
# Before:
jj -R "$repo" commit -m "Edit task: $final_title ($bookmark)"

# After:
jj -R "$repo" commit -m "$(format_commit_message "task" "edit" "$bookmark" "$final_title")"
```

**Line 350** (same-branch):
```bash
# Before:
jj -R "$target_worktree" commit -m "Edit task: $final_title ($bookmark)"

# After:
jj -R "$target_worktree" commit -m "$(format_commit_message "task" "edit" "$bookmark" "$final_title")"
```

### 11. `scripts/cli/task/move`

Two locations:

**Line 259** (old parent — `remove` operation):
```bash
# Before:
jj -R "$repo" describe -m "Move task: $task_title ($task_id)"
jj -R "$repo" bookmark set "$old_parent"

# After:
jj -R "$repo" describe -m "$(format_commit_message "task" "remove" "$task_id" "$task_title")"
jj -R "$repo" bookmark set "$old_parent"
```

**Line 292** (new parent — `move` operation):
```bash
# Before:
jj -R "$repo" describe -m "Move task: $task_title ($task_id)"
jj -R "$repo" bookmark set "$new_parent_id"

# After:
jj -R "$repo" describe -m "$(format_commit_message "task" "move" "$task_id" "$task_title")"
jj -R "$repo" bookmark set "$new_parent_id"
```

### 12. `scripts/cli/task/rename`

The rename command currently re-uses the parent's existing commit message via:
```bash
local parent_msg
parent_msg=$(jj "${jj_opts[@]}" log -r @ --no-graph -T 'description.first_line()')
jj "${jj_opts[@]}" commit -m "$parent_msg"
```

**Line 249** — replace with:
```bash
jj "${jj_opts[@]}" commit -m "$(format_commit_message "task" "rename" "$new_id" "$task_title")"
```

Note: `$task_title` and `$new_id` are already in scope at this point in the rename script.

The `parent_msg` local variable and its assignment can then be removed as they are no longer needed.

### 13. `scripts/cli/task/reorder`

Two locations within the `reorder_subtask` and `reorder_frontmatter` functions:

**In `reorder_subtask`** (modifier mode, parent branch commit) — currently:
```bash
jj -R "$parent_worktree" commit -m "Reorder subtask: $child_title ($child_id)" >/dev/null 2>&1
```

Change to:
```bash
jj -R "$parent_worktree" commit -m "$(format_commit_message "task" "reorder" "$parent_id" "$parent_title")" >/dev/null 2>&1
```

Note: `$parent_title` is already parsed from frontmatter as `$PARSED_TITLE` → `parent_title` in the `reorder_subtask` function.

**In `reorder_frontmatter`** (tidy mode, task's own branch commit) — currently:
```bash
jj -R "$canonical_worktree" commit -m "Reorder task: $title ($task_id)" >/dev/null 2>&1
```

Change to:
```bash
jj -R "$canonical_worktree" commit -m "$(format_commit_message "task" "reorder" "$task_id" "$title")" >/dev/null 2>&1
```

### 14. `scripts/cli/task/context/add`

Two locations:

**Line 284** (cross-branch path):
```bash
# Before:
jj -R "$repo" commit -m "Add context: $ctx_title ($bookmark)"

# After:
jj -R "$repo" commit -m "$(format_commit_message "task" "context:add" "$bookmark" "$ctx_title")"
```

**Line 289** (same-branch path):
```bash
# Before:
jj -R "$target_worktree" commit -m "Add context: $ctx_title ($bookmark)"

# After:
jj -R "$target_worktree" commit -m "$(format_commit_message "task" "context:add" "$bookmark" "$ctx_title")"
```

### 15. `scripts/cli/task/context/delete`

**Line 213**:
```bash
# Before:
jj -R "$target_worktree" commit -m "Delete context: $ctx_title ($branch)"

# After:
jj -R "$target_worktree" commit -m "$(format_commit_message "task" "context:delete" "$branch" "$ctx_title")"
```

---

## Test File Updates

Each command script has a corresponding `.test.sh` file. Tests that assert on commit message content must be updated to match the new format. Known test files with commit message assertions:

- `scripts/cli/workspace/init.test.sh`
- `scripts/cli/task/create.test.sh`
- `scripts/cli/task/checkout.test.sh`
- `scripts/cli/task/checkpoint.test.sh`
- `scripts/cli/task/complete.test.sh`
- `scripts/cli/task/checkin.test.sh`
- `scripts/cli/task/delete.test.sh`
- `scripts/cli/task/edit.test.sh`
- `scripts/cli/task/move.test.sh`
- `scripts/cli/task/rename.test.sh`
- `scripts/cli/task/reorder.test.sh`
- `scripts/cli/task/context/add.test.sh`
- `scripts/cli/task/context/delete.test.sh`

For each test file, search for assertions that match old commit message patterns (e.g. `grep -i "Create task\|Edit task\|Checkpoint:\|Handoff:\|Merge subtask\|Remove subtask\|Add context\|Delete context\|Begin task\|Complete task\|Create workspace\|Reorder\|Move task"`) and update them to match the new `[tt:...]` format.

---

## Decision Log

| Decision | Choice | Rationale |
|---|---|---|
| `task checkout` commit | Standardize to `[tt:task:<id>:checkout]` | It's a real VCS commit; should be consistent |
| `task complete` commit | Standardize to `[tt:task:<id>:complete]` | Same reasoning |
| `task reorder` modifier mode identifier | Use parent task ID + parent description | The commit modifies the parent's file |
| `task rename` parent commit | Use new task ID `[tt:task:<new-id>:rename]` | 'Mutating operations use updated metadata' rule |
| `task move` two commits | `[tt:task:<id>:remove]` (old parent) + `[tt:task:<id>:move]` (new parent) | Differentiated by operation semantic |
| Helper function placement | `common.sh` shared library | DRY — avoids duplicating logic in every command |

---

## Q&A Transcript

**Q: The `task checkout` command produces a commit setting status to IN-PROGRESS. Should this be included in the new standardized format?**
A: Yes — include it as `[tt:task:<id>:checkout] <description>`

**Q: The `task complete` command produces a commit setting status to DONE. Should this be included?**
A: Yes — include it as `[tt:task:<id>:complete] <description>`

**Q: For `task reorder` in modifier mode, the commit is on the parent branch. What should the `[tt:...]` identifier refer to?**
A: Use the parent task ID (file being modified), and also use the parent task description.

**Q: For `task rename`, the parent branch commit currently re-uses the existing commit message verbatim. What should the new format be?**
A: Use new task ID: `[tt:task:task/new-name-ab123456:rename] My task description`

**Q: `task move` produces two commits: one removing from old parent and one adding to new parent. Should both use the same format, or should they be differentiated?**
A: Use `[tt:task:<id>:remove]` (from, old parent) and `[tt:task:<id>:move]` (to, new parent).

---

## Task List

- [ ] Add `format_commit_message` helper to `scripts/cli/lib/common.sh`
- [ ] Update `scripts/cli/workspace/init`
- [ ] Update `scripts/cli/task/create`
- [ ] Update `scripts/cli/task/checkout`
- [ ] Update `scripts/cli/task/checkpoint`
- [ ] Update `scripts/cli/task/complete`
- [ ] Update `scripts/cli/task/checkin`
- [ ] Update `scripts/cli/task/delete`
- [ ] Update `scripts/cli/task/edit`
- [ ] Update `scripts/cli/task/move`
- [ ] Update `scripts/cli/task/rename`
- [ ] Update `scripts/cli/task/reorder`
- [ ] Update `scripts/cli/task/context/add`
- [ ] Update `scripts/cli/task/context/delete`
- [ ] Update all test files to match new commit message format
- [ ] Run test suite to confirm all pass
