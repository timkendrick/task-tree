---
title: "Strip `.tt` metadata file contents from `tt task diff` output"
status: IN-PROGRESS
created: 2026-08-05T16:03:08Z
updated: 2026-08-05T16:03:09Z
---
Currently, the `tt task diff` command output includes all file contents modifications in the current branch, including changes to the task metadata files within the `.tt` metadata folder.

By default, we should omit the diff output for any files within the `.tt` metadata folder (use existing common DRY helpers to determine this path).

If the user provides an optional `--include-metadata` flag, the `.tt` output is not stripped (current behavior).

Update DESIGN.md accordingly.
