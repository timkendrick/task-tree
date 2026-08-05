---
title: "Use git diff output format for `tt task diff`"
status: DONE
created: 2026-08-05T16:27:08Z
updated: 2026-08-05T16:27:09Z
---
Currently, `tt task diff` proxies the `jj diff` output directly to the terminal, which by default renders the diff in a pager with ANSI colors etc.

The `tt task diff` command is intended to be used programatically, so let's change this to pass the `--git` flag to `jj diff` to print more standard structured output.
