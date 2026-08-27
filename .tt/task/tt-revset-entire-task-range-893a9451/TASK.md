---
title: "Allow entire task range in `tt revset` / `tt diff` / `tt changelog` commands"
status: IN-PROGRESS
created: 2026-08-27T10:16:06Z
updated: 2026-08-27T10:21:32Z
context: context/refined-requirements-2e6916bf
---
scripts/cli/task/revset
scripts/cli/task/diff
scripts/cli/task/changelog

Currently, `tt revset` (and related `tt diff` / `tt changelog` commands) only shows the _unmerged_ range for a given task.

These commands should all accept an additional `--all` argument, which will additionally include all _merged_ ranges (expressed as a union of the discontiguous commits).

The task's range should be considered to include commits made directly to the branch itself, as well as tt actions performed on the task itself (edit / context:{add,remove,edit} / checkpoint / reorder / rename, etc) as well as creations / checkins / deletions of direct child tasks.

Update DESIGN.md and test suite, including a section in DESIGN.md explaining how to the relevant ranges for the given task are defined (including how to determine the 'canonical' VCS branches for a given task).
