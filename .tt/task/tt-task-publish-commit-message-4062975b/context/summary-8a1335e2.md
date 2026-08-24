---
title: "Implementation Summary"
created: 2026-08-24T17:16:36Z
updated: 2026-08-24T17:16:36Z
---
# Implementation summary: Prompt for `tt task publish` commit message

Task: `task/tt-task-publish-commit-message-4062975b`
Requirements: `context/requirements-7e01e6e3` · Architecture: `context/architecture-570331ab`

## 1. What changed

### `scripts/cli/lib/common.sh`

`prompt()` no longer strips leading whitespace from each line, so indented content
pre-populated into an editor template survives the round trip. Only the
`-e 's/^[[:space:]]*//'` clause was dropped; comment stripping, trailing-whitespace
trimming and blank-line trimming are unchanged. `tt task checkpoint` and
`tt task checkin --context` inherit the fix.

### `scripts/cli/task/publish`

- New options `-m/--message <msg>`, `--changelog`, `--changelog-depth <n>`
  (space-form spellings only), documented in the header comment and `usage()`.
  The `--changelog` flag is held in `include_changelog`, distinguishing it from the
  changelog text that `build_change_summary` works with.
- `--changelog-depth` without `--changelog`, and a non-numeric depth, are usage
  errors raised during argument validation.
- Two module-level constants: `CHANGE_SUMMARY_HEADER` (`Change summary:`) and
  `NO_CHANGES_PLACEHOLDER` (`No code changes`).
- `build_change_summary()` shells out to the sibling `changelog` script
  (`--task <project> --since <target> [--depth N] --repo <repo>`) and renders the
  section; empty changelog output becomes the placeholder.
- `build_message_template()` renders the editor template: empty message area,
  optional change summary, then `#` hint lines naming the project and target and
  stating that an empty message cancels the publish.
- Message resolution runs after any `--rebase`/`--merge` propagation and before
  `tt_begin_transaction`, so the summary reflects the history actually being
  published and an abandoned message leaves no VCS state to unwind.
- An empty resolved message logs `Publish cancelled.` and exits 1.
- The publish merge commit is now `[tt:task:<project-id>:publish] <message>`. The
  handoff commit still carries the project title.

### `scripts/cli/task/publish.test.sh`

- Every pre-existing case that reaches the message step now passes `-m`.
- Added `_setup_two_level_tree` (task A with subtask A1 checked in, plus a
  checkpoint on the project branch), mirroring `changelog.test.sh`.
- New cases: message on the publish commit (with the handoff commit still carrying
  the title), empty-message abort, change summary content including preserved
  nesting, the `No code changes` placeholder, full history before a project's first
  publish plus only-new-work on a second publish, `--changelog-depth 1` limiting
  levels, and rejection of `--changelog-depth` without `--changelog` / with a
  non-numeric value.
- The `--help` case now asserts the three new options are documented.

## 2. Verification

| Suite | Result |
| --- | --- |
| `scripts/test task/publish` | 53 passed, 0 failed |
| `scripts/test task/checkpoint task/checkin lib/common --parallel` | 160 passed, 0 failed |
| `scripts/test task/edit --parallel` | 19 passed, 0 failed |

`task/edit` is included because `tt task edit` uses `prompt()` for the task body:
indented markdown in a body edited through the editor is no longer flattened.

`shellcheck -x` on both changed scripts reports no new findings (remaining items
are pre-existing, plus `SC2016` on regex literals, matching `changelog.test.sh`).

The rendered template was verified directly against the shipped helpers:

```
|
|
|Change summary:
|
|- `task/a-1111` - Task A
|  - `task/a1-2222` - Task A1
|- `c0ffee12` - project work
|
|# Project: project/proj-abcd1234
|# Target: main
|# An empty message cancels the publish.
```

Applying `prompt()`'s cleaning to that template with `Ship it` typed on the first
line yields exactly the message the `-m "Ship it" --changelog` path produces.

## 3. Deviations from the architecture document

1. **Blank line before the hint lines.** `build_message_template` prints the change
   summary with `printf '%s\n'` rather than `printf '%s'`. Command substitution
   strips the section's trailing newline in the caller, so without the extra
   newline the hint lines abutted the last changelog line. The rendered template
   now matches the approved preview.
2. **Editor-path tests removed.** The four cases exercising `TT_EDITOR`
   (`editor_supplies_message`, `empty_editor_message_cancels`,
   `editor_template_is_empty_without_changelog`, `changelog_matches_edited_template`)
   were written and then removed at the user's instruction: `prompt_raw` requires a
   controlling terminal, the automated environment has none, and simulating a pty
   hung the suite. The `_write_editor_stub` and `_has_tty` helpers were removed with
   them. **The editor path is covered by manual QA only** (see §4).
3. **Handoff-commit assertion.** `main-` resolves to both merge parents, so the
   assertion reads all parent descriptions via `jj log -r 'main-'` and uses
   `assert_contains` instead of `get_commit_message_first_line` + `assert_eq`.
4. **Help-case assertions** for the three new options were added; the architecture
   document did not mention them.
5. **`-m '' --changelog` left as-is** (decided during implementation): the composed
   message is non-empty, so the publish proceeds and produces a commit with an
   empty subject line followed by the change summary. `-m ''` without `--changelog`
   still cancels.

## 4. Manual QA required

The editor path has no automated coverage. In a terminal, on a scratch project:

```bash
tt task publish <project-id> --target main                 # empty template, hints stripped
tt task publish <project-id> --target main --changelog     # template carries the summary
tt task publish <project-id> --target main --changelog --changelog-depth 1
```

Check that: the template matches §2; saving with a typed first line produces
`[tt:task:<project-id>:publish] <line>` plus the summary verbatim (nesting intact);
saving an empty buffer prints `Publish cancelled.`, exits non-zero and leaves the
target bookmark unmoved; and quitting the editor non-zero aborts without publishing.

## 5. Documentation

`DESIGN.md`:

- §5 command reference for `tt task publish` — new options in the signature and prose.
- §6.0 commit-message table — `[tt:task:<project-id>:publish] <message>`; the handoff
  row still reads `<title>`.
- §6.1.1 and §6.3.1 — editor cleanup described precisely: `#` lines stripped, trailing
  whitespace and surrounding blank lines trimmed, indentation within a line preserved.
- §6.5 "`tt task publish` (project branches)" — **Commit message** and **Change
  summary** paragraphs, including the fork-point behaviour on a first publish and the
  point at which the message is resolved.
- §7 step 7 — a clause on the message prompt and `--changelog`.

`.agents/skills/tt/SKILL.md`: updated `tt task publish` signature and description.

## 6. Review outcomes

A post-implementation review raised four points:

1. **Flag naming** — `main`'s boolean and `build_change_summary`'s text both used the
   identifier `changelog`. Renamed the flag to `include_changelog`.
2. **Fixture duplication** — `_setup_two_level_tree` is near-identical to the helper
   in `changelog.test.sh` and could move to `harness.sh`. Deliberately deferred.
3. **`tt task edit` body cleanup** — documented in §6.1.1 (see above).
4. **Editor path coverage** — accepted as manual QA; DESIGN.md §11 already records
   that interactive prompts cannot be tested non-interactively.
