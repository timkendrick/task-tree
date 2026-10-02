---
title: "Propagate rebase leaves merges on a stale first parent"
status: TODO
created: 2026-10-02T09:07:24Z
updated: 2026-10-02T09:07:24Z
---
## Goal

Investigate and fix the shape of merge commits on a child branch after a propagate rebase.

## Problem

Propagate with `--rebase` moves the commits in child `C`'s history that are not in parent `P`'s history (`P..C`). It rebases each root of that range with `jj rebase -s <root> -d <destination>`. jj replaces only the parents of the root. A merge commit further up the range keeps any parent that is outside the moved set.

tt treats a branch's first-parent line as the branch's own history. When a merge on `C` keeps an old first parent, `C`'s own line skips `P`'s new tip.

## Worked example

`C` was partially checked into `P`. Grandchild `G` was then checked into `C` (merge `Cci`). `C` gained more work (`W2`), and `P` advanced (`Pwork`).

Before propagate:

```
o  W2                       <- C
o    Cci [G:checkin]             parents: W1 (first), Gh (second)
|\
| o  Gh [G:handoff]
| o  Gwork
| o  Gfork [G:fork]
|/
o  W1                            (already in P's history via C's partial checkin)
```

- The moved commits are `Gfork`, `Gwork`, `Gh`, `Cci` and `W2`.
- The only root is `Gfork`. Its parent `W1` is outside the moved set.
- Propagate runs `jj rebase -s Gfork -d <destination>`.

After propagate (the destination is a fork commit `F2` on `P`'s tip):

```
o  W2                       <- C
o    Cci [G:checkin]             parents: W1 (first, unchanged), Gh (second)
|\
| o  Gh
| o  Gwork
| o  Gfork
| o  F2 [C:fork]
| o  Pwork                  <- P
| ...
o |  W1                          (old commit inside P's history)
```

- The file contents are correct. A scratch-repository probe confirmed them.
- `C`'s first-parent line runs `W2 -> Cci -> W1`. It skips `F2` and `Pwork`, which are reachable only through `G`'s side.
- The expected shape has `F2` as the first parent of `Cci`, so `C`'s line runs `W2 -> Cci -> F2 -> Pwork`.

The current rebase without a fork commit produces the same shape. This behavior is not new.

## Suspected symptom (to verify)

Changelog reads `Cci` as a checkin of `G`. It lists the commits of that checkin by following `Gh`'s first parents back to `Cci`'s first parent, `W1`. That walk passes through `F2`, `Pwork` and `P`'s earlier checkin of `C`. The changelog then probably attributes `P`'s commits, including `P`'s checkin of `C`, to `G`'s checkin.

## Scope

- Reproduce the scenario in a test. Record the actual changelog output, and the output of `tt task revset --all` and `tt task diff` for `C` and `G`.
- Decide the correct first-parent shape for merges inside a moved range. Expected rule: a merge whose first parent is outside the moved set, and in `P`'s history, gets the destination as its new first parent. The second parent keeps its rebased value.
- Investigate implementation options, and record the trade-offs:
  - Post-process the rebased merges by rewriting their parents in a bare operation.
  - Use other `jj rebase` modes. Check the current `jj` documentation with context7 before relying on any flag. Note that `--simplify-parents` drops the merge parent altogether, which removes the checkin record from `C`'s first-parent line.
- Check whether the merge strategy, checkin and `tt task checkout --rebase` produce similar shapes.
- Implement the fix in the range-moving code (`_task__move_unmerged_range` or its backend), so every caller gets the corrected shape.

## Tests

- The nested grandchild scenario above under `--rebase`:
  - After propagate, the first parent of `Cci` is the destination.
  - `C`'s first-parent line runs through `P`'s tip.
  - `C`'s changelog lists `G`'s checkin with only `G`'s commits.
  - `P`'s work does not appear under `G`.
- Run the `task/propagate`, `task/changelog`, `task/revset`, `task/diff` and `task/checkin` suites.

## Documentation

- `DESIGN.md` section 6.8: describe how propagate treats merge commits inside the moved range.
