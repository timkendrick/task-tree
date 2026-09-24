---
title: "Omit summary line from `tt prompt` output"
status: IN-PROGRESS
created: 2026-09-24T16:39:44Z
updated: 2026-09-24T16:39:44Z
---
Currently, `tt task prompt` emits the current task title, prefixed by 'Implement task: ' as the first line:

```
$ tt prompt | head -7
Implement task: Bootstrap CLI
---
task: project/bootstrap-cli-d35756ce
title: Bootstrap CLI
---

Implement shell script implementations of all `tt` CLI commands
```

This is redundant and potentially misleading.

Remove the line, so that the first line of the output is the `---` frontmatter opening tag.

Update DESIGN.md accordingly

Additionally, always print the final `---` separator delimiter regardless of whether a `--message` was specified.
