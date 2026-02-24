---
title: "Fix `--focus` flag behavior for `tt task list`"
status: IN-PROGRESS
description: "When run within a child branch, `tt task list --focus` has been observed incorrectly showing siblings of the parent task. \n\nThis behavior is incorrect: only direct ancestors of the current task should be shown."
---
