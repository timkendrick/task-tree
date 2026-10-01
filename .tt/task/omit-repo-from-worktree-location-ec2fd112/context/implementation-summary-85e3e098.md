---
title: "Implementation summary"
created: 2026-10-01T14:14:12Z
updated: 2026-10-01T14:14:12Z
---
## Outcome

The task premise still held after task/standardize-vcs-operations-d5419005. `_worktree__find_for_branch` deliberately returned the canonical repository, ranked last. `tt worktree sync --all` also treated the canonical repository like any worktree. That is why a sync moved the `default` workspace onto the new `project/bootstrap-cli-d35756ce` tip.

tt now acts on the canonical repository only when a command runs from it, or when a command names it explicitly. This supports both ways of working:

- Without worktrees, the user works in the canonical repository, so commands run from it may act on it.
- With worktrees, the canonical repository stays wherever the user left it.

## Behavior changes

- `tt task checkout --worktree` never reuses the canonical repository. An explicit `--worktree=<path>` is no longer refused because the canonical repository has the task checked out.
- `tt task checkin` finds the parent's workspace among worktrees only. It falls back to the canonical repository when no worktree has the parent checked out. `--switch` is no longer ambiguous when both are on the parent.
- `tt worktree sync --all` brings the canonical repository forward only when run from it.
- Out-of-sync warnings never name the canonical repository.
- `tt worktree list` lists worktrees only.

## Implementation

In `scripts/cli/lib/worktree.sh`:

- `__worktree__list_worktree_entries` lists every workspace except the canonical repository. It compares symlink-resolved paths.
- `__worktree__list_in_scope_entries` lists the worktrees plus the current workspace.
- `_worktree__find_for_branch REPO BOOKMARK` uses the worktree list. It returns worktrees in listing order, with no ranking. The unused prefix parameters are gone.
- `__worktree__list_behind` (sync and out-of-sync warnings) uses the in-scope list.
- `_worktree__list` (`tt worktree list`) uses the worktree list.
- `_worktree__list_entries`, `_worktree__resolve_name`, `_worktree__resolve_path` and `_worktree__list_holding_descendants` still cover every workspace. Commands use them to validate a path the user named, and `tt task rename` needs the canonical repository in its safety check.

`tt task checkin` no longer has its own canonical-repository filter (`deletable_child_worktrees`). Single-target callers still refuse when several worktrees hold a branch.

## Terminology

DESIGN.md (section 2) and the tt skill define a worktree as any jj workspace other than the canonical repository. Code, comments and tests no longer call worktrees "secondary" or the canonical repository "primary". DESIGN.md section 6.16 still says "canonical workspace" for the canonical repository.

## Tests

New scenarios cover `lib/worktree`, `task/checkout`, `task/checkin`, `worktree/sync` and `worktree/list`. Each new test fails against the previous implementation. `task/propagate`'s parent-worktree test now parks a dedicated project worktree, and checks that the canonical repository is not reported. That test was the only full-suite failure, and it passes after the update.

## Follow-up

Writing the sync tests exposed an existing bug: a write to an ancestor branch can move the invoking worktree onto that branch. task/ancestor-branch-write-moves-worktree-fb5b1ff6 tracks it, including the test workaround to remove from `scripts/cli/worktree/sync.test.sh`.
