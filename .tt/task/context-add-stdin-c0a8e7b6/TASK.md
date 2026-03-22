---
title: "Support stdin for `tt task context add` body"
status: TODO
created: 2026-03-22T15:49:07Z
updated: 2026-03-22T15:49:08Z
---
Replace the `--body <text>` argument on `tt task context add` with stdin support. When stdin is a pipe or redirect (i.e. not a TTY: `[[ ! -t 0 ]]`), read the body from stdin. When stdin is a terminal, preserve the existing behaviour of opening an editor.

## Motivation

The `--body` argument is subject to the kernel's `ARG_MAX` limit (1 MiB on macOS, shared with all arguments and env vars), making it unreliable for large context bodies such as multi-hundred-KiB markdown plans. Stdin has no such limit.

## Changes

### `scripts/cli/task/context/add`

- Remove the `--body <text>` argument and the `has_body` / `body` argument-parsing logic.
- After resolving title/slug, detect whether stdin is a terminal:
  - If `[[ ! -t 0 ]]`: read body from stdin (`body="$(cat)"`).
  - If `[[ -t 0 ]]`: open the editor as before (`prompt_raw`).
- Keep the existing empty-body guard.

### `DESIGN.md`

- Update the `tt task context add` command signature in §6 (commands reference) and §9 (workflow) to remove `--body <text>` and document the stdin behaviour.
- Update any usage examples that reference `--body`.

## Usage

```bash
# Pipe a file directly — no ARG_MAX risk
cat ./plan.md | tt task context add --title "Implementation plan"

# Redirect from file
tt task context add --title "Implementation plan" < ./plan.md

# Interactive (no redirect) — opens editor as before
tt task context add --title "Implementation plan"
```
