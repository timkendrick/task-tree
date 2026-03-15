---
title: "Extract context into standalone files"
status: IN-PROGRESS
created: 2026-03-15T09:29:32Z
updated: 2026-03-15T09:29:32Z
---
Currently, the task file format specifies the title and various other metadata fields including the JSON-encoded `description` in the task file frontmatter.

The remaining markdown body of the task file is used for arbitrary context chunks, appended via the `add-context` command.

I would like to 'shift this down', such that the task description is moved out of the JSON-encoded frontmatter field and into the plaintext markdown body of the task file, and the context chunks are saved as standalone 'context files'. These are freeform markdown files with arbitrarily-structured content and no restrictions on frontmatter (or absence thereof).

Each context chunk will be assigned an ID of the form `context/<context-slug>-<context-hash>`, similarly to task ID generation.

A task's context files will be referenced in the owner task's frontmatter via `context: <context-id>` tags (similar to how subtasks are referenced via `subtask: <task-id>` tags).

To group a task together with its context files, each task file will be moved to its own directory with a `TASK.md` and an arbitrary number of `context/<context-slug>-<context-hash>.md` files (one per `add-context` invocation).

so an existing `.tt/task/foo.md` will now be `.tt/task/foo/TASK.md`, `.tt/task/foo/context/initial-research-ab3243f0.md`, etc

This is a far-reaching change that will affect not only the @DESIGN.md and CLI script implementations, but also the current repository, which will need to be migrated en-masse to the new format for the self-hosted tool to continue working once the change is merged.

Given the self-hosting nature of the repository, any QA testing should be performed on artificially constructed files, rather than 

A critical acceptance criterion is therefore a script that can be run on the repository to migrate all branches from the existing task file format to the new task file format - i.e. all task files are extracted into their own directories with `TASK.md` files; `description` frontmatter fields shold be promoted to markdown body, any context chunks are extracted to standalone files. This is a delicate procedure so great care should be taken to produce a bulletproof migration script. Rather than rewriting history making potentially destructive changes to the current repository, it might be worth considering producing an clones of all repository branches in a new worktree and verifying parity, only 'switching over' the bookmarks to the new commits and abandoning the old commits once it has been proven to be a faithful reproduction in the new format.
