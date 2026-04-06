---
title: "Standardize `--help` flag across commands"
status: IN-PROGRESS
created: 2026-04-06T12:13:12Z
updated: 2026-04-06T20:47:21Z
context: context/implementation-plan-43571f2b
---
All CLI commands (should) support a `--help` flag to show usage instructions for the command.

If the `--help` flag is provided, all other flags should be ignored, the usage instructions should be printed to stdout, and the command should exit with code 0.

If the `--help` flag is not provided and validation fails for the command arguments, the usage instructions should be printed to stderr, and the command should exit with code 1.

Update all existing commands to have this behavior and document it in DESIGN.md

Implementation-wise, by convention, each command entrypoint script should declare a `usage` function that logs to stdout by default and does not `exit` - it is up to the call site to redirect to stderr if necessary and to exit with the correct code.
