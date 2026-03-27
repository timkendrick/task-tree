---
title: "Fix `tt task show` for completed tasks"
status: IN-PROGRESS
created: 2026-03-27T15:11:26Z
updated: 2026-03-27T15:11:26Z
---
Currently, when `tt task show` is called with a completed and checked-in task ID, it incorrectly shows details of the parent task rather than the child task.

Figure out why this is happening, verify with a test script on a dummy repo, and apply the fix.
