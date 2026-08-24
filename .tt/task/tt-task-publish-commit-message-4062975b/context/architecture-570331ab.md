---
title: "Architecture"
created: 2026-08-24T16:47:42Z
updated: 2026-08-24T16:47:42Z
---
# Architecture: Prompt for `tt task publish` commit message

Task: `task/tt-task-publish-commit-message-4062975b`
Requirements: context `context/requirements-7e01e6e3`

## 1. Files touched

| File | Change |
| --- | --- |
| `scripts/cli/lib/common.sh` | `prompt()` no longer strips leading whitespace per line. |
| `scripts/cli/task/publish` | New flags, two local helper functions, message resolution step. |
| `scripts/cli/task/publish.test.sh` | Existing cases get `-m`; new cases for the editor/changelog paths. |
| `DESIGN.md` | Command reference, §6.5, commit-message table, §7 walkthrough. |

No change to `changelog`, `checkpoint`, `checkin`, or the harness.

## 2. `prompt()` preserves indentation

The per-line leading-whitespace strip in the shared helper is treated as a defect
and removed, rather than adding a parallel helper. `tt task checkpoint` and
`tt task checkin --context` inherit the fix (indented content in their messages now
survives the editor round trip too).

```bash
# Usage: message=$(prompt <<< "$template")
# Reads template from stdin, opens editor, strips #-comment lines, trims trailing
# whitespace and surrounding blank lines, prints cleaned text to stdout (empty
# string if blank after stripping). Leading whitespace within a line is preserved,
# so indented content such as a nested changelog tree survives the round trip.
# Exits non-zero if editor exits non-zero.
prompt() {
  local raw
  raw="$(prompt_raw)" || return 1
  local msg
  msg="$(printf '%s' "$raw" | sed '/^#/d' | sed -e 's/[[:space:]]*$//')"
  # trim leading/trailing blank lines
  msg="$(printf '%s' "$msg" | awk 'NF{found=1} found{print}')"
  printf '%s' "$msg"
}
```

The only functional edit is dropping `-e 's/^[[:space:]]*//'`. Trailing blank lines
still disappear: each is reduced to an empty line by the trailing-whitespace `sed`,
and command substitution then strips the trailing newlines.

## 3. `publish` — new state and argument parsing

```bash
  local message=''
  local message_provided=false
  local changelog=false
  local changelog_depth=''
```

`message_provided` is required to distinguish "no `-m`" (open the editor) from
`-m ''` (empty message → abort). Space-form spellings only:

```bash
      -m|--message)
        [[ $# -lt 2 ]] && { usage >&2; exit 1; }
        message="$2"; message_provided=true; shift 2 ;;
      --changelog)   changelog=true; shift ;;
      --changelog-depth)
        [[ $# -lt 2 ]] && { usage >&2; exit 1; }
        [[ "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 1; }
        changelog_depth="$2"; shift 2 ;;
```

Validated immediately after the parse loop, alongside the existing `--target`
check:

```bash
  # A depth is only meaningful when a changelog is being generated.
  if [[ -n "$changelog_depth" && "$changelog" != true ]]; then
    usage >&2; exit 1
  fi
```

## 4. Local helpers in `publish`

Module-level constants:

```bash
readonly CHANGE_SUMMARY_HEADER='Change summary:'
readonly NO_CHANGES_PLACEHOLDER='No code changes'
```

### 4.1 `build_change_summary`

Shells out to the sibling `changelog` script, exactly as the existing propagation
step shells out to `propagate`.

```bash
# Usage: build_change_summary REPO PROJECT_ID TARGET [DEPTH]
#
# Prints the change summary section for PROJECT_ID's work since it last diverged
# from TARGET: a leading blank line, the header, a blank line, then the changelog
# ("No code changes" when there is none).
#
# The leading newline is the blank line separating the section from the message
# above it; callers append the section to a message that does not yet end in a
# newline.
#
# Exit 1: the changelog could not be generated.
build_change_summary() {
  local repo="$1" project_id="$2" target="$3" depth="${4:-}"

  local -a depth_args=()
  [[ -n "$depth" ]] && depth_args=(--depth "$depth")

  local changelog
  changelog="$("$SCRIPT_DIR/changelog" \
    --task "$project_id" \
    --since "$target" \
    ${depth_args[@]+"${depth_args[@]}"} \
    --repo "$repo")" || return 1

  [[ -z "$changelog" ]] && changelog="$NO_CHANGES_PLACEHOLDER"

  printf '\n%s\n\n%s\n' "$CHANGE_SUMMARY_HEADER" "$changelog"
}
```

The `${depth_args[@]+"${depth_args[@]}"}` idiom is the codebase's existing
`set -u`-safe empty-array expansion (see `changelog`'s `render_entries`).

### 4.2 `build_message_template`

```bash
# Usage: build_message_template PROJECT_ID TARGET CHANGE_SUMMARY
#
# Prints the editor template: an empty message area, the change summary section
# when one was generated, then hint lines that the editor prompt strips.
build_message_template() {
  local project_id="$1" target="$2" change_summary="$3"

  printf '\n'
  [[ -n "$change_summary" ]] && printf '%s' "$change_summary"
  printf '\n# Project: %s\n# Target: %s\n# An empty message cancels the publish.\n' \
    "$project_id" "$target"
}
```

Rendered template with `--changelog` (`·` marks a blank line):

```
·                                   <- message area (cursor here)
·                                   <- separator
Change summary:
·
- `task/a-1111aaaa` - Parent task
  - `task/b-2222bbbb` - Child task
·
# Project: project/my-proj-1234
# Target: main
# An empty message cancels the publish.
```

## 5. Message resolution step

Placed after the `--rebase`/`--merge` propagation block and its clean-working-copy
re-check, and **before** `tt_begin_transaction`, so that an aborted or empty
message leaves no VCS state to unwind and the summary reflects post-propagation
history.

```bash
  # --- Resolve the publish commit message ---
  local change_summary=''
  if [[ "$changelog" == true ]]; then
    change_summary="$(build_change_summary \
      "$repo" "$child_bookmark" "$target" "$changelog_depth")" || {
      log "Error: Could not summarize '$child_bookmark' since '$target'."
      exit 1
    }
  fi

  if [[ "$message_provided" == true ]]; then
    if [[ -n "$change_summary" ]]; then
      message="${message}"$'\n'"${change_summary}"
    fi
  else
    local template
    template="$(build_message_template "$child_bookmark" "$target" "$change_summary")"
    message="$(prompt <<< "$template")" || exit 1
  fi

  if [[ -z "$message" ]]; then
    log "Publish cancelled."
    exit 1
  fi
```

Both branches yield the same bytes for the same user text. Command substitution
strips the section's trailing newline, so the `-m` branch re-adds one newline to
close the message line, and the section's own leading newline supplies the blank
separator:

```
Ship v2                        message
                               (section's leading newline)
Change summary:
                            
- `task/a-1111aaaa` - Parent task
  - `task/b-2222bbbb` - Child task
```

## 6. Commit construction

Only the publish merge commit changes:

```bash
  # handoff — unchanged, still the project title
  jj -R "$target_ws" commit -m "$(format_commit_message "task" "handoff" "$task_id" "$task_title")"
  ...
  # publish merge — now the user message (may be multi-line)
  jj -R "$target_ws" describe -m "$(format_commit_message "task" "publish" "$task_id" "$message")"
```

`format_commit_message` already documents multi-line descriptions, and
`parse_commit_message` only ever inspects a first line, so `tt task changelog` run
against the *target* branch still parses these commits correctly.

`task_title` is still read from the project's task file because the handoff commit
needs it.

## 7. Control flow

```
main
├── parse args                       -m / --changelog / --changelog-depth
├── validate --target, --changelog-depth pairing
├── resolve repo / prefixes / worktree
├── resolve project bookmark, validate it is a project branch
├── validate --target resolves
├── check working copy clean
├── read task title (handoff message)
├── [--rebase|--merge] propagate  ──▶ scripts/cli/task/propagate
├── build_change_summary          ──▶ scripts/cli/task/changelog --task … --since …
├── prompt                        ──▶ $TT_EDITOR                (skipped with -m)
├── abort if message empty                            ◀── no VCS state touched yet
├── tt_begin_transaction
├── … handoff commit, merge, bookmark move, return to project branch …
└── tt_commit_transaction
```

## 8. Never-published projects

No code path is needed. Verified on jj 0.43: `fork_point(main | project/x)` for
fully disjoint histories resolves to the virtual root commit
`0000000000000000000000000000000000000000`, and
`first_ancestors(project/x) ~ ::0000…` returns the branch's complete history. The
existing `resolve_reference_commit` → `resolve_task_fork_point` path in `changelog`
therefore already produces a full-history summary. Locked in by a test.

## 9. Test strategy

`scripts/cli/task/publish.test.sh` only.

**Existing cases** gain `-m "<msg>"` so none blocks on an editor.

**Editor stub** — a local helper writing an executable stub for `TT_EDITOR`, whose
body operates on the file path in `$1`:

```bash
# Usage: _write_editor_stub PATH BODY
# Writes an executable editor stub; BODY edits the file named by "$1".
_write_editor_stub() {
  local script_path="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf '%s\n' "$body"
  } > "$script_path"
  chmod +x "$script_path"
}
```

Bodies used: overwrite (`printf 'Ship it\n' > "$1"`), prepend-a-line (keeps the
pre-populated changelog so the round trip can be asserted), and blank the file.

**TTY guard** — `prompt_raw` hard-redirects to `/dev/tty`, so editor cases start
with:

```bash
  if ! (: < /dev/tty) 2>/dev/null; then
    skip_test "editor path" "no controlling terminal"
    return 0
  fi
```

`skip_test` is the existing harness helper (`skip_test LABEL REASON`).

**Cases**

| Case | Asserts |
| --- | --- |
| `-m` message | publish commit first line is `[tt:…:publish] <msg>`; handoff commit still carries the project title |
| editor message | stub message lands in the publish commit |
| empty editor buffer | non-zero exit, target bookmark unmoved, no new commits |
| `-m ''` | non-zero exit |
| `--changelog` with checked-in subtasks | commit body contains `Change summary:` and the changelog lines, nesting indentation preserved |
| `--changelog`, nothing to report | body contains `No code changes` |
| `--changelog`, never published | body lists the project's full history |
| `--changelog-depth 1` | deeper levels absent from the body |
| `--changelog-depth` without `--changelog` | usage error, non-zero exit |
| editor deletes the whole buffer incl. changelog | non-zero exit |

Regression: run the `task/checkpoint` and `task/checkin` suites, since `prompt()`
changed.

## 10. Documentation

`DESIGN.md`:

- Command reference entry for `tt task publish` (~line 334) — new options; message
  now comes from the user; handoff keeps the project title.
- Commit-message table (~line 414) — `[tt:task:<project-id>:publish] <message>`
  (the handoff row at ~line 412 keeps `<title>`).
- §6.5 → "`tt task publish` (project branches)" (~lines 673-683) — the prompt, the
  change summary section, and the empty-message abort.
- §7 walkthrough step 7 (~line 1097) — mention the message prompt.
