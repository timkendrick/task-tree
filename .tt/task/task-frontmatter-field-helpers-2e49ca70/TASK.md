---
title: "Add helpers to read task frontmatter fields from a branch"
status: TODO
created: 2026-10-20T10:20:36Z
updated: 2026-10-20T10:20:36Z
---
## Background

Many commands read frontmatter fields from a task file on a branch. Each command repeats the same steps inline:

1. Strip the task or project prefix from the task ID to get the task suffix.
2. Build the task file path from the suffix.
3. Read the task file content at a revision.
4. Parse each field from the content, and decode the quoted fields.

Step 3 starts a VCS process. Steps 1, 2 and 4 run in pure bash. The cost of a read therefore depends on the number of VCS reads, not on the number of fields parsed.

`tt worktree prune` needs the status of each worktree's task. `tt worktree delete` already reads it inline. This task adds shared helpers so that both commands use one implementation.

## Goal

Add five helpers in two tiers:

| Helper | Module | Cost |
|---|---|---|
| `_task__resolve_file TASK_ID TASK_PREFIX PROJECT_PREFIX` | `lib/task.sh` | pure bash |
| `_frontmatter__parse_values CONTENT FIELD...` | `lib/frontmatter.sh` | pure bash |
| `_task__read_fields REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX FIELD...` | `lib/task.sh` | 1 VCS read |
| `_task__read_status REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX` | `lib/task.sh` | 1 VCS read |
| `_task__read_title REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX` | `lib/task.sh` | 1 VCS read |

Adopt them in `worktree/delete`, `task/propagate` and `_task__resolve_current`.

## Helper contracts

### `_task__resolve_file TASK_ID TASK_PREFIX PROJECT_PREFIX`

- Prints the repo-relative task file path for TASK_ID (`.tt/task/<suffix>/TASK.md`).
- Accepts a task ID and a project ID.
- Builds the path with `_path__task_file`.
- Returns 1 and prints nothing when TASK_ID is neither a task ID nor a project ID.
- Performs no VCS access.

### `_frontmatter__parse_values CONTENT FIELD...`

- Prints one line per requested FIELD, in the order of the arguments.
- Prints an empty line for an absent field, so the line positions stay fixed.
- Decodes a value written as a quoted string, as `_frontmatter__parse_quoted_field` does.
- Prints an unquoted value unchanged.
- Uses the first occurrence when a field appears more than once, as `_frontmatter__parse_field` does.
- Parses CONTENT in a single pass through `_frontmatter__parse_fields`.
- Rejects the repeatable fields `label`, `context` and `subtask`: logs an error and returns 1 before printing anything.

Newline separates the values. The frontmatter format stores each value on one line, and quoting escapes newlines, so a newline does not appear inside a value. Tab and other printable separators can appear inside a title.

Pseudocode:

```
parse_values(content, fields...):
  reject any repeatable field in fields
  values[i] = "" for each requested field i
  for each "key:value" record from parse_fields(content, fields...):
    for each requested field i with fields[i] == key and values[i] not yet set:
      values[i] = unquote(value)
  print each values[i] on its own line
```

Bash 3.2 has no associative arrays. Track the values in an array parallel to the field list. Track the "already set" state in a second parallel array, so that an empty first occurrence still wins over a later one.

### `_task__read_fields REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX FIELD...`

- Resolves the task file path of TASK_ID with `_task__resolve_file`.
- Reads the content of that path at REV with `_task__read_file`.
- Prints the result of `_frontmatter__parse_values` for the requested fields.
- Returns 1 and prints nothing when TASK_ID is not a task or project ID.
- Returns 1 and prints nothing when the task file cannot be read at REV. For example, REV does not exist, or the file does not exist at REV.
- Returns 1 when `_frontmatter__parse_values` rejects a field.
- Performs exactly one VCS read for any number of fields.

REV is required. A caller that reads the task's own branch passes the task ID as both REV and TASK_ID. Other callers pass a different revision:

- `task/reorder` reads at the branch that `_task__find_branch` returns. For a task merged by a complete checkin, this is the parent branch.
- `task/changelog` reads at a historical revision.

The caller passes the prefixes in. Commands already hold them, and a lookup inside the helper adds a read per call. This matters for `tt worktree prune`, which calls the helper once per worktree.

The helpers report an unreadable task file through the return status only. Each caller decides how to handle it.

### `_task__read_status REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX`

- Prints the `status` value of TASK_ID's task file at REV.
- Delegates to `_task__read_fields` with the single field `status`.
- Returns the same status codes as `_task__read_fields`.

### `_task__read_title REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX`

- Prints the decoded `title` value of TASK_ID's task file at REV.
- Delegates to `_task__read_fields` with the single field `title`.
- Returns the same status codes as `_task__read_fields`.

## Call-site conventions

Read several fields into variables with a `read` block:

```bash
local fields title status
fields="$(_task__read_fields "$repo" "$task_id" "$task_id" "$task_prefix" "$project_prefix" title status)" || exit 1
{ IFS= read -r title; IFS= read -r status; } <<< "$fields" || true
```

- `$(...)` strips trailing empty lines. A `read` past the end of the input leaves its variable empty and returns non-zero. The `|| true` keeps `set -e` from exiting in that case.
- `IFS=` keeps leading and trailing whitespace in each value.
- `_task__resolve_current_branch` uses the same pattern to unpack the two lines of `_task__resolve_current`.

Read a single field with the matching wrapper:

```bash
status="$(_task__read_status "$repo" "$task_id" "$task_id" "$task_prefix" "$project_prefix")" || status=''
```

Under `set -e`, a failed command substitution in an assignment exits the script. Each call site must handle the non-zero status explicitly.

## Call-site changes

### `scripts/cli/worktree/delete`

The status check strips the prefix, builds the task file path, reads the file and parses `status` inline. Replace these steps with one `_task__read_status` call that reads the task's own branch. Keep the current behavior:

- An unreadable task file gives an empty status.
- The error message reports an empty status as `unknown`.
- A status other than `DONE` refuses the delete unless `--force` is given.

### `scripts/cli/task/propagate`

Adopt the helpers and keep the current behavior.

- Remove the local `branch_task_file` function. Call `_task__resolve_file` in its place. The local function prints nothing for an invalid ID, while `_task__resolve_file` also returns 1. Handle the non-zero status at each call site so that the current flow stays the same:
  - In `propagate_from`, an invalid source branch still reaches the existing empty-path check.
  - In the child loop, an invalid child ID still skips the child.
- Change `read_title` to take a branch, a task ID and the prefixes instead of a task file path. Implement it with `_task__read_title`. It still prints nothing when the task file cannot be read.
- Change `is_done` to take a task ID and the prefixes instead of a task file path. Implement it with `_task__read_status`. It still returns 0 (DONE) when the task file cannot be read.
- Pass the prefixes to the functions that call `read_title` and `is_done`. These are `build_fork_commit`, `propagate_one_merge`, and the functions that call `build_fork_commit`.
- Keep `get_subtask_ids` on `_task__read_file`. It parses the repeatable `subtask` field, which the new helpers reject.

Known difference: the current `is_done` also treats a readable but empty task file as DONE. With the helper, an empty file reads successfully and gives an empty status, so `is_done` reports not DONE. An empty task file is invalid state, and the follow-up task `task/tt-task-propagate-branch-task-file-errors-ee9f5c1b` covers invalid task files in `propagate`.

### `_task__resolve_current` in `lib/task.sh`

It builds the task file path from the branch name with its own prefix checks. Replace the path construction with `_task__resolve_file`. Keep the two-line output contract unchanged.

## Tests

Add to `scripts/cli/lib/frontmatter.test.sh`, for `_frontmatter__parse_values`:

- Prints values in argument order when it differs from file order.
- Prints an empty line for an absent field in the middle of the list, and keeps the later positions.
- Prints an empty line for an absent field at the end of the list.
- Decodes a quoted title that contains escaped quotes, a backslash and an escaped newline.
- Prints an unquoted `status` value unchanged.
- Uses the first occurrence of a repeated single-valued field.
- Ignores `---` lines and `key: value` lines in the body.
- Rejects `label`, `context` and `subtask` with a non-zero status and no stdout.

Add to `scripts/cli/lib/task.test.sh`:

- `_task__resolve_file` maps a task ID to its task file path.
- `_task__resolve_file` maps a project ID to its task file path.
- `_task__resolve_file` returns 1 with no output for an ID with neither prefix.
- `_task__read_fields` reads title and status from the branch tip, not from the working copy. For example, change the status with a branch write that leaves the working copy behind, then check that the helper reports the new status.
- `_task__read_fields` reads at a REV other than the task's own branch. For example, after a complete checkin, read the child's task file at the parent branch.
- `_task__read_fields` returns 1 for an ID with neither prefix.
- `_task__read_fields` returns 1 when REV does not exist.
- `_task__read_fields` returns 1 when the task file does not exist at REV.
- `_task__read_status` and `_task__read_title` each print the single value, with the title decoded.

Add to `scripts/cli/task/propagate.test.sh`:

- A child whose task file cannot be read at its branch tip counts as DONE. Propagate reports it as up to date and creates no fork commit. This test pins the current behavior. The follow-up task changes it.

Run these suites, and check that they pass without changes to existing tests:

- `scripts/test lib/frontmatter`
- `scripts/test lib/task`
- `scripts/test worktree/delete`
- `scripts/test task/propagate`
- `scripts/test task/checkin` and `scripts/test task/create`, which run propagate
- `scripts/test task/current` and `scripts/test task/show`, which depend on `_task__resolve_current`

## Documentation

- Add each new helper to the "Public surface" list in the header of its module.
- Update `ARCHITECTURE.md` if its module inventory describes the frontmatter or task module responsibilities in a way the new helpers change.
- No change to `DESIGN.md` or `.agents/skills/tt/SKILL.md` is needed. The task changes no user-facing behavior.

## Out of scope

Changing the `propagate` behavior for an unreadable task file. Task `task/tt-task-propagate-branch-task-file-errors-ee9f5c1b` covers it.

Migrating the other call sites to the helpers. A follow-up task covers them:

| Call site | Helper | Revision read |
|---|---|---|
| `task/select:86` | `_task__read_status` | own branch |
| `task/checkin:345` | `_task__read_status` | own branch |
| `task/move:198` | `_task__read_title` | own branch |
| `task/checkpoint:128` | `_task__read_title` | own branch |
| `task/publish:212` | `_task__read_title` | own branch |
| `task/rename:176` | `_task__read_title` | own branch |
| `task/reorder:233` | `_task__read_title` | `_task__find_branch` result |
| `task/delete:189` | `_task__read_fields` title, status | own branch |
| `task/complete:104` | `_task__read_fields` title, status | own branch |
| `task/checkin:279`, `task/checkin:359` | `_task__read_fields` title, status | own branch |
| `task/checkout:325` | `_task__read_fields` title, status | own branch |
| `task/changelog:127` | `_task__read_fields` status, title | historical revision |
| `task/show:205` | `_task__read_fields` status, title | subtask branch |

- `task/rename:176` parses the title with `awk` and does not decode the quoted value. The migration to `_task__read_title` decodes it.
- `task/complete:104` also parses the repeatable `subtask` field from the same content. It needs the content as well as the fields, so check whether the migration reduces its cost before moving it.

Replacing the other inline prefix-stripping sites with `_task__resolve_file`. This belongs to the same follow-up task.

The following call sites stay on `_task__read_file`. They parse content they already hold, need the body or repeatable fields, or copy the file whole: `task/tree`, `task/show:121`, `task/prompt`, `task/edit`, `task/reorder:125` and `:292`, the `task/context/*` commands, `task/create:372`, `task/delete:89` and `:95`, `task/checkin:477`, and the file copies in `task/move` and `task/rename`.
