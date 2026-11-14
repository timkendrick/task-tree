---
title: "Keep the first-parent line intact when rebasing checkpoint merges"
status: IN-PROGRESS
created: 2026-11-13T16:26:20Z
updated: 2026-11-13T16:26:20Z
---
## Problem

`tt task propagate --rebase` and `tt task move` can leave a task branch whose first-parent line skips commits that belong to the branch. The cause is a merge commit inside the moved range whose first parent lies outside it.

### Background

- A task branch's **first-parent line** is the chain of commits reached by starting at the task bookmark and always following a commit's first parent. tt relies on this line being the branch's own history: `tt task changelog` walks it, and full-range discovery (`_task__get_full_range_records`) classifies merges by the shape of their parents (see ARCHITECTURE.md §5.1).
- `tt task checkpoint` merges the user's commits into the task branch with an empty `[tt:task:<id>:merge]` commit. Its first parent is the task bookmark's previous tip and its second parent is the newest user commit. An empty `[tt:task:<id>:checkpoint]` commit sits on top.
- When propagate rebases a task onto its parent, it moves only the **unmerged range**: the commits reachable from the task bookmark but not from the parent bookmark (`P..C`). It rebases the roots of that range, and their descendants, onto the parent's tip (`jj rebase -s "roots(P..C)" -d <destination>`). `tt task move` does the same with the old and new parents.

### Worked example

1. Task `C` is partially checked in to project `P`. `C`'s bookmark commit `W` is now also part of `P`'s history.
2. The user commits `c2` on top of `W` and runs `tt task checkpoint`. This creates `merge` (first parent `W`, second parent `c2`) and `checkpoint` on top. `C`'s bookmark moves to `checkpoint`.
3. `P` gains new work, `Pwork`.
4. The user runs `tt task propagate`. The unmerged range is `{c2, merge, checkpoint}`, and its only root is `c2`. Because `W` points `TASK.md` at `C`, propagate first builds a fork commit `F2` on `Pwork`, then rebases `c2` and its descendants onto `F2`.

jj rebases `c2` onto `F2`, but leaves `merge`'s other parent, `W`, where it was, because `W` was not part of the moved set:

```
before propagate                     after propagate --rebase

○  [C:checkpoint]  ← task/C          ○  [C:checkpoint]  ← task/C
○    [C:merge]                       ○    [C:merge]
├─╮                                  ├─╮
│ ○  c2                              │ ○  c2'
○ │  W   (also in project/P)         │ ○  F2 [C:fork]
├─╯                                  │ ○  Pwork  ← project/P
                                     ○─╯  W
```

After the rebase, the first-parent line from `task/C` is `checkpoint → merge → W`. It skips `F2` and `c2'`, even though they are on `C`'s branch. File contents and `TASK.md` are correct; only the graph shape is wrong. The merge's first parent `W` is now also an ancestor of its second parent `c2'`, so the first parent is redundant.

This shape arises whenever a checkpoint merge's first parent is already in the parent branch: in practice, the first checkpoint after a partial check-in. It also affects `tt task move`, which rebases the same kind of range.

## Candidate fix

After rebasing, drop redundant merge parents from the moved commits: `jj simplify-parents -s <rebased roots>` removes any parent that is an ancestor of another parent of the same commit. A probe against jj 0.47.1 confirmed it turns the example into a straight line:

```
○  [C:checkpoint]  ← task/C
○  [C:merge]       (now a single parent: c2')
○  c2'
○  F2 [C:fork]
○  Pwork  ← project/P
○  W
```

The `merge` commit then has one parent, despite its description. Consider whether that is acceptable, or whether the merge should instead be re-parented onto the rebased line so that it keeps two parents.

## Scope

- Fix `tt task propagate --rebase` and `tt task move` (and any other command that rebases a task's unmerged range, such as `tt task checkout --rebase` and `tt task checkin --rebase`, which delegate to propagate).
- Add the backend operation needed (behind `_repo__*` and a task facade), following ARCHITECTURE.md.
- Add test scenarios reproducing the worked example for propagate and move, asserting the first-parent line from the task bookmark reaches the parent's tip through the fork commit.
- Update DESIGN.md §6.8 and §6.11, and the propagate tests whose commit counts currently encode the broken shape (`test_task_propagate__rebase_after_partial_checkin_forks_underneath`, `test_task_propagate__rebase_done_child_after_partial_checkin_forks`).
