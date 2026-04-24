---
title: "Custom merge conflict driver for task frontmatter"
status: TODO
created: 2026-04-24T07:29:19Z
updated: 2026-04-24T07:29:20Z
---
Subtask metadata operations such as updating subtask status and reordering the task list have a high chance of introducing merge conflicts in checked-out child/sibling task branches.

To improve the chance of successful merges, it might make sense to develop a custom merge driver for all task file merges that semantically understands task file frontmatter.

the following frontmatter changes should be supported:

- status updates (most advanced wins)
- timestamp modifications (most recent wins)
- context reordering (most recent created timestamp in corresponding context file wins*)
- subtask status updates (most advanced wins)
- subtask reordering (most recent created timestamp in corresponding task file wins*)

> *Confirm whether merge driver is able to read external files from the respective branches, otherwise this information might need to be provided to the merge driver via other means

This merge driver should be invoked for all merge operations that produce conflicts; it should be restricted to rectifying frontmatter conflicts and leave conflict markers for any other conflicts (which should not happen in practice, as task file body is only ever modified on the parent branch)

References:

- context7 jj docs
- https://docs.jj-vcs.dev/latest/config/#setting-up-a-custom-merge-tool
- https://docs.jj-vcs.dev/latest/config/#editing-conflict-markers-with-a-tool-or-a-text-editor
