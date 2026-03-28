---
title: "Automated test suite"
status: IN-PROGRESS
created: 2026-03-28T09:13:00Z
updated: 2026-03-28T09:13:01Z
---
The bootstrap implementation is currently largely untested. Various ad-hoc test suites have been created for one-off commands (see @scripts/test/) and to investigate individual bugs (see @.agents/plans/scripts/) but there is no unified approach to automated testing.

Let's extract a reusable test harness that allows us to quickly, easily and consistently define a suite of test scenarios to accompany each command.

The test harness should allow building scenarios based on the following commands:

- creating a temporary repository via `tt workspace init`
- running standard workflow commands (`tt task create`, `tt task checkpoint` etc)
- adding manual `jj commit` entries
- making manual edits to working copy files
- running manual `jj` commands

Where possible, `tt` commands should be prioritized over raw `jj` commands.

output assertion helpers should make it simple to validate the following:

- resulting `jj` branch topography and WC revision
- commit introspection: commit message, modified files, conflict status
- resulting working copy contents
- stderr/stdout contents

Analyze the existing command implementations and determine whether this would be sufficient to fully specify the behavior of the existing commands, including edge cases.

Update @DESIGN.md with a section on testing approach.
