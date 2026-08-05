---
title: "Implementation Plan"
created: 2026-08-05T15:56:35Z
updated: 2026-08-05T15:56:35Z
---
## Implementation Plan: `tt task diff` (alias `tt diff`)

**1. Refactor — extract shared range resolution into `scripts/cli/lib/common.sh`**

New helper, used by both `revset` and `diff`:

```bash
# Usage: resolve_task_range REPO [TASK_ID]
# Prints "<parent_bookmark> <upper_bound>" for a task's unmerged range.
# Without TASK_ID: current task, upper bound @ (dirty WC) or @- (clean).
# With TASK_ID: bookmark itself is the upper bound.
resolve_task_range() {
  local repo="$1" task_id_arg="${2:-}"
  local task_prefix project_prefix task_bookmark upper_bound
  task_prefix="$(get_task_prefix "$repo")"
  project_prefix="$(get_project_prefix "$repo")"

  if [[ -z "$task_id_arg" ]]; then
    task_bookmark="$(resolve_current_bookmark "$repo" "$task_prefix" "$project_prefix")" || {
      log "Error: Not on a task or project branch."; return 1; }
    [[ -z "$task_bookmark" ]] && { log "Error: Not on a task or project branch."; return 1; }
    local wc_empty
    wc_empty="$(jj -R "$repo" log -r '@' --no-graph -T 'empty' 2>/dev/null)" || true
    [[ "$wc_empty" == "true" ]] && upper_bound='@-' || upper_bound='@'
  else
    task_bookmark="$task_id_arg"; upper_bound="$task_bookmark"
    jj -R "$repo" log -r "$task_bookmark" --no-graph -T 'commit_id' >/dev/null 2>&1 || {
      log "Error: Bookmark '$task_bookmark' not found."; return 1; }
  fi

  local parent_bookmark exit_code=0
  parent_bookmark="$(find_parent_branch "$repo" "$task_bookmark" "$task_prefix" "$project_prefix")" || exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    [[ $exit_code -eq 1 ]] && log "Error: No parent found for '$task_bookmark'."
    return $exit_code
  fi
  printf '%s %s' "$parent_bookmark" "$upper_bound"
}
```

`scripts/cli/task/revset` is rewritten to call it (behaviour unchanged).

**2. New `scripts/cli/task/diff`**

Options: `--task ID`, `--repo PATH`, `-h|--help` only (per your answer — no passthrough). Core:

```bash
range="$(resolve_task_range "$repo" "$task_id_arg")" || exit $?
read -r parent_bookmark upper_bound <<<"$range"

from_rev="$(jj -R "$repo" log -r "fork_point(${parent_bookmark} | ${upper_bound})" \
  --no-graph -T 'commit_id' 2>/dev/null)" || {
  log "Error: Could not resolve fork point between '$parent_bookmark' and '$upper_bound'."; exit 1; }

exec jj -R "$repo" diff --from "$from_rev" --to "$upper_bound"
```

Output (including colour) is relayed directly from `jj diff`. Confirmed against jj docs via context7: `jj diff --from F --to T`.

**3. Dispatcher `scripts/cli/tt`** — add `diff)  set -- task diff "${@:2}" ;;` to the alias case and a `tt diff → tt task diff` line in usage.

**4. Tests** — `scripts/cli/task/diff.test.sh` modelled on `revset.test.sh`: basic diff shows changed file content, `--task` form, no-change case (empty output), not-on-task-branch failure, nonexistent task failure, `tt diff` alias, `--help`. Plus re-run `scripts/test task/revset` to verify the refactor.

**5. Docs** — `DESIGN.md`: alias-table row `| tt diff | tt task diff |` and a command-reference bullet after the `revset` entry. `.agents/skills/tt/SKILL.md`: new `#### tt task diff` section under Task commands.
