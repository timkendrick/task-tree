---
title: "Populate `tt task checkpoint` commit message for single-commit checkpoints"
status: IN-PROGRESS
created: 2026-06-02T16:57:51Z
updated: 2026-06-02T16:57:52Z
---
When running `tt task checkpoint`, the editable commit message defaults to the name of the task.

This makes sense for multi-commit checkpoints, however when the commit range since the task bookmark contains only a single commit, the editor should be prepopulated with that commit's message.

This applies regardless of the `--squash` flag.
