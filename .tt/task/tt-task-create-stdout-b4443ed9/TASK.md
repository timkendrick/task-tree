---
title: "Allow piping `tt task create` output"
status: IN-PROGRESS
created: 2026-06-15T09:28:29Z
updated: 2026-06-15T09:28:30Z
---
Currently, `tt task create` logs various debugging information to stdout, including the output of VCS commands etc.

Let's change this so that the only output written to stdout is the generated task ID, so that it can be piped to other commands (similar to `tt task checkout` writing the worktree path to stdout).

Update DESIGN.md, .agents/skills/tt/SKILL.md and tests accordingly.
