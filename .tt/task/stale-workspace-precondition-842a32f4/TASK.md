---
title: "Check for a stale canonical workspace before acting"
status: TODO
created: 2026-09-17T17:13:34Z
updated: 2026-09-17T17:13:34Z
---
A transaction rollback failed to restore anything, and the command reported it only as a warning:

    Rolling back transaction (restoring VCS operation: 83a967b8fddd...)
    Error: The working copy is stale (not updated since operation 83a967b8fddd).
    Warning: Could not restore the VCS operation state; manual recovery may be needed

`_history__rollback_transaction` runs the restore in the **canonical** repo, because that is the one workspace guaranteed to exist even when the invoking worktree has just been deleted. But a repository driven from task worktrees leaves the canonical workspace behind: every operation is recorded against the repo while that workspace's own working copy stays where it was, and the backend then refuses an operation restore from it. The rollback left the repository mid-transaction — a conflicted rebase applied, the task bookmark on a conflicted commit — and recovery needed a manual `jj op restore` run from a worktree that was not stale.

Two things to decide, in order:

1. **Where the staleness should be caught.** Discovering it inside a rollback is the worst moment: the command is already failing, and the report is a warning nobody can act on without knowing the operation ID. A precondition that refuses up front, naming the stale workspace and the command to refresh it, would be strictly better. The question is scope: every command that writes to a branch from a worktree other than the canonical one is exposed to this, not just the ones that roll back, so this may belong beside the existing working-copy preconditions (`_worktree__ensure_working_copy`) rather than inside the history module.

2. **What a failed restore should leave behind.** Today the rollback deletes the in-progress history entry whether or not the restore succeeded, so a failed rollback leaves no lock and no trace — the next command runs happily on a half-written repository. Keeping the entry when the restore fails would make the failure visible, at the cost of a lock the user must clear with `tt history unlock --force` once they have recovered manually.

Also consider whether the restore should simply run in the invoking worktree when it still exists, falling back to the canonical repo only when it does not (the `worktree delete` case that motivated the current placement), and whether tt should refresh a stale workspace itself rather than refusing.

Scope: add regression coverage driving a failing command from a task worktree while the canonical workspace is stale, asserting the repository is restored and no history entry survives.
