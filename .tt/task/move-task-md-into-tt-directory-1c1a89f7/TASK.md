---
title: "Move `TASK.md` into `.tt` directory"
status: TODO
created: 2026-09-24T15:05:40Z
updated: 2026-09-24T15:05:40Z
---
Currently, the directory layout specifies a top-level `TASK.md` symlink, which could collide with within any `TASK.md` file within the project.

Let's move this to `.tt/TASK.md` such that it doesn't pollute the project root directory.

Given that this refactors a fundamental assumption of the current bootstrapped repository, consider whether we need to additionally rewrite the current repository history to 'backfill' this change to all historical branches as described in docs/file-format-migrations.md
