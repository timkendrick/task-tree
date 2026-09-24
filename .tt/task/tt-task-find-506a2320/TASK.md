---
title: "Add `tt task find` CLI command"
status: IN-PROGRESS
created: 2026-09-24T14:57:48Z
updated: 2026-09-24T14:57:48Z
---
Add a new `tt task find --revision <revision-id>` CLI command, aliased to `tt find`, which locates the immediate `tt` task parent that contains the provided `<revision-id>`

If no parent is found (or for unexpected edge cases where there are multiple immediate parents, e.g. a merge commit), exit with an error message

The revision format should be whatever is accepted by the underlying VCS implementation

Update DESIGN.md and SKILL.md accordingly

## Usage examples

Enclosing task exists:

```
$ tt task find --revision abcd1234
task/foo
$ echo "$?"
0
```

No enclosing task exists / multiple enclosing tasks / any other error:

```
$ tt task find --revision abcd1234
Unable to locate task for revision abcd1234
$ echo "$?"
1
```
