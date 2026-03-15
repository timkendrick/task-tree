---
title: "Show subtask titles in `tt task show`"
status: DONE
created: 2026-03-15T09:29:31Z
updated: 2026-03-15T09:29:31Z
---
Currently the tt task show command lists subtasks and their task IDs, however it doesn't show the task's title.

Let's update this to use the common helper functions to read the title of that subtask from the subtask's canonical title file. 
