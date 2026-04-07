---
title: "Standardize task file metadata manipulations"
status: TODO
created: 2026-04-07T09:12:58Z
updated: 2026-04-07T09:12:59Z
---
Various different techniques are current used to manipulate task files and frontmatter (`sed`, `awk`, etc).

We should standardize these by extracting a module of common helper functions that can be reused across all scripts.

Assess opportunities for DRY refactoring.
