---
title: "Fix `context:` frontmatter updates"
status: TODO
created: 2026-04-14T21:10:52Z
updated: 2026-04-14T21:10:53Z
---
When running `tt task context delete <context-id>`, the context file is removed from the task file frontmatter, but any additional `context: <other-context-id>` entries have their `context: ` prefix stripped, leaving an invalid frontmatter field.

Reproduce the scenario in a failing unit test, then fix the bug.
