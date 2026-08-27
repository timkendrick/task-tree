---
title: "Refined Requirements"
created: 2026-08-27T10:21:32Z
updated: 2026-08-27T10:21:32Z
---
# Complete task range requirements

## Objective

Allow task range consumers to select a task's complete retained history, including work already merged into a canonical parent branch and work still unmerged on the task branch.

## Command surface

- Add `--all` to `tt revset`, `tt diff`, and `tt changelog`.
- Support the option consistently through the corresponding `tt task ...` forms and top-level aliases.
- Document the option in command usage and shell completion surfaces where applicable.
- Preserve each command's existing behavior when `--all` is absent.

## Complete task range

With `--all`, the selected range is the union of all commits attributable to the existing task across its retained lifecycle. The union includes both previously merged, potentially discontiguous ranges and the current unmerged range.

Commits attributable to the task include:

- commits made directly on the task branch;
- task-management operations performed on the task itself, including edits, context additions/removals/edits, checkpoints, reorders, and renames;
- creation, check-in, and deletion operations for direct child tasks.

Only direct-child task-management operations are independently attributable to the task. Deeper descendant work is included when it reaches the task through a direct child's check-in.

Resolving deleted tasks solely from historical commits is outside this task's scope. The target task must remain resolvable through retained task metadata or canonical VCS references.

## Command behavior

### `tt revset --all`

- Print a valid Jujutsu revset selecting the complete task range.
- Represent discontiguous historical ranges as a union without selecting unrelated intervening commits.
- Include the current unmerged range in the union.

### `tt diff --all`

- Produce one aggregate patch for changes introduced by the selected task commits.
- Exclude unrelated commits that occur between discontiguous task ranges.
- Preserve the existing default exclusion of `.tt/` and `TASK.md`.
- Preserve `--include-metadata` as the explicit way to include those paths.

### `tt changelog --all`

- Summarize work from the complete task range.
- Preserve the existing task-tree/checkpoint presentation and ordering semantics rather than grouping output by historical range.
- Preserve existing `--depth` behavior.
- When `--since <revision>` is also supplied, use it as a boundary that filters the complete selected history rather than rejecting or ignoring either option.

## Canonical branch documentation

Update `DESIGN.md` with a current-state definition of task ranges that explains:

- how canonical VCS branches for a task are identified;
- how canonical task and parent branches bound unmerged work;
- how commits attributable to the task are recognized after check-in;
- how multiple merged and unmerged ranges form a discontiguous union;
- how direct task operations and direct-child lifecycle operations participate in the task's range.

## Compatibility and errors

- Existing invocations without `--all` retain their current output and validation behavior.
- Existing task selection, repository selection, metadata filtering, changelog depth, and changelog since options continue to work with their established meanings except for the explicitly defined expansion under `--all`.
- Invalid or unresolvable task identifiers continue to fail through the commands' established error path.

## Verification

Add automated scenarios covering:

- unchanged default unmerged-only behavior;
- a task with both merged and currently unmerged ranges;
- multiple discontiguous merged ranges;
- direct commits and supported task-management commits;
- direct-child create, check-in, and delete operations;
- exclusion of unrelated intervening commits;
- aggregate diff output and metadata filtering;
- changelog ordering, depth, and `--since` interaction;
- task-qualified and top-level alias parsing, usage, and completion behavior where applicable.
