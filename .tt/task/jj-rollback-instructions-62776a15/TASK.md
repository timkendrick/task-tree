---
title: "Show `jj` rollback instructions before each `tt` operation"
status: TODO
created: 2026-03-23T11:18:58Z
updated: 2026-03-23T11:18:58Z
---
In the `tt` command entrpoint, always log the current `jj` operation and rollback instructions to stderr

jj operation ID is retrieved via `jj op log --no-graph -T id -n 1`

Output message has this format:

```
jj operation ID before command: <operation-id>
rollback: `jj op restore <operation-id>`
```
