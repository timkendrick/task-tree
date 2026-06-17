---
title: "Creating a task under a different parent leaves HEAD on wrong branch"
status: TODO
created: 2026-06-17T17:17:45Z
updated: 2026-06-17T17:17:46Z
---
Currently, when creating a task via `tt task create --parent <task-id>` (e.g. `tt task create --parent $(tt task parent)`), the current jj position is incorrectly left on the newly-created task branch, rather than the change where the current jj position was before invoking the task creation command.
