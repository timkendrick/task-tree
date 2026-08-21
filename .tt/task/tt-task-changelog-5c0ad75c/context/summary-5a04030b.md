# `tt task changelog` — Implementation summary

## What was built

`tt task changelog [--task <task-id>] [--since <revision>] [--depth <n>] [--repo PATH]`
(alias `tt changelog`) reports the work that landed on a task branch since a reference
commit: a tree of the tasks checked into it, then a flat list of the checkpoints
recorded directly on it. `--depth` caps how many subtask levels are reported: `0` leaves
only the checkpoint section, `1` adds the tasks checked into the branch, each further
level adds a generation, and omitting it reports every level. Levels beyond the limit
are never queried, so a shallow report costs fewer VCS operations.

| File | Change |
|------|--------|
| `scripts/cli/lib/common.sh` | Added `parse_commit_message` (inverse of `format_commit_message`) and `mainline_commit_records` (first-parent commit records for a range). |
| `scripts/cli/task/changelog` | New command. |
| `scripts/cli/task/changelog.test.sh` | New suite: 19 tests, 55 assertions. |
| `scripts/cli/tt` | `tt changelog` alias and usage entry. |
| `DESIGN.md` | Alias table, §5.4 command bullet, new §6.14 subsection. |
| `.agents/skills/tt/SKILL.md` | Command reference entry. |

The traversal rests on `first_ancestors(<tip>) ~ ::<base>`, which yields a scope's
mainline directly, so first-parent walking never has to be reimplemented in bash. Each
checkin merge is recursed into via the range between its two parents, which also
excludes anything an earlier partial checkin already merged.

## Verification

- `scripts/test task/changelog` — 55 passed, 0 failed.
- `scripts/test task/changelog lib/common task/revset task/diff` — 173 passed, 0 failed.
- `scripts/test task/checkin task/checkpoint task/complete task/publish task/propagate`
  — 162 passed, 0 failed (regression cover for the `common.sh` additions).
- `shellcheck` clean on the new command apart from the repo-wide `SC1091` (sourced
  library) and `SC2016` (literal backticks in the output format).
- Exercised against this repository's own history, which produced a correct two-level
  tree plus checkpoint list for 60 commits of project history in ~2s.

## Output format

Entries are one per line, tree section first and checkpoint section immediately after,
with no blank line between them; either section is omitted when it has no entries. Every
line separates its backticked identifier from its description with ` - `, so task and
checkpoint lines read alike:

```
- `task/foo-abc12345` - Foo task
  - `task/foo-subtask-1-abc12345` [IN-PROGRESS] - Foo subtask 1
- `abcd1234` - Regenerate types
```

## Deviations from the plan

1. **`read_task_field` became `read_task_metadata`.** The planned helper took a field
   name and ran one `jj file show` per field, so every entry read its task file twice.
   It now returns `<status>\t<title>` from a single read, which also removed the `case`
   statement that chose a frontmatter parser per field name. (Code review finding,
   approved.)

2. **Record decoding extracted into `record_operation_fields`.** The plan inlined the
   "split record → `parse_commit_message` → match namespace/operation" sequence in both
   the checkin loop and the checkpoint loop. It is now a single helper returning
   `<commit-id>\t<parent-ids>\t<entity-id>\t<description>`. (Code review finding,
   approved.)

3. **Section separation and checkpoint punctuation changed after review.** The sections
   are adjacent rather than separated by a blank line, and checkpoint lines carry the
   same ` - ` separator as task lines. The requirements and architecture documents,
   written before that decision, still describe the earlier form.

4. **The planned `__deleted_task_file` test was split in two.** Its premise was wrong:
   `checkin --delete` removes the task file in a *separate commit after* the checkin
   merge, so the title still resolves at the checkin commit. The suite now has
   `__deleted_task_still_listed` (asserting that real behaviour) and
   `__unreadable_task_file_lists_id_only`, which strips the task directory out of a real
   checkin commit with `jj edit` so the ID-only fallback is exercised against genuine
   tt-produced history rather than a fabricated commit.

5. **`__checkpoints_only` was folded into `__checkpoint_ids_are_git_commit_ids`.** That
   test asserts the complete output equals a single checkpoint line, which covers both
   the checkpoints-only section and the absence of a leading separator, and additionally
   asserts the ID is the git commit ID rather than the jj change ID.

6. **Two error tests added** beyond the planned table: `__non_task_branch_rejected`
   (`--task main`) and `__project_branch_without_parent_requires_since`.

7. **The deduplication test needed `--rebase`.** A second checkin after a partial one
   conflicts on the parent's task file unless the parent tip is rebased in first, which
   is the documented rebase-refresh idiom rather than a changelog issue.

8. **`changelog.test.sh` is not executable.** Test suites in this repository are invoked
   as `bash <file>`, and the `tt` dispatcher lists executables, so an executable suite
   would appear in `tt task --help`.

## Reviewed and deliberately left as-is

- **Checkpoints are matched by exact task ID.** `tt task rename` does not rewrite commit
  descriptions, so checkpoints recorded before a rename are omitted from the changelog.
  Matching the specified `[tt:task:<task-id>:checkpoint]` form exactly was preferred over
  looser matching that could mis-attribute a foreign checkpoint.
- **Merge shapes.** The merged-in arm is taken as the last parent and a checkin commit
  that is not a merge is skipped. tt only ever creates two-parent checkin merges.
