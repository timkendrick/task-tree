---
title: "Topology-based Complete Range Discovery"
created: 2026-08-27T11:20:32Z
updated: 2026-08-27T11:20:32Z
---
# Topology-based complete task range discovery

## Scope

Complete task ranges are derived from commit topology and task metadata paths, without inspecting commit descriptions. The approach supports existing non-project tasks with their current task and parent bookmarks. Task move, task rename, deleted-task recovery, and project publish ranges are outside scope.

## Canonical references and bounds

The target task bookmark identifies ongoing task history. Its current parent bookmark identifies the branch receiving target-task check-ins. The graph search is bounded by these two task-specific heads rather than every repository bookmark.

The target task file path is:

```text
.tt/task/<target-suffix>/TASK.md
```

Within the ancestry of the task and parent heads, the earliest commit modifying that path is the task creation boundary. That commit is a boundary only and is excluded from the task range.

## Direct waypoint commits

Commits modifying the target task file are direct waypoints. Depending on their topology, these changes represent:

- task metadata operations performed directly on the target;
- direct-child creation or deletion;
- the handoff side of a direct-child check-in;
- metadata commits already contained in a broader merged or unmerged task range.

Broader range components take precedence over individual waypoint commits so the same change is not emitted twice.

## Check-in discovery

A task check-in is recognized from the invariant graph shape created by `tt task checkin`, not from its description:

1. A one-parent handoff commit changes the root `TASK.md` symlink from the source task file to the receiving task file.
2. A two-parent merge commit is created with the receiving branch as its first parent and the handoff as its second parent.
3. The receiving bookmark advances to that merge; the source bookmark does not advance to the handoff.

Candidate merges can be selected conceptually with:

```text
bounded_history
& merges()
& children(files(root-file:"TASK.md"))
```

For each candidate, its ordered parent list must show that the symlink-changing commit is the second parent. The symlink transition is obtained from that handoff commit's root `TASK.md` diff. A single templated `jj log` can return commit IDs, ordered parents, timestamps, changed task paths, and the per-commit symlink patch.

## Check-in classification

Let `T` be the target task and `P` its current parent.

- A handoff transition from `T`'s root `TASK.md` target to `P`'s root `TASK.md` target is a check-in of `T` into `P`.
  - Emit the connected component from the merge's first parent to the handoff's parent.
  - Exclude the handoff and receiving merge wrapper commits themselves.
- A handoff transition from another task's root `TASK.md` target to `T`'s root `TASK.md` target is a direct-child check-in to `T`.
  - Emit the connected component from the merge's first parent to the merge commit.
  - This includes the direct child's delivered work.
- Any transition that does not unambiguously identify `T` as source or receiver is ignored.

This symlink-only classification intentionally does not fall back to commit descriptions or per-merge incoming-arm analysis. A check-in whose source or destination cannot be identified from the symlink transition is therefore not included.

## Current unmerged work

The current unmerged component continues to use the established task range calculation:

```text
ancestors(task upper bound) minus ancestors(current parent)
```

Implicit invocation preserves trailing work through `@` or `@-`; explicit `--task` remains bounded by the task bookmark.

## Shared output model

Range discovery emits ordered connected records containing immutable base and tip commit IDs plus ordering metadata. All consumers use the same records:

- `tt revset --all` joins components as a Jujutsu union.
- `tt revset --all --git` prints one immutable Git range per line.
- `tt diff --all` diffs each connected component and concatenates the Git patches in order.
- `tt changelog --all` gathers and deduplicates first-parent records from the components before applying its established tree/checkpoint rendering.

The implementation does not inspect structured commit descriptions while discovering the complete range. Changelog may continue parsing descriptions after selection because descriptions define its existing user-facing labels and grouping semantics.
