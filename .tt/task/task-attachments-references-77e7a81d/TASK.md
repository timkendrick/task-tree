---
title: "Allow task file references and attachments"
status: TODO
created: 2026-10-02T10:24:01Z
updated: 2026-10-02T10:24:01Z
---
Currently, context can be attached to task files.

The only type of context entry currently supported is markdown text.

Let's additionally support two additional types of task context:

- file references - links to existing files within the repository
- attachments - arbitrary file contents

Both of these should be stored within the task's directory, potentially in `refs` and `attachments` sub directories respectively.

File references should be stored as symbolic links to the target file within the repository.

Attachments should be stored as standalone files (attachment filenames must be unique within a given task).

Unlike context files, these probably won't need any additional 'wrapper' metadata. Each task holds a combined set of file references and a combined set of attachments, rather than a sequence of timestamped/titled entries.

We will need to extend the CLI surface area to include something like the following (TBD)

```
tt task paths <add|delete> <path> [...paths]
tt task attachments <add|edit> <filename> < /path/to/file/content
tt task attachments delete <filename>
```

in this example file referencepaths are assumed to be relative to the repository root; file contents are provided via stdin
