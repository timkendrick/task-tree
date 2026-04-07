---
title: "Filter out test files in subcommand listing"
status: DONE
created: 2026-04-03T21:51:25Z
updated: 2026-04-03T21:51:25Z
---
Currently, when listing subcommand help via `tt <command>`, all files within that command's directory are listed as subcommands.

This incorrectly includes test files which are colocated with the subcommand files.

We need to filter the list such that only executable files with no file extension are shown, so that e.g. `.test.sh` files are not shown in the output
