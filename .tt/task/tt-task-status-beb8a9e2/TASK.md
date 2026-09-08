---
title: "Implement `tt task status` CLI command"
status: TODO
created: 2026-09-08T09:18:09Z
updated: 2026-09-08T09:18:09Z
---
Let's implement a `tt task status [--task <task-id>]` command (alias `tt status`) that prints the status of the given task (i.e. `TODO` / `IN-PROGRESS` / `DONE`), defaulting to the current task.

Note that this ultimately be an alias to a more general-purpose command that retrieves (and potentially updates?) arbitrary task frontmatter labels; let's explore this when planning and design with this in mind.

Update DESIGN.md
