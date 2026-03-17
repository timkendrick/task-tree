---
title: "Add `--message` argument to `tt task prompt` command"
status: TODO
created: 2026-03-17T08:29:14Z
updated: 2026-03-17T08:29:14Z
---
Currently, `tt task prompt` can be used to create an implementation prompt for a given task.

Add an optional `--message "..."` argument that, if specified, appends the follwing section to the task prompt:


```
---

<message>
```

...where `<message>` is the verbatim text provided via the CLI argument 
