---
title: "Standardize command output across all commands"
status: TODO
created: 2026-04-07T09:22:36Z
updated: 2026-04-07T09:22:38Z
---
Currently, standard output is implemented ad-hoc for each individual command.

The `tt` commands currently log a fairly verbose mixture of logging output to stdio and stdout.

This could benefit from being more structured – for instance, such that when creating a new task, we should be able to capture the task ID on standard output.

We might want to consider a convention of supporting a `--quiet` flag for commands that produce machine-readable output.

Additionally, output from external commands (e.g. `jj`) should always be logged to stderr.

This will need a comprehensive evaluation of all logging across all commands, and some thought to ensure consistent logging conventions across all commands.
