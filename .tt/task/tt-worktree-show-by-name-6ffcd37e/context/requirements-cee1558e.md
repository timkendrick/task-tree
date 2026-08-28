---
title: "Refined requirements: locate worktree show target by --name"
created: 2026-08-28T10:10:41Z
updated: 2026-08-28T10:10:41Z
---
# Requirements: Locate `tt worktree show` target by `--name`

## Goal

`tt worktree show` locates a worktree by the **jj workspace name** instead of by the task
currently checked out in it. The `--task <task-id>` flag is removed entirely and replaced by
`--name <worktree-name>`.

## Motivation

A task ID does not uniquely identify a workspace: several workspaces can have the same task
checked out, and a worktree's currently-checked-out task may differ from the task it was
created for. The jj workspace name is stable and unique per repository, so it is the correct
key for this lookup.

## Definition of "name"

`--name` is matched **exactly** against the jj workspace name — the `NAME` column of
`tt worktree list`. Dedicated worktrees are created by
`jj workspace add --name <task-id> ...`, so the name usually equals the task ID at creation
time, but it does not track subsequent checkouts. The main workspace is normally named
`default`.

## Command contract

```
tt worktree show --name <worktree-name> [--repo PATH]
```

- `--name <worktree-name>` — required. Exact jj workspace name.
- `--repo PATH` — unchanged: overrides `TT_REPO`; defaults to walking up from CWD to find `.jj`.
- `-h`, `--help` — unchanged.
- Bare positional arguments remain rejected with usage on stderr, exit 1.
- Missing `--name` prints usage on stderr, exit 1.

### Success

Prints the symlink-resolved absolute path of the named workspace to stdout, exit 0.

### Name resolution rules

1. The name is **not** validated against the task/project ID format. Workspace names are
   arbitrary jj strings (e.g. `default`), so the only check is existence in
   `jj workspace list`.
2. The repository root is never a valid result. Detection is by **path**, not by name: the
   named workspace's path is symlink-resolved and compared against the symlink-resolved
   canonical repository root. This remains correct when the main workspace has been renamed,
   and when `show` is invoked from inside a dedicated worktree (where `resolve_repo` returns
   the worktree, not the canonical repo).
3. Lookup is independent of which task is checked out in any workspace.

### Failure modes

All errors are written to stderr and exit 1. Each is a single line, with no hint line.

| Condition | Message |
|---|---|
| No workspace with that name | `Error: No worktree named '<name>'` |
| Name resolves to the repository root | `Error: Worktree '<name>' is the repository root, not a dedicated worktree` |
| Workspace has no recorded path, or the recorded path is not a directory | `Error: Worktree '<name>' has an invalid path` |

Terminology note: "repository root", not "main workspace", consistent with the rest of the
codebase and DESIGN.md.

## Out of scope

- `tt worktree list --task <task-id>` is unchanged. Filtering a listing by checked-out task is
  a different operation from locating a single worktree.
- `tt worktree delete`, `tt worktree switch`, `tt worktree active` are unchanged.

## Documentation

- `DESIGN.md` §5.5 — rewrite the `tt worktree show` bullet for the new contract.
- `.agents/skills/tt/SKILL.md` §`tt worktree show` — update the signature to `--name` and
  remove the stale "falls back to the repo root" sentence.

## No trace of prior behavior

No source comment, help text, doc sentence, or test name may reference `--task` on
`worktree show`, or describe the change as a migration/rename. The command reads as if it
had always taken `--name`.

## Test coverage (`scripts/cli/worktree/show.test.sh`)

1. Dedicated worktree is returned for its exact name.
2. Unknown name errors with `No worktree named`.
3. `--name default` (repository root) errors with `is the repository root`.
4. Lookup from inside the named worktree returns that worktree.
5. Lookup of a different worktree from inside a worktree returns the other worktree.
6. Bare positional argument is rejected with usage.
7. `--help` documents `--name` and `--repo` as required/optional per the existing assertions.
8. **Name is decoupled from the checked-out task** — create a worktree for task A, then check
   out task B inside it; `--name <task-A-id>` still returns that worktree, and
   `--name <task-B-id>` fails with `No worktree named` (no workspace bears task B's name).
9. **Invalid path** — remove a registered workspace's directory from disk, leaving the jj
   workspace registered; `--name` for it errors with `has an invalid path`.

All tests must pass, as must the rest of the `scripts/cli/worktree/` suite.
