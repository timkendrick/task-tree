---
title: "Fix task file frontmatter parsing"
status: TODO
created: 2026-08-06T15:02:27Z
updated: 2026-08-06T15:02:27Z
---
Due to inconsistent frontmatter parsing, `tt task tree` incorrectly shows a `[?]` status checkbox for any tasks whose task file body contains a `---` line

While we're at it, let's standardize frontmatter parsing across all commands to avoid issues like this cropping up again
