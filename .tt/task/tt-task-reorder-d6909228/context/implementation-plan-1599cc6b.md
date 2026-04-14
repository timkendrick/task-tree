---
title: "Implementation Plan"
created: 2026-04-09T07:29:45Z
updated: 2026-04-09T07:29:45Z
---
# Plan: Implement `tt task reorder` CLI command

## Overview

Implement `scripts/cli/task/reorder` — a new tt CLI subcommand that:

1. **Reorder modifier mode** (`--up`, `--down`, `--before <sibling>`, `--after <sibling>`): Reorders a named child task within its parent's `subtask:` list.
2. **Tidy mode** (no modifier): Canonicalises the frontmatter ordering of a task file on its canonical branch.

Also add `reorder` as a top-level alias in `scripts/cli/tt`, and update `DESIGN.md` to document the full command including tidy mode.

---

## Questionnaire Transcript

**Q: When running `tt task reorder <task-id>` with no modifier (tidy mode), should `updated:` be refreshed?**
A: Yes — update `updated:` to current timestamp.

**Q: When reordering subtasks (`--up`/`--down`/`--before`/`--after`), which task file is modified?**
A: The actual parent of `<task-id>` (found by scanning branches for `subtask:` entries — use existing `find_parent_branch` helper).

**Q: When running tidy mode, which task is tidied?**
A: Optional positional `<task-id>` argument; defaults to the current task.

**Q: Should `--worktree=<path>` be supported?**
A: Yes.

**Q: What commit message for tidy mode?**
A: `Reorder task: <title> (<task-id>)`

**Q: What commit message for reorder modifier mode?**
A: `Reorder subtask: <child-title> (<child-id>)`

**Q: In tidy mode, if the frontmatter is already canonical, should a commit be created?**
A: No — detect no-op and exit 0 silently.

**Q: For reorder modifier mode, how is the parent task determined?**
A: Use `find_parent_branch` to scan all bookmarks.

**Q: Should the WC be clean before proceeding?**
A: Yes.

**Q: For `--up`/`--down` on already-first/last item, error or no-op?**
A: Fail with error for `--up`/`--down`; succeed silently for `--before`/`--after` (already in correct position = no-op).

**Q: Where to read subtask statuses from for tidy mode ordering?**
A: Use the checkbox in the `subtask:` line (`[ ]`/`[-]`/`[x]`) as the canonical source — no external branch lookups needed.

**Q: Commit message details?**
A: Tidy mode: `Reorder task: <title> (<task-id>)`. Reorder modifier: `Reorder subtask: <child-title> (<child-id>)`.

---

## Key Decisions

- **Tidy mode**: Operates on the task's **canonical branch** (merged tasks are on the parent branch; ongoing tasks are on their own branch — same "where to read" rule as §7.1 / Appendix A step 3). Uses `find_branch_for_task` to determine this.
- **Reorder modifier mode**: Operates on the parent's branch. Uses `find_parent_branch` to discover parent.
- **No-op detection**: Both modes detect unchanged content and skip commit.
- **Status grouping for subtask reordering**: IN-PROGRESS first (`[-]`), then TODO (`[ ]`), then DONE (`[x]`). Determined solely by the checkbox in the `subtask:` line. Within each group, original relative order is preserved (stable sort).
- **`updated:` timestamp**: Refreshed in both tidy and reorder modifier commits.
- **Commit style**: Matches existing commands (transaction bracket, `jj commit`, bookmark advance).
- **`parse_task_frontmatter` helper**: Added to `lib/common.sh`. Parses all known frontmatter fields into global variables (`PARSED_TITLE`, `PARSED_STATUS`, `PARSED_CREATED`, `PARSED_UPDATED`, `PARSED_BODY`, `PARSED_LABELS`, `PARSED_CONTEXTS`, `PARSED_SUBTASKS`). Errors with exit 1 if any unrecognized frontmatter key is encountered. Both `reorder_subtask` and `reorder_frontmatter` use this instead of inline parsing. `edit` is migrated to use it as a precursor task.
- **`write_task_file` helper**: Inlined in the `reorder` script (not sourced from `edit`). Canonical frontmatter order: `title, status, created, updated, labels, contexts, subtasks`.
- **Function names**: `reorder_subtask` (modifier mode), `reorder_frontmatter` (tidy mode).

---

## Files to Create / Modify

| File | Action |
|------|--------|
| `scripts/cli/lib/common.sh` | **Modify** — add `parse_task_frontmatter` helper |
| `scripts/cli/task/edit` | **Modify** — migrate frontmatter parsing to `parse_task_frontmatter` (precursor task) |
| `scripts/cli/task/reorder` | **Create** — main command script |
| `scripts/cli/task/reorder.test.sh` | **Create** — test suite |
| `scripts/cli/tt` | **Modify** — add `reorder` alias, add to usage |
| `DESIGN.md` | **Modify** — expand §6.7 with full behavior, update command reference bullet |

---

## Detailed Implementation

### `scripts/cli/task/reorder`

#### Usage

```
tt task reorder [<task-id>] [--up | --down | --before <sibling-id> | --after <sibling-id>]
                [--worktree=<path>] [--repo PATH]
```

- `<task-id>`: The task to operate on (in modifier mode: the child task; in tidy mode: the task to tidy). Defaults to the current task.
- `--up`: Move `<task-id>` one position earlier in its parent's `subtask:` list.
- `--down`: Move `<task-id>` one position later in its parent's `subtask:` list.
- `--before <sibling-id>`: Move `<task-id>` immediately before `<sibling-id>` in the parent's list.
- `--after <sibling-id>`: Move `<task-id>` immediately after `<sibling-id>` in the parent's list.
- (no modifier): Tidy mode — canonicalise the frontmatter of `<task-id>` on its canonical branch.
- `--worktree=<path>`: Explicit worktree to operate in (passed to `resolve_task_worktree`).
- `--repo PATH`: Override repository root.

#### Argument parsing

```bash
main() {
  local task_id=''
  local modifier=''       # 'up' | 'down' | 'before' | 'after' | ''
  local sibling_id=''     # for --before / --after
  local worktree_arg=''
  local repo=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --up)        modifier='up';   shift ;;
      --down)      modifier='down'; shift ;;
      --before)
        [[ $# -lt 2 ]] && { usage >&2; exit 1; }
        modifier='before'; sibling_id="$2"; shift 2 ;;
      --after)
        [[ $# -lt 2 ]] && { usage >&2; exit 1; }
        modifier='after'; sibling_id="$2"; shift 2 ;;
      --worktree=*)
        worktree_arg="${1#--worktree=}"; shift ;;
      --repo)
        [[ $# -lt 2 ]] && { usage >&2; exit 1; }
        repo="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*)
        usage >&2; exit 1 ;;
      *)
        if [[ -z "$task_id" ]]; then
          task_id="$1"; shift
        else
          usage >&2; exit 1
        fi ;;
    esac
  done

  repo="$(resolve_repo "$repo")"

  local task_prefix project_prefix
  task_prefix="$(get_task_prefix "$repo")"
  project_prefix="$(get_project_prefix "$repo")"

  local current_worktree
  current_worktree="$(resolve_current_worktree "$repo")"

  # Resolve default task_id if not provided
  if [[ -z "$task_id" ]]; then
    local resolve_output
    resolve_output="$(resolve_current "$repo" "$task_prefix" "$project_prefix")"
    task_id="$(printf '%s' "$resolve_output" | sed -n '3p')"
    if [[ -z "$task_id" ]]; then
      log "Error: Not on a task or project branch."
      exit 1
    fi
  fi

  # Validate task_id is a known branch
  if ! jj -R "$repo" --ignore-working-copy log -r "$task_id" --no-graph -T '' 2>/dev/null; then
    log "Error: Branch '$task_id' not found in repository."
    exit 1
  fi
  if ! is_task_branch "$task_id" "$task_prefix" && \
     ! is_project_branch "$task_id" "$project_prefix"; then
    log "Error: '$task_id' is not a task or project branch."
    exit 1
  fi

  if [[ -n "$modifier" ]]; then
    reorder_subtask "$repo" "$task_id" "$modifier" "$sibling_id" \
      "$task_prefix" "$project_prefix" "$current_worktree" "$worktree_arg"
  else
    reorder_frontmatter "$repo" "$task_id" \
      "$task_prefix" "$project_prefix" "$current_worktree" "$worktree_arg"
  fi
}
```

---

### Precursor task: migrate `edit` to `parse_task_frontmatter`

Before implementing `reorder`, add `parse_task_frontmatter` to `lib/common.sh` and migrate `scripts/cli/task/edit` to use it. This removes the duplicate inline parsing in `edit` and ensures the shared helper is proven before `reorder` depends on it.

**`parse_task_frontmatter` signature** (added to `lib/common.sh`):

```bash
# parse_task_frontmatter CONTENT
#
# Populates global variables from task frontmatter:
#   PARSED_TITLE, PARSED_STATUS, PARSED_CREATED, PARSED_UPDATED, PARSED_BODY
#   PARSED_LABELS (array), PARSED_CONTEXTS (array), PARSED_SUBTASKS (array)
#
# Exits 1 with an error message if any unrecognized frontmatter key is found.
# Known keys: title, status, created, updated, label, context, subtask
parse_task_frontmatter() {
  local content="$1"

  PARSED_TITLE="$(parse_quoted_frontmatter_field "$content" "title")"
  PARSED_STATUS="$(parse_frontmatter_field "$content" "status")"
  PARSED_CREATED="$(parse_frontmatter_field "$content" "created")"
  PARSED_UPDATED="$(parse_frontmatter_field "$content" "updated")"
  PARSED_BODY="$(parse_body "$content")"

  PARSED_LABELS=()
  while IFS= read -r lbl; do [[ -n "$lbl" ]] && PARSED_LABELS+=("$lbl"); done \
    < <(printf '%s' "$content" | awk '/^---$/{n++; if(n==2)exit} n==1 && /^label:/{sub(/^label:[[:space:]]*/,""); print}')

  PARSED_CONTEXTS=()
  while IFS= read -r ctx; do [[ -n "$ctx" ]] && PARSED_CONTEXTS+=("$ctx"); done \
    < <(printf '%s' "$content" | awk '/^---$/{n++; if(n==2)exit} n==1 && /^context:/{sub(/^context:[[:space:]]*/,""); print}')

  PARSED_SUBTASKS=()
  while IFS= read -r st; do [[ -n "$st" ]] && PARSED_SUBTASKS+=("$st"); done \
    < <(printf '%s' "$content" | awk '/^---$/{n++; if(n==2)exit} n==1 && /^subtask:/{sub(/^subtask:[[:space:]]*/,""); print}')

  # Reject unrecognized frontmatter keys
  local unknown
  unknown="$(printf '%s' "$content" | awk '
    /^---$/ { n++; if (n==2) exit; next }
    n==1 && /^[a-zA-Z]/ {
      key=$0; sub(/:.*/, "", key)
      if (key != "title" && key != "status" && key != "created" && key != "updated" \
          && key != "label" && key != "context" && key != "subtask")
        print key
    }
  ')"
  if [[ -n "$unknown" ]]; then
    printf 'Error: Unrecognized frontmatter field(s):\n%s\n' "$unknown" >&2
    return 1
  fi
}
```

Migration of `edit`: replace the inline `parse_quoted_frontmatter_field` / `parse_frontmatter_field` / multi-line array parsing block (lines ~207–230) with a single `parse_task_frontmatter "$task_content"` call followed by local variable assignments from `PARSED_*`. The `rewrite_task_file` helper in `edit` remains unchanged (its field order is a separate concern).

---

### `write_task_file` helper (local to `reorder` script)

Mirrors `rewrite_task_file` from `tt task edit` but uses the canonical frontmatter order specified in the task: `title → status → created → updated → labels → contexts → subtasks`.

```bash
# write_task_file FILE TITLE STATUS BODY CREATED
# Uses REWRITE_LABELS, REWRITE_CONTEXTS, REWRITE_SUBTASKS env arrays.
write_task_file() {
  local file="$1" title="$2" status="$3" body="$4" created="$5"
  local updated
  updated="$(generate_timestamp)"
  {
    echo '---'
    echo "title: \"${title//\"/\\\"}\""
    echo "status: $status"
    echo "created: $created"
    echo "updated: $updated"
    for lbl in "${REWRITE_LABELS[@]+"${REWRITE_LABELS[@]}"}"; do
      echo "label: $lbl"
    done
    for ctx in "${REWRITE_CONTEXTS[@]+"${REWRITE_CONTEXTS[@]}"}"; do
      echo "context: $ctx"
    done
    for st in "${REWRITE_SUBTASKS[@]+"${REWRITE_SUBTASKS[@]}"}"; do
      echo "subtask: $st"
    done
    echo '---'
    [[ -n "$body" ]] && printf '%s\n' "$body"
  } > "$file"
}
```

---

### `sort_subtasks_by_status` helper

Partitions `subtask_lines` array into IN-PROGRESS / TODO / DONE by checkbox, then concatenates them. Populates `sorted_subtasks` in the caller's scope.

```bash
sort_subtasks_by_status() {
  local -a _ip=() _todo=() _done=()
  for line in "${subtask_lines[@]+"${subtask_lines[@]}"}"; do
    if [[ "$line" =~ ^\[-\] ]]; then
      _ip+=("$line")
    elif [[ "$line" =~ ^\[[[:space:]]\] ]]; then
      _todo+=("$line")
    else
      _done+=("$line")
    fi
  done
  sorted_subtasks=()
  sorted_subtasks+=("${_ip[@]+"${_ip[@]}"}")
  sorted_subtasks+=("${_todo[@]+"${_todo[@]}"}")
  sorted_subtasks+=("${_done[@]+"${_done[@]}"}")
}
```

---

### `array_move_element` helper

Removes an element at `old_idx` and inserts it at `new_idx` (insert-before semantics). Mutates the array referenced by name (bash namerefs, requires bash 4.3+).

```bash
array_move_element() {
  local -n _arr="$1"
  local old_idx="$2" new_idx="$3"
  local elem="${_arr[$old_idx]}"
  # Remove from old position
  local -a tmp=()
  local i
  for i in "${!_arr[@]}"; do
    [[ $i -eq $old_idx ]] && continue
    tmp+=("${_arr[$i]}")
  done
  # Insert at new_idx into tmp → result
  local -a result=()
  local j
  for j in "${!tmp[@]}"; do
    [[ $j -eq $new_idx ]] && result+=("$elem")
    result+=("${tmp[$j]}")
  done
  [[ $new_idx -ge ${#tmp[@]} ]] && result+=("$elem")
  _arr=("${result[@]+"${result[@]}"}")
}
```

---

### Reorder modifier mode (`reorder_subtask`)

Modifies the **parent** task's `subtask:` list.

```
reorder_subtask REPO CHILD_ID MODIFIER SIBLING_ID TASK_PREFIX PROJECT_PREFIX CURRENT_WORKTREE WORKTREE_ARG
```

**Steps:**

1. Locate parent via `find_parent_branch "$repo" "$child_id" "$task_prefix" "$project_prefix"`.
   - Exit 1 if no parent (parentless task — cannot reorder).
   - Exit 2 (propagated from `find_parent_branch`) if multiple parents.

2. Determine parent task file path:
   ```bash
   local parent_suffix
   if is_task_branch "$parent_id" "$task_prefix"; then
     parent_suffix="${parent_id#$task_prefix}"
   else
     parent_suffix="${parent_id#$project_prefix}"
   fi
   local parent_task_file
   parent_task_file="$(task_file_path "$parent_suffix")"
   ```

3. Resolve `parent_worktree` via `resolve_task_worktree "$repo" "$parent_id" "$task_prefix" "$project_prefix" "$current_worktree" "$worktree_arg"`.

4. Precondition: WC must be clean in `parent_worktree`:
   ```bash
   if ! is_wc_clean "$parent_worktree"; then
     log "Error: Working copy has uncommitted changes. Commit or discard first."
     exit 1
   fi
   ```

5. Read parent task file from the parent branch:
   ```bash
   local parent_content
   parent_content="$(jj_show_at_revision "$repo" "$parent_id" "$parent_task_file")" || {
     log "Error: Could not read task file '$parent_task_file' from branch '$parent_id'."
     exit 1
   }
   ```

6. Parse all parent frontmatter fields via the shared helper (also validates no unknown keys):
   ```bash
   parse_task_frontmatter "$parent_content"
   local parent_title="$PARSED_TITLE"
   local parent_status="$PARSED_STATUS"
   local parent_created="$PARSED_CREATED"
   local parent_body="$PARSED_BODY"
   local -a parent_labels=("${PARSED_LABELS[@]+"${PARSED_LABELS[@]}"}")
   local -a parent_contexts=("${PARSED_CONTEXTS[@]+"${PARSED_CONTEXTS[@]}"}")
   local -a subtask_lines=("${PARSED_SUBTASKS[@]+"${PARSED_SUBTASKS[@]}"}")
   ```

7. Find index of `$child_id` in `subtask_lines`:
   ```bash
   local child_idx=-1
   local i
   for i in "${!subtask_lines[@]}"; do
     # Match the task ID after the checkbox (e.g. "[ ] task/foo-abc123")
     if [[ "${subtask_lines[$i]}" =~ [[:space:]]"${child_id}"([[:space:]]|$) || \
           "${subtask_lines[$i]}" =~ ^(\[..\])[[:space:]]+"${child_id}"([[:space:]]|$) ]]; then
       child_idx=$i
       break
     fi
   done
   if [[ $child_idx -eq -1 ]]; then
     log "Error: '$child_id' is not a subtask of '$parent_id'."
     exit 1
   fi
   ```

   More precisely, extract the ID field from each line and compare:
   ```bash
   for i in "${!subtask_lines[@]}"; do
     local line_id
     line_id="$(printf '%s' "${subtask_lines[$i]}" | awk '{print $2}')"
     if [[ "$line_id" == "$child_id" ]]; then
       child_idx=$i; break
     fi
   done
   ```

8. Apply the modifier. Let `n=${#subtask_lines[@]}`.

   **`--up`**:
   ```bash
   if [[ $child_idx -eq 0 ]]; then
     log "Error: Cannot move up: '$child_id' is already first."
     exit 1
   fi
   # Swap with previous
   local tmp_elem="${subtask_lines[$((child_idx-1))]}"
   subtask_lines[$((child_idx-1))]="${subtask_lines[$child_idx]}"
   subtask_lines[$child_idx]="$tmp_elem"
   ```

   **`--down`**:
   ```bash
   if [[ $child_idx -eq $((n-1)) ]]; then
     log "Error: Cannot move down: '$child_id' is already last."
     exit 1
   fi
   local tmp_elem="${subtask_lines[$((child_idx+1))]}"
   subtask_lines[$((child_idx+1))]="${subtask_lines[$child_idx]}"
   subtask_lines[$child_idx]="$tmp_elem"
   ```

   **`--before <sibling>`**:
   ```bash
   # Find sibling index
   local sibling_idx=-1
   for i in "${!subtask_lines[@]}"; do
     local line_id
     line_id="$(printf '%s' "${subtask_lines[$i]}" | awk '{print $2}')"
     if [[ "$line_id" == "$sibling_id" ]]; then sibling_idx=$i; break; fi
   done
   [[ $sibling_idx -eq -1 ]] && { log "Error: Sibling '$sibling_id' not found."; exit 1; }
   [[ "$sibling_id" == "$child_id" ]] && { log "Error: Cannot reorder relative to itself."; exit 1; }
   # No-op check: child is already immediately before sibling
   if [[ $((child_idx + 1)) -eq $sibling_idx ]]; then exit 0; fi
   # Move: remove child, insert before sibling's new index
   array_move_element subtask_lines "$child_idx" "$sibling_new_idx"
   # (sibling_new_idx computed after removal: if sibling_idx > child_idx, new idx = sibling_idx-1; else sibling_idx)
   ```

   **`--after <sibling>`**: same as `--before` but insert at `sibling_new_idx + 1`.

9. Read child title for commit message:
    ```bash
    local child_branch child_suffix child_content child_title
    child_branch="$(find_branch_for_task "$repo" "$child_id" "$task_prefix" "$project_prefix")" || {
      log "Error: Could not locate branch for '$child_id'."
      exit 1
    }
    if is_task_branch "$child_id" "$task_prefix"; then
      child_suffix="${child_id#$task_prefix}"
    else
      child_suffix="${child_id#$project_prefix}"
    fi
    child_content="$(jj_show_at_revision "$repo" "$child_branch" "$(task_file_path "$child_suffix")")"
    child_title="$(parse_quoted_frontmatter_field "$child_content" "title")"
    ```

10. Begin transaction:
    ```bash
    tt_begin_transaction "$repo"
    ```

11. Write to parent worktree and commit:
    ```bash
    jj -R "$parent_worktree" new "$parent_id"
    export REWRITE_LABELS=("${parent_labels[@]+"${parent_labels[@]}"}")
    export REWRITE_CONTEXTS=("${parent_contexts[@]+"${parent_contexts[@]}"}")
    export REWRITE_SUBTASKS=("${subtask_lines[@]+"${subtask_lines[@]}"}")
    write_task_file "$parent_worktree/$parent_task_file" \
      "$parent_title" "$parent_status" "$parent_body" "$parent_created"
    unset REWRITE_LABELS REWRITE_CONTEXTS REWRITE_SUBTASKS
    jj -R "$parent_worktree" commit -m "Reorder subtask: $child_title ($child_id)"
    jj -R "$parent_worktree" bookmark set "$parent_id" -r '@-'
    jj -R "$parent_worktree" new '@'
    ```

12. Commit transaction:
    ```bash
    tt_commit_transaction "$repo"
    ```

13. Output:
    ```bash
    log "Reordered: $child_id in $parent_id"
    ```

---

### Tidy mode (`reorder_frontmatter`)

Canonicalises the frontmatter of the named task on its **canonical branch**.

```
reorder_frontmatter REPO TASK_ID TASK_PREFIX PROJECT_PREFIX CURRENT_WORKTREE WORKTREE_ARG
```

**Steps:**

1. Determine the canonical branch via `find_branch_for_task`:
   - **Ongoing task** (not yet checked in): canonical branch = `task_id`'s own branch.
   - **Merged task** (checked in with `[x]`): canonical branch = the parent branch that received the checkin.

   ```bash
   local canonical_branch
   canonical_branch="$(find_branch_for_task "$repo" "$task_id" "$task_prefix" "$project_prefix")" || {
     log "Error: Could not locate branch for '$task_id'."
     exit 1
   }
   ```

2. Determine task file path from `task_id` (the slug-hex suffix is always derived from `task_id` itself, regardless of canonical branch):
   ```bash
   local task_suffix
   if is_task_branch "$task_id" "$task_prefix"; then
     task_suffix="${task_id#$task_prefix}"
   else
     task_suffix="${task_id#$project_prefix}"
   fi
   local task_file
   task_file="$(task_file_path "$task_suffix")"
   ```

3. Resolve the worktree to operate in — use `canonical_branch` (not `task_id`) for resolution:
   ```bash
   local canonical_worktree
   canonical_worktree="$(resolve_task_worktree "$repo" "$canonical_branch" \
     "$task_prefix" "$project_prefix" "$current_worktree" "$worktree_arg")"
   ```

4. Precondition: WC must be clean:
   ```bash
   if ! is_wc_clean "$canonical_worktree"; then
     log "Error: Working copy has uncommitted changes. Commit or discard first."
     exit 1
   fi
   ```

5. Read task file content from the canonical branch:
   ```bash
   local task_content
   task_content="$(jj_show_at_revision "$repo" "$canonical_branch" "$task_file")" || {
     log "Error: Could not read task file '$task_file' from branch '$canonical_branch'."
     exit 1
   }
   ```

6. Parse all frontmatter fields via the shared helper (also validates no unknown keys):
   ```bash
   parse_task_frontmatter "$task_content"
   local title="$PARSED_TITLE" status="$PARSED_STATUS"
   local created="$PARSED_CREATED" body="$PARSED_BODY"
   local -a labels=("${PARSED_LABELS[@]+"${PARSED_LABELS[@]}"}")
   local -a contexts=("${PARSED_CONTEXTS[@]+"${PARSED_CONTEXTS[@]}"}")
   local -a subtask_lines=("${PARSED_SUBTASKS[@]+"${PARSED_SUBTASKS[@]}"}")
   ```

7. Sort subtask lines by checkbox status (stable within each category):
   ```bash
   local -a sorted_subtasks=()
   sort_subtasks_by_status  # reads subtask_lines, writes sorted_subtasks
   ```

8. Build proposed canonical content for no-op detection:
   ```bash
   local proposed
   proposed="$(
     echo '---'
     echo "title: \"${title//\"/\\\"}\""
     echo "status: $status"
     echo "created: $created"
     echo "updated: PLACEHOLDER"
     for lbl in "${labels[@]+"${labels[@]}"}"; do echo "label: $lbl"; done
     for ctx in "${contexts[@]+"${contexts[@]}"}"; do echo "context: $ctx"; done
     for st  in "${sorted_subtasks[@]+"${sorted_subtasks[@]}"}"; do echo "subtask: $st"; done
     echo '---'
     [[ -n "$body" ]] && printf '%s\n' "$body"
   )"
   ```

9. No-op detection — strip `updated:` from both sides and compare:
   ```bash
   local current_stripped proposed_stripped
   current_stripped="$(printf '%s' "$task_content" | grep -v '^updated:')"
   proposed_stripped="$(printf '%s\n' "$proposed" | grep -v '^updated:' | grep -v '^updated: PLACEHOLDER')"
   if [[ "$proposed_stripped" == "$current_stripped" ]]; then
     exit 0  # already canonical, no commit needed
   fi
   ```

   Implementation note: the `proposed` is constructed with `updated: PLACEHOLDER` solely for easier stripping. The actual `write_task_file` call will insert the real timestamp.

10. Begin transaction:
    ```bash
    tt_begin_transaction "$repo"
    ```

11. Write to canonical worktree and commit:
    ```bash
    jj -R "$canonical_worktree" new "$canonical_branch"
    export REWRITE_LABELS=("${labels[@]+"${labels[@]}"}")
    export REWRITE_CONTEXTS=("${contexts[@]+"${contexts[@]}"}")
    export REWRITE_SUBTASKS=("${sorted_subtasks[@]+"${sorted_subtasks[@]}"}")
    write_task_file "$canonical_worktree/$task_file" "$title" "$status" "$body" "$created"
    unset REWRITE_LABELS REWRITE_CONTEXTS REWRITE_SUBTASKS
    jj -R "$canonical_worktree" commit -m "Reorder task: $title ($task_id)"
    jj -R "$canonical_worktree" bookmark set "$canonical_branch" -r '@-'
    jj -R "$canonical_worktree" new '@'
    ```

12. Commit transaction:
    ```bash
    tt_commit_transaction "$repo"
    ```

13. Output:
    ```bash
    log "Tidied: $task_id"
    ```

---

### Full script structure

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}") && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

readonly SCRIPT_NAME="${0##*/}"

usage() { ... }

log() { printf '%s\n' "$*" >&2; }

# Local write helper — canonical frontmatter order: title, status, created, updated,
# labels, contexts, subtasks. Uses REWRITE_LABELS, REWRITE_CONTEXTS, REWRITE_SUBTASKS.
write_task_file() { ... }

# Sort subtask_lines (global array) by checkbox status, stable within category.
# Writes result to sorted_subtasks (global array).
sort_subtasks_by_status() { ... }

# Move element at old_idx to new_idx (insert-before) in a named array.
array_move_element() { ... }

reorder_subtask() { ... }

reorder_frontmatter() { ... }

main() { ... }

main "$@"
```

---

### Modifying `scripts/cli/tt`

Add `reorder` to:
1. The alias `case` block: `reorder) set -- task reorder "${@:2}" ;;`
2. The `usage()` function alias list: `${SCRIPT_NAME} reorder → tt task reorder`

---

### Updating `DESIGN.md`

**1. §6.7 Task reorder** — Replace the existing one-liner with a full section:

```markdown
### 6.7 Task reorder

Child tasks are ordered via the current task file's `subtask:` frontmatter.

**`tt task reorder [<task-id>] [--up | --down | --before <other-task-id> | --after <other-task-id>] [--worktree=<path>] [--repo PATH]`**

When a modifier is given (`--up`, `--down`, `--before`, `--after`), reorders `<task-id>` (default: current task) within its **parent's** `subtask:` list. The parent is located automatically by scanning all task/project branches for one whose task file lists `<task-id>` in a `subtask:` entry (using the same `find_parent_branch` logic as `tt task checkin`). The command fails if:

- `<task-id>` has no parent (parentless project — cannot reorder).
- `<task-id>` is not found in the parent's `subtask:` list.
- The modifier is `--up` and `<task-id>` is already first.
- The modifier is `--down` and `<task-id>` is already last.
- The sibling given to `--before` / `--after` is not found in the parent's `subtask:` list.

For `--before` / `--after`: if `<task-id>` is already immediately before/after the named sibling, the command exits silently with no commit (no-op).

On success, creates a `Reorder subtask: <child-title> (<child-id>)` commit on the parent branch, advancing the parent bookmark.

When **no modifier** is given, **tidy mode** canonicalises the frontmatter of `<task-id>` (default: current task) on its canonical branch (merged tasks are edited on the parent branch; ongoing tasks are edited on their own branch — same "where to read" rule as §7.1 / Appendix A step 3).

Canonical frontmatter order:
1. `title`
2. `status`
3. `created`
4. `updated` (refreshed to current timestamp)
5. `label` entries, retaining their current relative order
6. `context` entries, retaining their current relative order
7. `subtask` entries, ordered by status category — `IN-PROGRESS` (`[-]`) first, then `TODO` (`[ ]`), then `DONE` (`[x]`) — determined solely by the checkbox in the `subtask:` line. Relative order within each status category is preserved (stable sort).

If the frontmatter is already in canonical order (all fields in the correct sequence, subtasks already grouped by status), tidy mode exits silently with no commit. The `updated:` field is excluded from this comparison — it is always refreshed when any other change is made. Otherwise creates a `Reorder task: <title> (<task-id>)` commit on the canonical branch, advancing the canonical bookmark.

**Preconditions (both modes):** working copy must be clean. `<task-id>` must be a valid task or project branch.
```

**2. Command reference bullet for `tt task reorder` (§5)** — Replace the existing one-liner:

```markdown
- **`tt task reorder [<task-id>] [--up | --down | --before <other-task-id> | --after <other-task-id>] [--worktree=<path>] [--repo PATH]`** — Reorder a task within its parent's `subtask:` list, or (with no modifier) tidy the frontmatter of a task file. With a modifier, locates the parent automatically via `find_parent_branch` and moves `<task-id>` accordingly; `--up`/`--down` error if already at the boundary; `--before`/`--after` is a no-op if already in the requested position. Without a modifier, canonicalises the frontmatter field order and groups `subtask:` entries by checkbox status (`[-]` IN-PROGRESS first, `[ ]` TODO, `[x]` DONE), operating on the task's canonical branch (per §7.1 / Appendix A step 3). Defaults to the current task if `<task-id>` is omitted. Creates a `Reorder subtask:` commit on the parent branch (modifier mode) or a `Reorder task:` commit on the canonical branch (tidy mode). See §6.7.
```

---

### Test suite: `scripts/cli/task/reorder.test.sh`

**Reorder modifier mode:**
- `test_task_reorder__up_basic` — Three tasks; move middle one up; verify order is now [middle, first, last].
- `test_task_reorder__down_basic` — Three tasks; move middle one down; verify order.
- `test_task_reorder__before_basic` — Move last task before first; verify order.
- `test_task_reorder__after_basic` — Move first task after last; verify order.
- `test_task_reorder__up_already_first` — Expect failure with error message.
- `test_task_reorder__down_already_last` — Expect failure with error message.
- `test_task_reorder__before_noop` — Child is already immediately before sibling; exit 0; no new commit.
- `test_task_reorder__after_noop` — Child is already immediately after sibling; exit 0; no new commit.
- `test_task_reorder__unknown_frontmatter_field_errors` — Parent task file contains an unrecognized key; expect failure with clear error message.
- `test_task_reorder__before_sibling_not_found` — Expect error.
- `test_task_reorder__dirty_wc_fails` — Expect failure.
- `test_task_reorder__transaction_recorded` — Verify history entry added.
- `test_task_reorder__commit_message` — Verify commit on parent branch contains child title and ID.
- `test_task_reorder__parentless_task_fails` — Reordering a project (parentless) errors.

**Tidy mode:**
- `test_task_reorder__tidy_basic` — Task with TODO/IN-PROGRESS/DONE subtasks out of order; verify subtasks reordered by category.
- `test_task_reorder__tidy_noop` — Already canonical; verify no new commit created (history count unchanged).
- `test_task_reorder__tidy_frontmatter_field_order` — Verify canonical field order: title before status before created before updated before labels before contexts before subtasks.
- `test_task_reorder__tidy_labels_preserved` — Labels retain original relative order.
- `test_task_reorder__tidy_contexts_preserved` — Contexts retain original relative order.
- `test_task_reorder__tidy_within_status_stable` — Two IN-PROGRESS subtasks; both stay IN-PROGRESS group; relative order preserved.
- `test_task_reorder__tidy_commit_message` — Verify `Reorder task: <title> (<task-id>)`.
- `test_task_reorder__tidy_transaction_recorded` — Verify history entry.
- `test_task_reorder__tidy_defaults_to_current_task` — No task-id arg; tidy operates on current branch's task.
- `test_task_reorder__tidy_dirty_wc_fails` — Expect failure.
- `test_task_reorder__tidy_merged_task` — Task that has been checked in (`[x]`); tidy operates on parent branch.

**Alias:**
- `test_task_reorder__alias` — `tt reorder <id> --up` dispatches identically to `tt task reorder <id> --up`.

---

## Task Checklist

- [ ] **Precursor: add `parse_task_frontmatter` to `lib/common.sh` and migrate `edit`**
  - [ ] Create a new jj commit (`jj new -m "Add parse_task_frontmatter helper to lib/common.sh"`)
  - [ ] Add `parse_task_frontmatter` function to `scripts/cli/lib/common.sh`
  - [ ] Migrate `scripts/cli/task/edit` lines ~207–230 to use `parse_task_frontmatter`
  - [ ] Run edit test suite to confirm no regressions
  - [ ] Commit (`jj commit -m "..."`)
- [ ] Create a new jj commit before starting reorder (`jj new -m "Implement tt task reorder"`)
- [ ] Implement `scripts/cli/task/reorder` script
  - [ ] `usage()` function
  - [ ] `log()` helper
  - [ ] `write_task_file()` helper (canonical order: title, status, created, updated, labels, contexts, subtasks; `parse_task_frontmatter` sourced from `lib/common.sh`)
  - [ ] `sort_subtasks_by_status()` helper
  - [ ] `array_move_element()` helper
  - [ ] Argument parsing (task_id, modifier, sibling_id, worktree, repo)
  - [ ] `reorder_subtask()` function
  - [ ] `reorder_frontmatter()` function
  - [ ] `main()` function
  - [ ] Make executable: `chmod +x scripts/cli/task/reorder`
- [ ] Update `scripts/cli/tt`
  - [ ] Add `reorder` alias in `case` block
  - [ ] Add `reorder` to `usage()` alias list
- [ ] Update `DESIGN.md`
  - [ ] Expand §6.7 with full behavior description
  - [ ] Update command reference bullet for `tt task reorder` in §5
- [ ] Implement `scripts/cli/task/reorder.test.sh`
  - [ ] Reorder modifier tests (13 tests)
  - [ ] Tidy mode tests (11 tests)
  - [ ] Alias test (1 test)
- [ ] Run test suite: `scripts/test reorder`
- [ ] Run broader test suite to check for regressions
- [ ] Commit all changes

---

## Research Findings

### Existing `rewrite_task_file` in `scripts/cli/task/edit` (lines ~63–93)

Uses `REWRITE_LABELS`, `REWRITE_SUBTASKS`, `REWRITE_CONTEXTS` env arrays. Order: labels → subtasks → contexts. Not in `lib/common.sh`, so not importable. The `reorder` script inlines its own `write_task_file` with the canonical order (labels → contexts → subtasks).

### `find_parent_branch` in `lib/common.sh` (line 437)

Scans all task/project bookmarks for one that contains `subtask: [?] <task-id>`. Returns:
- 0: parent found (printed to stdout)
- 1: no parent
- 2: multiple parents (error to stderr)

### `find_branch_for_task` in `lib/common.sh` (line 499)

Returns canonical branch for a task: merged (`[x]`) → parent branch; unmerged → own branch.

### `resolve_task_worktree` in `lib/common.sh` (line 554)

Resolves which worktree to operate in for a given bookmark. Handles 0/1/multiple matches.

### `parse_frontmatter_field` / `parse_quoted_frontmatter_field`

Standard field extractors used throughout the codebase.

### Subtask line format

Raw value after `subtask: ` is: `[?] <task-id>` where `?` is ` ` (space), `x`, or `-`.
Example: `[ ] task/my-task-abc12345`

The second whitespace-delimited field (awk `$2`) is the task ID.

### Canonical frontmatter order

Per the task description: title → status → created → updated → labels → contexts → subtasks.
The existing `edit` command uses a different order (labels → subtasks → contexts). The `reorder` command implements the canonical order as specified.
