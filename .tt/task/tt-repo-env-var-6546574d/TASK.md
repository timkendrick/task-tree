---
title: "Support `TT_REPO` environment variable"
status: TODO
created: 2026-03-29T08:01:10Z
updated: 2026-03-29T08:01:10Z
---
Many commands currently support a `--repo` flag that can be used to specify the `tt` workspace to use.

1. Make sure that all commands support this flag
2. Additionally allow the value to be provided via an optional `TT_REPO` flag (`--repo` argument takes priority)
3. Add a note explaining this behaior in @DESIGN.md
