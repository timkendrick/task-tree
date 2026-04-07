---
title: "Standardize VCS operations"
status: TODO
created: 2026-04-07T09:11:15Z
updated: 2026-04-07T09:11:16Z
---
Currently, underlying VCS operations are heavily interspersed with app business logic.

It would be preferable to abstract all VCS operations into helper module functions, to separate storage service from control flow, also potentially paving the way for alternative storage backends (e.g. Git).

This will be a large refactor that touches most of the codebase, so let's assess opportunities for clean encapsulation, modularization and DRY refactoring.
