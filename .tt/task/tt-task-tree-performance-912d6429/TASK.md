---
title: "Fix `tt task tree` performance"
status: IN-PROGRESS
created: 2026-08-06T14:25:01Z
updated: 2026-08-06T14:25:15Z
context: context/analysis-88313951
---
Currently, `tt task tree --focus` returns results much more quickly than `tt task tree`.

Determine why this is the case and address the performance disparity.
