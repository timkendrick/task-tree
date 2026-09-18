---
title: "Resolve a worktree's task the same way everywhere"
status: TODO
created: 2026-09-18T10:50:35Z
updated: 2026-09-18T10:50:35Z
---
Two mechanisms answer "which task is checked out in this worktree", and they disagree.

`_worktree__resolve_branch_at` reads the task symlink recorded in the worktree's working-copy commit and maps it to the task or project bookmark. That is exact: the symlink is the repository's own record of what was checked out, written by `tt task checkout` for this purpose.

`_task__resolve_current_branch` (via `_task__resolve_current`, over `_repo__resolve_nearest_bookmark`) instead takes the nearest bookmarked ancestor of `@`. That degrades exactly as the old attribution ranking did: once a branch write moves a bookmark to a sibling of the working-copy commit, the nearest bookmarked ancestor is some unrelated branch that happens to lie below it. Observed live, with `tt worktree list` naming an unrelated sibling task for two worktrees:

      NAME                             TASK ID                                  PATH
      default                          task/redirect-hooks-to-stderr-5296bc55   ~/Sites/task-tree/task-tree
      project/bootstrap-cli-d35756ce   task/redirect-hooks-to-stderr-5296bc55   ~/Sites/task-tree/project/bootstrap-cli-d35756ce

Both worktrees were on entirely different branches.

Callers of the nearest-bookmark path include `tt worktree list`, `tt task current`, `tt task show`, `tt task tree` and every command resolving "the current task" from the working copy, so the unification needs care: some of them want "the task this worktree has checked out" (the symlink answer), while `_task__resolve_current` also returns the nearest bookmark's *commit*, which range resolution uses as a boundary. Decide per caller which of the two it actually needs, then route each to one mechanism.

See ARCHITECTURE.md §6.3 for why the recorded answer is exact and a graph-derived one cannot be.

Scope: add coverage asserting `tt worktree list` names the right task after a bare write has advanced a sibling branch past the worktree's position.
