---
title: "Complete Range Architecture"
created: 2026-08-27T10:33:27Z
updated: 2026-08-27T10:33:27Z
---
# Complete task range architecture

## Scope

The `--all` option for task range consumers selects an existing non-project task's full attributable history. The default mode continues to select only the task's current unmerged range.

Full-range discovery requires the target task bookmark and its current parent bookmark. Project publish ranges, deleted-task recovery, task move history, and task rename history are outside scope. A check-in whose topology cannot identify the target task unambiguously is not included.

## Canonical VCS references

The canonical references for a task range are:

- the **task bookmark**, which identifies ongoing work and the explicit-task upper bound;
- the **current parent bookmark**, determined from the parent task file's `subtask:` frontmatter, which identifies the receiving branch and bounds current unmerged work;
- the **task creation boundary**, which is the earliest relevant commit that modifies the target task file within the ancestry of the task and parent references.

The target task file has the canonical path:

```text
.tt/task/<target-suffix>/TASK.md
```

The creation boundary establishes where attribution starts but is not itself part of the task range.

## Range components

A full task range is an ordered union of connected components. Its components can include:

- work committed directly on the task branch and later delivered to its parent;
- current work reachable from the task upper bound but not from the current parent;
- operations that modify the target task file directly;
- creation and deletion of direct child tasks;
- work delivered by direct child check-ins.

The broad component that contains a commit takes precedence over a narrower one-commit component for the same change. Duplicate components and commits are removed. Historical components retain graph order, with deterministic ordering for otherwise incomparable components, and current unmerged work is last.

## Check-in topology

A check-in is identified from VCS topology and metadata paths rather than its commit description:

1. A one-parent handoff commit changes the root `TASK.md` symlink from the source task file to the receiving task file.
2. A two-parent merge commit records the receiving branch as its first parent and the handoff as its second parent.
3. The receiving bookmark advances to the merge, while the source bookmark does not advance to the handoff.

The direction of the handoff's root `TASK.md` transition identifies the relationship to the target task:

- **Target task to current parent:** the target was checked into its parent. The attributable component ends at the handoff's parent and begins after the receiving merge's first parent. The handoff and receiving merge are boundary wrappers and are excluded.
- **Another task to target task:** a direct child was checked into the target. The attributable component includes the child's delivered work and the receiving merge on the target branch.
- **Any other transition:** the merge is unrelated or ambiguous and is excluded.

This classification does not fall back to structured commit descriptions. The detailed graph query and symlink-classification model are documented in [Topology-based Complete Range Discovery](topology-based-complete-range-discovery-214f5912.md).

## Current unmerged component

The current unmerged component is the ancestors of the task upper bound that are not ancestors of the current parent. For an implicit current task, the upper bound includes trailing work through `@` when the working copy is non-empty or `@-` when it is empty. For an explicit task, the upper bound is the task bookmark.

This definition remains the complete range when `--all` is absent. With `--all`, it is appended after historical components.

## Consumer behavior

### Revset

`tt revset --all` represents the full range as a parenthesized union of connected Jujutsu ranges, using immutable historical boundaries. Git mode prints one immutable `<base>..<tip>` range per line because Git has no single range expression for a discontiguous union.

### Diff

Jujutsu cannot aggregate a revset containing gaps in one `jj diff -r` invocation. `tt diff --all` therefore emits one ordered Git-format patch stream by diffing each connected component in sequence. Components are not labeled, and the same path can appear in more than one patch section. Existing task-metadata filtering applies to every component.

### Changelog

`tt changelog --all` combines and deduplicates first-parent records from every selected component before applying its existing tree, checkpoint, grouping, depth, title, and status behavior. Range discovery is independent of commit descriptions; changelog rendering can still interpret structured descriptions because those descriptions define its existing labels and grouping.

When `--since <revision>` is present, records already reachable from that revision are excluded from the full selection. An unresolvable revision follows the existing error path.

## Invariants

- Every emitted component is connected and non-empty.
- Historical boundaries use immutable commit IDs.
- The task creation commit and the target task's own handoff/check-in wrappers are excluded.
- Direct-child check-ins include the work delivered to the target task.
- Ambiguous symlink transitions are ignored rather than inferred from descriptions.
- Invocations without `--all` preserve established behavior.
