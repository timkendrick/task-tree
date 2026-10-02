---
title: "Track subtasks and context via filesystem"
status: TODO
created: 2026-10-02T09:56:10Z
updated: 2026-10-02T09:56:10Z
---
Currently, subtasks and context entries are linked to a task via TASK.md file `subtask:` and `context:` frontmatter entries respectively.

This is more complicated to parse and maintain versus reading filesystem listings directly, and allows recorded subtask status to fall out of sync with the file system contents.

Let's consider an alternative design that uses the file system to encode these links implicitly by creating symlinks within a `subtasks` directory within the task directory to indicate subtask relations, and inferring `context` entries from the filesystem rather than the TASK.md frontmatter:

```
.tt/
  tasks/
    parent-task-1234abcd/
      TASK.md  <- Contains metadata and description, no links
      subtasks/
        child-task-4321dcba > ../../child-task-4321dcba
      context/
        task-context-abcd1234.md
        … 
    child-task-4321dcba/
      TASK.md
```

Pro: reduces conflict noise in TASK.md, removes redundancy between two sources of truth
Con: implicit 'inferred' entity relations reduce auditable metadata in TASK.md when working with subtasks/context entries

Open questions:

- does manipulating subtask / context entries constitute an 'update' to the TASK.md? What about checking in a completed subtask vs a non-completed subtask? Is it worth some introspection here for a more coherent overall design?
- given this implies subtasks become an unordered set, how should subtask order be determined in UI?
