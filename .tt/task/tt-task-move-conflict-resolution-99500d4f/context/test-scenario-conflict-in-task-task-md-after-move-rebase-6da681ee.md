---
title: "Test scenario: conflict in task TASK.md after move rebase"
created: 2026-03-22T21:49:46Z
updated: 2026-03-22T21:49:46Z
---
## Root cause

The conflict arises because jj performs a 3-way merge during `jj rebase`. When
`task/task-a` is rebased from `project/project-a` onto `project/project-b`:

- **Base (common ancestor):** the old parent `project/project-a` tip — this
  commit *does* contain task-a's TASK.md (the stub version: `status: TODO`,
  no subtasks).
- **Ours (rebased revision):** the task-a branch commit — the TASK.md has been
  updated to `status: IN-PROGRESS` with a `subtask:` entry.
- **Theirs (new destination):** `project/project-b` — this commit does *not*
  contain task-a's TASK.md at all (the file doesn't exist on project-b).

jj detects that both sides modified/deleted the file relative to the base and
records a conflict. The conflict appears in the task's TASK.md using jj's
conflict format.

## Reproducing the scenario

```bash
TDIR=$(mktemp -d) && cd "$TDIR"
git init -q . && git commit --allow-empty -m "init"
jj git init --colocate

mkdir -p .tt
cat > .tt/config.toml << 'TOML'
task_prefix = "task/"
project_prefix = "project/"
TOML

# ── Commit on project/project-a ──────────────────────────────────────────────
# Registers task-a as a subtask; includes a stub TASK.md for task-a
# (status: TODO, no subtasks).
jj new "@"
mkdir -p .tt/task/project-a-aaaabbbb .tt/task/task-a-11111111
cat > .tt/task/project-a-aaaabbbb/TASK.md << 'TASK'
---
title: "Project A"
status: IN-PROGRESS
created: 2026-01-01T00:00:00Z
updated: 2026-01-01T00:00:00Z
subtask: [ ] task/task-a-11111111
---
TASK
cat > .tt/task/task-a-11111111/TASK.md << 'TASK'
---
title: "Task A"
status: TODO
created: 2026-01-01T00:00:00Z
updated: 2026-01-01T00:00:00Z
---
TASK
jj describe -m "Create task: Task A (task/task-a-11111111)"
jj bookmark set project/project-a-aaaabbbb
jj new "@"

# ── Commit on task/task-a ─────────────────────────────────────────────────────
# Begin task-a: updates TASK.md to status: IN-PROGRESS, adds task-c as subtask.
# This is the commit that will be rebased — it diverges from the project-a
# version of the TASK.md.
mkdir -p .tt/task/task-c-33333333
cat > .tt/task/task-a-11111111/TASK.md << 'TASK'
---
title: "Task A"
status: IN-PROGRESS
created: 2026-01-01T00:00:00Z
updated: 2026-01-01T00:00:00Z
subtask: [ ] task/task-c-33333333
---
TASK
cat > .tt/task/task-c-33333333/TASK.md << 'TASK'
---
title: "Task C"
status: TODO
created: 2026-01-01T00:00:00Z
updated: 2026-01-01T00:00:00Z
---
TASK
jj describe -m "Begin task: Task A (task/task-a-11111111) + Create task: Task C"
jj bookmark set task/task-a-11111111
jj new "@" ; jj bookmark set task/task-c-33333333 ; jj new "@"

# ── project/project-b: independent root ──────────────────────────────────────
# project-b does NOT contain task-a's TASK.md at all.
jj new "root()"
mkdir -p .tt/task/project-b-ccccdddd
cat > .tt/task/project-b-ccccdddd/TASK.md << 'TASK'
---
title: "Project B"
status: IN-PROGRESS
created: 2026-01-01T00:00:00Z
updated: 2026-01-01T00:00:00Z
---
TASK
jj describe -m "Create project: Project B"
jj bookmark set project/project-b-ccccdddd
jj new "@"

# ── Trigger the conflict ──────────────────────────────────────────────────────
tt task move --task task/task-a-11111111 --parent project/project-b-ccccdddd
```

## What jj outputs during the move

```
Rebasing task/task-a-11111111 onto project/project-b-ccccdddd...
Rebased 2 commits to destination
New conflicts appeared in 1 commits:
  ooskqntq ea232bc3 task/task-a-11111111 | (conflict) Begin task: Task A ...
Hint: To resolve the conflicts, start by creating a commit on top of
the conflicted commit:
  jj new ooskqntq
Then use `jj resolve`, or edit the conflict markers in the file directly.
Once the conflicts are resolved, you can inspect the result with `jj diff`.
Then run `jj squash` to move the resolution into the conflicted commit.
```

## Conflict format in the TASK.md after the move

`jj file show -r "task/task-a-11111111" -- .tt/task/task-a-11111111/TASK.md`
outputs:

```
<<<<<<< conflict 1 of 1
%%%%%%% diff from: <project-a tip> (parents of rebased revision)
\\\\\\\        to: <project-b tip> (rebase destination)
----
-title: "Task A"
-status: TODO
...deleted stub TASK.md...
+++++++ <task-a commit> (rebased revision)
---
title: "Task A"
status: IN-PROGRESS
...
subtask: [ ] task/task-c-33333333
---
>>>>>>> conflict 1 of 1 ends
```

The conflict format is a jj "diff conflict": the `%%%%%%%` section shows what
changed between the old base and the new destination (the file was deleted on
project-b), and the `+++++++` section shows the rebased revision's content.

**The correct resolution is always the `+++++++` side** — the task's own
TASK.md as it existed on the task branch before the rebase. The new parent
(project-b) never owned this file; it should not influence the task's TASK.md.

## Detecting and resolving the conflict

After `jj rebase`, check for conflicts with `has_conflicts` (already in
`common.sh`):

```bash
# has_conflicts REPO REVSET — returns 0 if any commit in REVSET has conflicts
if has_conflicts "$repo" "${task_id}::"; then
    ...resolve...
fi
```

The resolution strategy: use `jj restore` to bring back the correct version
of the TASK.md. The pre-rebase version of the task's TASK.md can be obtained
from the task bookmark's change ID (which jj preserves across rebases):

```bash
# Create a WC on top of the conflicted task bookmark
jj -R "$repo" new "$task_id"

# Restore task's TASK.md from the task's own (pre-rebase) commit.
# Since jj preserves change IDs across rebases, $task_id still resolves
# to the correct (rebased) commit, but we want the content from the
# pre-rebase version. We can get it via:
#   jj file show -r "$task_id" -- "$task_file"
# and write it back:
jj -R "$repo" file show -r "$task_id" -- "$task_file" > "$repo/$task_file"

# Commit the resolution
jj -R "$repo" describe -m "Resolve conflicts: $task_title ($task_id)"
jj -R "$repo" bookmark set "$task_id"
jj -R "$repo" new "@"
```

Note: child tasks (e.g. task-c) that are descendants of the conflicted commit
will also show as conflicted (`has_conflicts "$repo" "${task_id}::"` catches
them all). However, their TASK.md files are their own and should not have
conflicts introduced by the move — the conflict propagates from the parent
commit in jj's model. Re-running `has_conflicts` after resolving task-a's
conflict should confirm whether children need separate resolution or whether
jj automatically resolves them once the parent is fixed.

## Affected commits

Both the moved task's bookmark commit AND its descendant (task-c) show as
conflicted after the move:

```
zpxpkuvkuvsy CONFLICTED   ← task/task-c-33333333 (inherits parent conflict)
ooskqntqvlml CONFLICTED   ← task/task-a-11111111 (direct conflict)
```

This means the resolution must resolve the conflict in the task-a commit
(the root of the conflicted range), and jj should automatically propagate
the clean state to descendants.
