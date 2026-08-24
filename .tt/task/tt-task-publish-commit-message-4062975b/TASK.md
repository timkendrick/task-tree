---
title: "Prompt for `tt task publish` commit message"
status: DONE
created: 2026-06-02T17:02:33Z
updated: 2026-08-24T17:16:36Z
context: context/requirements-7e01e6e3
context: context/architecture-570331ab
context: context/summary-8a1335e2
---
See scripts/cli/task/changelog

Currently, `tt task publish <project-id> --target <target>` uses the name of the `<project-id>` task for the 'free text' portion of its commit message.

The command should instead present the user with an editor for them to describe the published changes (similar to scripts/cli/task/checkpoint).

If the user provides the optional `--changelog` flag (optionally parameterized by the `--changelog-depth <depth>` argument), the editor commit message template should have a changelog section appended that describes the changes that have been made to the project branch since since the last common ancestor of the current project branch and the target branch (provided via `tt task changelog --since <target> [--depth <changelog-depth>]`).

We need to handle the edge case of projects that have never been published to the specified target branch - in this case, intuitively the 'common ancestor' changelog reference commit should resolves to the 'nil' root commit, therefore showing the entire project history in the changelog - we need to confirm that this is indeed the standard `tt task changelog` behavior.

If the `--changelog` flag is omitted, the editor should be pre-populated with an empty commit message template.

An empty message should be treated as an error, causing the command to exit with a non-zero exit code.

The user-provided commit message does not affect the hardcoded `[tt:task:<project-id>:publish] ` commit message prefix.

Update DESIGN.md as appropriate

## Changelog message template

The pre-populated changelog section should be appended to the commit message template, and comprises the following:

- 1 'separator' newline
- "Change summary" header line with trailing newline
- 1 'separator' newline
- Verbatim `tt task changelog` output (or "No code changes" placeholder if `tt task changelog` output is empty) with trailing newline

### Examples

N.B. These examples assume standard unix convention of a trailing newline to end the file

#### Non-empty changelog

```

Change summary:

[`tt task changelog` output]
```

#### Empty changelog

```

Change summary:

No code changes
```
