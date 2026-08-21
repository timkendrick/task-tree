---
title: "Requirements"
created: 2026-08-21T10:36:12Z
updated: 2026-08-21T10:36:12Z
---
# `tt task changelog` — Requirements

## Summary

A new command `tt task changelog [--task <task-id>] [--since <revision>] [--repo PATH]`
(alias `tt changelog`) reports all work that landed on a task branch since a reference
commit: subtask checkins (as a nested tree) and checkpoints made directly to the branch
(as a flat list).

## Inputs

| Option | Default | Meaning |
|--------|---------|---------|
| `--task <task-id>` | current task/project branch | Branch to report on. Must be a task or project branch (validated against the configured task/project prefixes); must exist. |
| `--since <revision>` | parent branch of `<task-id>` | Any jj revision expression. The reference commit is the fork point of `<revision>` and the branch tip. |
| `--repo PATH` | `TT_REPO`, else walk up to `.jj` | Repository root, as for all other commands. |
| `-h`, `--help` | — | Print usage to stdout, exit 0. |

**Tip resolution.** The tip is always the task bookmark itself, both with and without
`--task`. Trailing commits beyond the bookmark are never reported (this differs from
`tt task revset` / `tt task diff`, which extend to `@` / `@-`).

**Reference commit.** `fork_point(<since-or-parent-branch> | <tip>)`, i.e. the most
recent common ancestor of the branch tip and the given revision — the same resolution
used by `tt task revset --git` (`resolve_task_fork_point`).

**Project branches** are accepted. A project branch typically has no parent branch: if
no parent can be found and `--since` was not given, the command exits with an error
stating that `--since` is required.

## Errors (exit 1, message on stderr, nothing on stdout)

- Not on a task or project branch and no `--task` given.
- `--task` is not a task/project branch, or the bookmark does not exist.
- `--since` cannot be resolved to a revision.
- No common ancestor between `<since>` and the tip.
- No parent branch found and no `--since` given.

## Traversal model

Commit conventions are those of DESIGN.md §6.0. Given a tip `T` and reference commit `R`:

1. **Mainline walk.** Starting at `T`, visit commits by following the *first* parent,
   stopping as soon as the current commit is no longer within `R..T` (i.e. it is `R` or
   an ancestor of `R`). Only commits on this path are considered "on the branch".
2. **Checkpoints.** Mainline commits whose description starts with
   `[tt:task:<task-id>:checkpoint] ` (where `<task-id>` is the branch being reported on)
   form the checkpoint section.
3. **Checkins.** Mainline commits whose description starts with
   `[tt:task:<subtask-id>:checkin] ` form depth-0 tree entries.
4. **Recursion.** For a checkin merge commit `C` with first parent `m` (mainline) and
   second parent `h` (the handoff arm), the newly merged work is the range `m..h`.
   Recurse using the same mainline walk with tip `h` and reference `m`; any checkin
   commits found there become the children of `C`'s entry, and so on recursively.
5. **Non-checkin merges** (e.g. those created by `tt task propagate --merge`, which merge
   the parent branch into the task branch) are traversed via their first parent only;
   their merged arm is not reported. Work that arrived from the parent branch is
   therefore never attributed to this task.
6. `[tt:task:<id>:publish]` merge commits are **not** reported; only `:checkin]` merges
   form tree entries.

## Entry resolution

For a checkin of task `X` at merge commit `C`:

- **Title and status** are read from `.tt/task/<slug>/TASK.md` at revision `C` — the
  version as checked in, *not* the version on `X`'s canonical branch (which may have
  moved on) and not the version at the reported branch's tip (where the file may have
  been deleted or edited later).
- If that file cannot be read at `C`, the entry shows the task ID alone, with no title
  and no status flag.
- A task is flagged `[IN-PROGRESS]` when, and only when, its resolved frontmatter status
  is exactly `IN-PROGRESS`.

**Deduplication.** A task may be checked in multiple times (partial checkins followed by
a final checkin). Sibling entries are deduplicated by task ID *within a single parent
entry* (not globally across the tree): the entry occupies the position of the task's
**earliest** checkin in that range, while its title and status come from its **latest**
checkin, and its children are the union of the work merged by all of its checkins (in
chronological order, themselves deduplicated by the same rule).

**Ordering.** Chronological, oldest first, within every section and at every tree depth —
i.e. the reverse of the mainline walk order.

## Output format

Written to stdout. Two optional sections, in this order:

1. **Task tree** — emitted when at least one subtask checkin was found.
2. **Checkpoint list** — emitted when at least one checkpoint of the reported branch was
   found on the mainline.

Sections are separated by one blank line (two consecutive newlines). Separators collapse:
when only one section is present it appears alone, with no leading or trailing blank
line. When neither section is present, the command exits 0 having written nothing at all
to stdout. Output always ends with a single trailing newline.

**Task tree lines.** Two spaces of indentation per depth level:

```
- `<task-id>` - <title>
- `<task-id>` [IN-PROGRESS] - <title>
- `<task-id>`
```

(the third form is used when the task file could not be read at the checkin commit).

**Checkpoint lines.** The 8-character *Git commit ID* (not the jj change ID), followed by
the first line of the checkpoint message with the `[tt:task:<task-id>:checkpoint] `
prefix removed:

```
- `abcd1234` <checkpoint message first line>
```

### Example

```
- `task/foo-abc123` - Foo task
  - `task/foo-subtask-1-abc123` - Foo subtask 1
  - `task/foo-subtask-2-abc123` - Foo subtask 2
- `task/bar-abc123` - Bar task
  - `task/bar-subtask-1-abc123` - Bar subtask 1
    - `task/bar-subtask-1-subtask-1-abc123` [IN-PROGRESS] - Bar subtask 1.1
- `task/baz-abc123` - Baz task

- `abcd1234` Regenerate types
- `cdef5678` Fix deployment issues
```

## Side effects

None. The command is read-only: no hooks, no transaction, no bookmark or working-copy
changes. Diagnostics go to stderr; report content goes to stdout.

## Documentation

- `DESIGN.md`: alias table (§5), `tt task` command reference (§5.4), and a subsection
  describing the traversal and output format.
- `.agents/skills/tt/SKILL.md` command reference entry.
