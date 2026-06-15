---
title: "Read `tt task checkin` handoff context via stdin / interactive editor"
status: TODO
created: 2026-06-15T11:00:21Z
updated: 2026-06-15T11:00:22Z
---
Currently, handoff context is provided to `tt task checkin` via a `--context "…"` argument.

Similarly to `scripts/cli/task/create`, let's allow task context be provided via stdin if the user provides the `--context -` argument; otherwise if no `--context` arg is provided and input is a tty open an editor for context input (no default content).

If no (empty) input is provided, don't add the task context

Update DESIGN.md / unit tests accordingly
