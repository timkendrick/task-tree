---
title: "Implementation Summary"
created: 2026-11-13T21:30:09Z
updated: 2026-11-13T21:30:09Z
---
# Implementation summary

## Outcome

Commits that tt creates now hold only task metadata. Commits that the user creates hold only project files. `tt task checkpoint` no longer records the working copy. It merges the user's commits into the task branch and records an empty checkpoint commit on top.

A migration script rewrites existing repositories to follow the same conventions. It is attached to this task as the context file "History migration: merge-based checkpoints".

## Checkpoint behavior

Without `--task`, `tt task checkpoint` acts on the current task:

- It requires a clean working copy. There is no override.
- It collects the commits reachable from the working copy's parent but not from the task bookmark.
- If there are any, it creates an empty `[tt:task:<id>:merge] <title>` commit. The bookmark's tip is the first parent. The working copy's parent is the second parent.
- It creates an empty `[tt:task:<id>:checkpoint] <message>` commit on the merge, or on the bookmark's tip when nothing needs merging.
- It advances the bookmark to the checkpoint and moves the working copy onto it.

Example:

```
before                                   after

@  (clean)                               @
o  C2                                    o  [T:checkpoint] <message>   <- task/T
o  C1                                    o    [T:merge] <title>
o  [T:edit]   <- task/T                  |\
                                         | o  C2
                                         | o  C1
                                         |/
                                         o  [T:edit]
```

The command refuses in these cases:

- A commit to be merged changes task metadata (`.tt/task/**` or the root `TASK.md`). The error lists the paths.
- The merge commit comes out conflicted. The transaction rolls back.

With `--task <task-id>`, the command records only the empty checkpoint commit on that branch. It merges nothing and accepts a dirty working copy. This follows the existing rule that an explicit task ID means "the branch as it stands".

Hooks run in this order when there is something to merge:

1. pre-merge (blocking)
2. post-merge (blocking; a failure rolls back the whole command)
3. pre-checkpoint (blocking)
4. post-checkpoint (optional)

The merge hooks receive `TT_MERGE_HEAD`, the commit being merged in. post-merge also receives the merge commit as `TT_COMMIT`.

`tt task log` shows the merge event with the Unicode glyph U+2443 (inverted fork) or the Nerd Font icon `nf-oct-git_pull_request`. It shows no label.

## Design decisions

- **Two commits per checkpoint.** The merge and the checkpoint are separate commits. Every checkpoint is therefore the same kind of commit: empty, single-parent, and on the branch's first-parent line.
- **Merge described by the task title.** Only the checkpoint commit carries the user's message.
- **Empty marker when nothing needs merging.** The command does not refuse. The empty checkpoint serves as a milestone.
- **Plain branch write.** The command builds the commits without a working copy, advances the bookmark, and moves its own clean working copy onto the result. Only `tt task checkout` and `tt workspace init` remain working-copy-bound.
- **Range of commits to merge.** The range is every commit the working copy's parent reaches that the bookmark does not. This also covers a bookmark that another command advanced while the user was committing.
- **Removed `--squash`.** The option and its supporting code are gone, including the backend squash operation and a range query that only checkpoint used.

## Documentation

- DESIGN.md gains a "Metadata and data" section. It also describes the new checkpoint flow, the merge commit type, the hooks, the log event, the guard tables and the workflow.
- ARCHITECTURE.md lists four commands that create merges and two working-copy-bound commands.
- The tt skill describes the new checkpoint flow and when a clean working copy is required.
- The user workflow no longer tells users to accumulate context in `./TASK.md`. That instruction contradicted the metadata rule.

## Tests

- The checkpoint suite covers the merge shape and parent order, the empty marker, `--task`, the refusals, the hook order and the post-merge rollback.
- The test helper `checkpoint_task` commits pending changes before it checkpoints. It commits only when the working copy is dirty. An unconditional commit would add a jj operation between tt commands and break history-chain assertions.
- A new helper, `checkpoint_task_in_worktree`, does the same from inside a worktree.
- Four propagate tests count the extra merge and checkpoint commits. These counts encode the first-parent issue described below.

## Deviations from the agreed plan

- The test helper commits only a dirty working copy, not every time.
- The range query that checkpoint uses was kept and changed to the plain range, not removed.
- DESIGN.md now shows the editor template as `# Task: <task-id>`, which matches what the command prints.
- `.agents/plans/.gitignore` now ignores everything under `.agents/plans`.

## Follow-up task

`task/propagate-checkpoint-merge-parents-2837f3d1` covers a remaining issue. `tt task propagate --rebase` and `tt task move` move only the commits the parent branch lacks. A checkpoint merge whose first parent is already in the parent branch keeps that parent after the rebase. The branch's first-parent line then skips the rebased commits. File contents stay correct. A candidate fix runs `jj simplify-parents` on the moved commits.

## History migration script

The script rewrites every commit from the oldest `[tt:task:` commit onward. It applies five fixes:

1. It abandons empty, undescribed commits that are not a working copy.
2. It drops redundant parents from tt merges with more than two parents.
3. It splits each checkpoint that changes files into a data commit and an empty checkpoint.
4. It moves user commits beneath a checkpoint onto a side arm joined by a new merge.
5. It gives user commits beneath any other non-merge tt commit a merge and a generated checkpoint.

Older commit message formats and workspace setup commits before the first task are not changed. A final phase restores the committer timestamps that jj replaced. It rewrites the git commit objects directly, because jj cannot set committer timestamps.

A real run checks every workspace first. It records the starting state, applies the fixes, and verifies file contents and the convention rules. On any failure, it restores the starting operation and git branches. On success, it updates every workspace and records the run in `.tt/history`.

Results:

- This repository (about 2,000 commits): 155 fixes in 35 minutes.
- The grfn repository (about 4,800 commits): 528 fixes in 6.3 hours, after one-off repairs of shapes the script cannot fix.
- On both, all bookmarks kept identical contents and the convention check reported no violations. The committer timestamps were then restored in seconds.
- Synthetic tests cover every fix case, colocated and non-colocated repositories, a second workspace, a failing run, a dirty workspace and a copied repository.

Testing found these bugs, all fixed:

- A locally deleted bookmark broke the verification step.
- The script did not read task titles or prefixes when run from outside the repository.
- Workspace updates ran after the history entry closed. `tt history undo` would then refuse.
- The pattern for older message formats matched user commits such as `Checkpoint before ...`. Three merges in this repository got such a commit as first parent, and were corrected by hand.
- Workspace setup commits before the first task, and a merge with three parents, made the convention check fail.
- A git import during the timestamp phase rebased orphaned commits. The phase now disables that behavior.
- A rollback in a non-colocated repository left git branches on the rewritten commits. The rollback now resets them.

## Known limitations of the migration script

- Each fix rewrites every later commit, so the run time grows with the square of the history size.
- The script does not fix these shapes:
  - user commits that change task metadata;
  - tt commits other than checkpoints that change project files;
  - checkpoints that change only task metadata;
  - a user commit with two or more tt children that each need a fix;
  - user runs that contain a merge.
- A real run with any of these shapes fails verification and restores the starting state, possibly after hours. `--check` and `--dry-run` show them in advance.
- Rewritten commits need a force-push.
