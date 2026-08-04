---
title: "Implementation Plan"
created: 2026-08-04T07:15:33Z
updated: 2026-08-04T07:15:33Z
---
# Plan: Configurable `tt task select` UI

## Goal

Replace the bespoke 554-line interactive selector (`scripts/cli/lib/select.sh`) with a
minimal POSIX default picker living in `scripts/cli/lib/common.sh`, overridable via the
`TT_SELECT` environment variable.

## Research findings

- `scripts/cli/lib/select.sh` (554 lines) — full-screen state machine: vim nav, fuzzy
  filter, ANSI highlighting, raw-mode terminal handling. Public API is a single function
  `select_value` (stdin → stdout).
- Its only consumer is `scripts/cli/task/select:109`:
  `printf '%s' "$active_items" | sort | select_value`.
- `scripts/cli/task/select:56-60` additionally guards on `[ -t 2 ]` and `-e /dev/tty`.
- Tests to delete: `scripts/cli/lib/select.test.sh` (969 lines),
  `scripts/cli/lib/select.unit.test.sh` (71), `scripts/cli/lib/select.integration.test.sh` (144).
  `scripts/cli/task/select.test.sh` (134) is mostly skipped/indirect and gets rewritten.
- Test discovery: `scripts/test` globs `scripts/cli/**/*.test.sh`; each suite ends with
  `run_tests "<title>"`. `run_tt` in `scripts/harness/harness.sh` forwards `TT_REPO`.
- DESIGN.md references: line 213 (command table) and line 362 (`tt task select` description).
- Bash rules (`.agents/rules/bash-style.mdc`): `set -euo pipefail`, diagnostics → stderr,
  respect `NO_COLOR`, DRY helpers.

## Questionnaire transcript

| Question | Answer |
| --- | --- |
| Where should `select_value` live? | **Move into `lib/common.sh`**; delete `lib/select.sh` entirely |
| How does the user pick? | **Type the full option value** (exact match required) |
| Where is the reply read from? | **`/dev/tty`** |
| How is `TT_SELECT` invoked? | **`sh -c "$TT_SELECT"`** |
| Keep the TTY guard in `tt task select`? | **No** — guard lives only in the default picker path |
| Empty stdin behavior? | Error to stderr + exit 1, message: `Error: no options provided` |
| Test coverage? | `select_value` unit tests in `lib/common.test.sh` + rewritten `task/select.test.sh` |
| Default UI stderr format? | Spec format verbatim plus a `> ` prompt |

## Design

### `select_value` (new, in `scripts/cli/lib/common.sh`)

```
select_value
  read all of stdin into `options` (newline-separated, blank lines skipped)
  if empty            -> "Error: no options provided" >&2 ; return 1
  if $TT_SELECT set   -> choice="$(printf '%s\n' "${options[@]}" | sh -c "$TT_SELECT")"
  else                -> choice="$(_select_value ...)"   # requires /dev/tty
  validate: choice must exactly equal one of options, else
            "Error: invalid selection: <choice>" >&2 ; return 1
  printf '%s\n' "$choice"
```

`_select_value` writes to stderr:

```
Select an option:

task/foo
task/bar
task/baz

> 
```

and reads one line from `/dev/tty`. If `/dev/tty` is not available:
`Error: no interactive terminal available (set TT_SELECT to use a custom picker)` → exit 1.

Note: custom `TT_SELECT` commands inherit stderr, so `fzf` etc. render normally.

### `scripts/cli/task/select`

- Drop the `. lib/select.sh` source line (function now comes from `common.sh`).
- Drop the `[ -t 2 ] / -e /dev/tty` guard (moved into the default picker).
- Keep bookmark listing / DONE filtering / `sort` / pipe to `select_value` unchanged.
- Update `usage()` to mention `TT_SELECT`.

### Deletions

- `scripts/cli/lib/select.sh`
- `scripts/cli/lib/select.test.sh`
- `scripts/cli/lib/select.unit.test.sh`
- `scripts/cli/lib/select.integration.test.sh`

### Tests

`scripts/cli/lib/common.test.sh` — new section `select_value`:
- `TT_SELECT` receives options on stdin and its output is returned verbatim
- output not in the option list → failure + `invalid selection`
- empty stdin → failure + `no options provided`
- no `TT_SELECT` and no tty → failure mentioning `TT_SELECT`

`scripts/cli/task/select.test.sh` — rewritten:
- `TT_SELECT='head -n1'` selects the first active task
- DONE tasks are absent from the list presented to `TT_SELECT`
  (use `TT_SELECT='tee /tmp/x >/dev/null; head -n1 /tmp/x'`-style capture, or
  `TT_SELECT="cat > $capture; head -n1 $capture"`)
- no active tasks → error `No active tasks or projects found`
- invalid `TT_SELECT` output → nonzero exit

### DESIGN.md

Rewrite line 362 to describe the default picker and `TT_SELECT` override; add `TT_SELECT`
to the environment-variable documentation near line 538 (`TT_EDITOR` section).

## Task list

- [ ] 1. Checkpoint commit
- [ ] 2. Add `select_value` + `_select_value` to `lib/common.sh`
- [ ] 3. Delete `lib/select.sh` and its three test files
- [ ] 4. Update `scripts/cli/task/select`
- [ ] 5. Add `select_value` tests to `lib/common.test.sh`
- [ ] 6. Rewrite `scripts/cli/task/select.test.sh`
- [ ] 7. Run `scripts/test lib/common task/select`; shellcheck
- [ ] 8. Update DESIGN.md
- [ ] 9. Final commit
