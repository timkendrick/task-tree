---
title: "Fix `tt task checkin` for project branches"
status: DONE
created: 2026-03-15T09:29:31Z
updated: 2026-03-23T10:58:49Z
---
Verify issue via repro script:

Create scenario test script that initializes a temporary `tt` project (with bootstrapped config files).

Once the project has been created, create dummy tasks using `tt` commands.

Verify problem exists within dummy project.

Implement a fix in main project

Add a `tt checkpoint`

Verify problem is solved within dummy project

Delete test script
