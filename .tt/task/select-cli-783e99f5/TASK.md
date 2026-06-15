---
title: "Implement tt task select CLI command and integration tests"
status: TODO
created: 2026-06-15T13:35:51Z
updated: 2026-06-15T13:35:52Z
---
# Implement `tt task select` CLI command and integration tests

## Overview

Implement the `scripts/cli/task/select` CLI command and its integration test suite at `scripts/cli/task/select.test.sh`.

This task depends on `scripts/cli/lib/select.sh` being fully implemented and tested.

## CLI Command: `scripts/cli/task/select`

### Behavior

1. Check that `/dev/tty` is available (interactive terminal). If not, exit with error (code 1).
2. List all task and project bookmarks from `jj`.
3. Filter out DONE tasks (read status from task frontmatter).
4. Sort alphabetically.
5. Pipe list into `select_value` from `scripts/cli/lib/select.sh`.
6. Print the selected task ID to stdout.

### Implementation

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"
. "$SCRIPT_DIR/../lib/select.sh"

# Parse args (--repo flag via common.sh)
# Check TTY
if ! [ -t 2 ] || ! [ -e /dev/tty ]; then
  echo "Error: tt task select requires an interactive terminal" >&2
  exit 1
fi

# List active task/project bookmarks
# Filter to task/project branches, exclude DONE
# Sort alphabetically
# Pipe to select_value
```

### Listing active tasks

```bash
all_bookmarks="$(jj -R "$repo" --ignore-working-copy log -r 'bookmarks()' \
  -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' \
  --no-graph 2>/dev/null)" || true

active_items=""
while IFS= read -r b; do
  [[ -z "$b" ]] && continue
  is_task_branch "$b" "$task_prefix" || is_project_branch "$b" "$project_prefix" || continue
  local tf
  tf="$(task_file_path "$b")"
  local content
  content="$(jj_show_at_revision "$repo" "$b" "$tf")" || continue
  local status
  status="$(parse_frontmatter_field "$content" "status")"
  [[ "$status" == "DONE" ]] && continue
  active_items+="$b"$'\n'
done <<< "$all_bookmarks"

printf '%s' "$active_items" | sort | select_value
```

## Integration Tests: `scripts/cli/task/select.test.sh`

### Test Cases

1. **Non-TTY exits with error** — pipe input in non-interactive mode, verify exit code 1 and error message
2. **No active tasks exits with error** — mock empty bookmark list, verify exit code 1
3. **DONE tasks are excluded** — create tasks with various statuses, verify only non-DONE appear
4. **Output is sorted alphabetically** — verify items passed to select_value are sorted
5. **Selected value is printed to stdout** — mock select_value, verify output

## Update DESIGN.md

Add `tt task select` to the command reference in DESIGN.md:

```markdown
#### `tt task select`
```
tt task select
```
Interactively select an active (non-completed) task or project. Requires an interactive terminal. The selected task ID is printed to stdout.
```
