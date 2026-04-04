---
title: "Ensure absolute path when updating `.tt/workspace` symlink"
status: IN-PROGRESS
created: 2026-04-03T21:25:00Z
updated: 2026-04-03T21:25:01Z
---
Commands that mutate the `.tt/workspace` symlink must ensure that they resolve the new path assigned to the symlink to prevent symlink loops (e.g. `HEAD -> ./HEAD`)

Incorrect behavior has been observed in e.g. `tt task checkin --complete --propagate`; maybe other commands are also affected
