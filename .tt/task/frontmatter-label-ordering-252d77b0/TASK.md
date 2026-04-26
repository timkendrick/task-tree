---
title: "Insert frontmatter labels in correct position"
status: DONE
created: 2026-04-24T07:36:46Z
updated: 2026-04-26T15:22:09Z
context: context/implementation-plan-c6c98cce
context: context/rollback-operation-id-bae68e35
---
Currently, when adding context to a task, the `context:` frontmatter entry is added after all existing frontmatter entries, regardless of what other frontmatter labels currently exist in the task.

The correct order should be:

```markdown
---
title:
status:
created:
updated:
label:
…
context:
…
subtask:
…
---
```


all scripts that update frontmatter (e.g. scripts/cli/task/edit) should ensure that this order is maintained by extracting common order-aware helpers.

Add unit tests for all frontmatter-updating scenarios to verify correct order.

update DESIGN.md accordingly.
