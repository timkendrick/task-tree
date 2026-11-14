---
title: "Implementation summary"
created: 2026-11-14T12:57:54Z
updated: 2026-11-14T12:57:54Z
---
# Implementation summary

## Problem

Rebasing a task's unmerged range moved only the range roots and their descendants. A merge in the range could have its first parent outside the range. The rebase left that first parent in place.

The first checkpoint merge after a partial check-in has this shape:

- Its first parent is the checked-in commit `W`, which the parent branch already contains.
- Its second parent is the user's commit `c2`, which is inside the range.

After `tt task propagate --rebase`, the first-parent line from the task bookmark ran `[C:checkpoint]`, `[C:merge]`, `W`. It skipped the fork commit and the rebased work.

`tt task move` had a worse version of the same problem. `W` is not in the new parent's history, so the merge kept the old parent's history inside the moved task.

## Resulting behavior

- After the rebase, each moved merge whose first parent lies outside the range takes the rebase destination as its first parent. It keeps its other parents in order.
- The merge keeps two parents, and its first parent is a tt commit.
- `tt task propagate --rebase`, `tt task checkout --rebase` and `tt task checkin --rebase` all get the fix, because they share the same range move.
- `tt task move` refuses a task that is partially checked in to its current parent:

  ```
  Error: Cannot move '<task-id>': already partially checked in to '<old-parent>'
  ```

Worked example, propagate after a partial check-in:

```
before                               after

o  [C:checkpoint]   <- C             o  [C:checkpoint]   <- C
o    [C:merge]                       o    [C:merge]
|\                                   |\
| o  c2                              | o  c2'
|/                                   |/
o  W   (in P's history)              o  F2 [C:fork]
                                     o  Pwork            <- P
```

## Design decisions

### Re-parent the merge rather than drop the redundant parent

The task description suggested `jj simplify-parents`, which removes a parent that is an ancestor of another parent. It was rejected for two reasons:

- It turns the checkpoint merge into a single-parent commit, despite its description. Its first parent also stops being a tt commit.
- It does nothing for `tt task move`. There, `W` is not an ancestor of `c2'`, so jj does not consider it redundant. A probe reported "Nothing changed".

### Replace first parents only

Only the first parent of a merge is replaced. Other parents outside the range stay where they are.

- Every merge tt creates on a task branch keeps its second parent inside the range, except a propagate merge (`propagate --merge`).
- A propagate merge's second parent is always a commit on the parent branch. Replacing it with the destination would point a `[P:propagate]` merge at the child's own fork commit.
- `propagate --merge` is due for removal. Without it, "first parents only" and "all outside parents" give the same result for every tt merge.
- A merge the user creates by hand can still carry an extra parent outside the range. This counts as the user's intent.

### Rebase first, then re-parent

- Before anything moves, the affected merges are recorded by change ID. Change IDs survive the rewrites. Commit IDs do not.
- The roots move as before.
- Each recorded merge then has its parents read again, and its first parent replaced.

Re-parenting first and rebasing afterwards also works. That order was rejected for two reasons. The roots must be read before the re-parent: read afterwards, the destination itself counts as a root of the range. It also leaves the graph in an odd intermediate state between the two steps.

### Working copy

A re-parent rewrites the merge and its descendants. When the working-copy commit descends from the merge, a bare rewrite leaves the worktree stale. The re-parent then runs through the worktree instead, as the root moves already did. The working-copy commit is resolved again after the roots move, because a carried root move changes it.

### Location

The re-parent step runs inside the shared range move. Every command that rebases a task's range uses it without changes of its own.

### No repair of branches already in the broken shape

A branch rebased the old way has its root sitting on the parent's tip, so propagate treats it as up to date. tt does not detect or repair it. Its files and `TASK.md` are correct. Only the graph shape is wrong. Repair it by hand:

```
jj rebase -s <merge> -d <fork commit> -d <second parent>
```

### Move refuses a partially checked-in task

A partially checked-in task is split across two parents. Part of its work already belongs to the old parent, and a move rebases only the rest. Probes showed both possible outcomes are wrong:

- With the old rebase, the merge brought back `W` and every commit below it on the old parent's line. The moved task contained the old parent's own work. A conflict on the rebased user commit was hidden at the tip.
- With the re-parent step, the moved task no longer contains its checked-in work. When later work edits a file the checked-in work created, the task ends up conflicted at its tip. `move` has no conflict check, so nothing reported it.

Detection uses the test propagate already applies before it builds a fork commit: a commit that the range hangs off points `TASK.md` at the task. Propagate and move share this check. Move runs it before it opens a transaction, so a refusal changes nothing.

Consequence: `tt task move` never reaches the re-parent step, because only a partial check-in produces the shape. A unit test of the shared range move covers the move-style shape directly.

## Backend operations

- `list_range_external_first_parent_changes`: change IDs, oldest first, of the commits in a range that are not roots and whose first parent is outside the range.
- `list_parent_commits`: a revision's parents, first parent first.
- `set_parents`: replace a revision's parents in the given order, as a bare rewrite. Descendants stay on top of it.
- `reattach_worktree` accepts one or more destinations. With several, the rewritten commit becomes a merge with those parents in order.

## Tests

- Backend unit tests for each new or changed operation, including parent order and a working copy carried across a multi-parent rewrite.
- Unit tests for the shared range move (move-style shape, destination without `W`) and for the partial check-in check.
- Propagate after a partial check-in, for an in-progress and a `DONE` child: the first-parent line passes through the fork commit to the parent's tip, and the merge's parents are the fork commit and then the user commit. The commit counts of these tests are the same in both shapes, so they stayed unchanged.
- Propagate with the working copy above the merge and a pending edit: the shape is correct, the edit survives, and the worktree is not stale.
- Propagate with a grandchild that existed before the child's partial check-in and was checked in after it. This shape gives the grandchild's check-in merge an outside first parent. The existing nested-grandchild test does not produce it, because creating the grandchild after the partial check-in adds a commit to the child first.
- Move refusal for a partially checked-in task, with and without a checked-in grandchild. Each asserts that no transaction was opened and no bookmark moved.

With the re-parent step disabled, every new first-parent assertion fails.

## Probe findings (jj 0.47.1)

- `jj rebase -s <roots> -d <dest>` replaces only the parents of the roots. `jj rebase -r <range> -d <dest>` gives the same result for this shape.
- `jj rebase -s <rev> -d A -d B` sets the parents of `rev` to `A` then `B`, in that order.
- The template expression `parents.first().contained_in("<revset>")` selects commits by their first parent.
- A bare rewrite of a commit below the working copy leaves the worktree stale. The same rewrite run through the worktree updates the files and keeps pending edits.

## Limitations

- Change IDs must resolve to a single commit (no divergent changes). The existing working-copy move has the same requirement.
- After `propagate --rebase` moves a propagate merge, its second parent stays at the old parent tip and becomes redundant. Removing `propagate --merge` removes this case.
