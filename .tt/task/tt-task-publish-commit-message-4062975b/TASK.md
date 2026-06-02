---
title: "Prompt for `tt task publish` commit message"
status: TODO
created: 2026-06-02T17:02:33Z
updated: 2026-06-02T17:02:34Z
---
Currently, `tt task publish` uses the name of the task for its editable commit message.

The command should instead present the user with a blank editor for them to describe the published changes.

An empty message should be treated as an error, causing the command to exit with a non-zero exit code.
