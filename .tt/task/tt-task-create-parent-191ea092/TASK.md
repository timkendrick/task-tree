---
title: "Show parent task when creating task"
status: DONE
created: 2026-04-03T08:19:37Z
updated: 2026-04-03T08:20:16Z
---
When creating a task via `tt task create`, it is useful to be informed of which parent task the task will be created under.

Before any user prompts, log a message to stderr to indicate which parent task the task is being created under.
