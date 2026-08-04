---
title: "Configurable `tt task select` UI"
status: TODO
created: 2026-08-04T06:57:13Z
updated: 2026-08-04T06:57:14Z
---
Currently, `tt task select` implements an opinionated list picker UI that allows the user to choose an option. This functionality is ancillary to the primary tool and should be removed from the codebase as it creates unnecessary complexity. 

Instead, let's provide a bare bones default picker UI, and allow overriding it via a user-provided environment variable (see below for UI requirements).

Make sure to update DESIGN.md and any tests, and remove the prior `select.sh` implementation and accompanying tests entirely.

---

## Basic picker UI

If no custom environment variable is provided, a common helper function will be used that reads a list of newline separated options from standard input, renders the minimal picker UI to stderr, prompts the user to enter a value, and writes the selected option to stdout using basic posix tools. If the user enters an invalid value, the function will return a nonzero exit status.

Example stdin:

```
task/foo
task/bar
task/baz
```

Example stderr:

```
Select an option:

task/foo
task/bar
task/baz
```

Example stdout:

```
task/bar
```

---

## Custom picker UI

If the `TT_SELECT` environment variable is provided, that command will be used to render the picker UI. The custom command should expose the same interface as the basic picker UI function: accept a list of newline-separated options provided via standard input, and write a single line to standard output containing one of the selected options. If the stdout value does not exactly match one of the provided input values, this should be treated as an error.

---
