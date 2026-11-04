---
title: "Fix quoted `\\n` in frontmatter field parsing"
status: TODO
created: 2026-11-04T17:30:05Z
updated: 2026-11-04T17:30:05Z
---
`_frontmatter__parse_values` (`scripts/cli/lib/frontmatter.sh`) decodes the escapes in a quoted value. A quoted `\n` becomes a real newline in its output.

The function's output contract is one line per single-valued field, so the extra line shifts every later field. For example, a task file with:

```
title: "Line one\nline two"
status: TODO
```

read with `_frontmatter__parse_values "$content" title status` prints three lines. A caller that reads `title` then `status` gets `status` = `line two`.

Every command that reads task fields goes through this function, including the task index used by `tt task list` and `tt task tree`.

Decide how decoded values that contain newlines should be represented in the output (for example, keep them escaped in the line protocol and decode only at the point of display), fix the parser and its callers, and add regression tests.
