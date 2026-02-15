# Design document: todo-tree

todo-tree (`tt`) is a CLI tool that can be used for task tracking and context management within complex software development projects

## Overview

todo-tree is intended to combine both lightweight in-repository task tracking, with straightforward and structured task context management.

The tool will use the version control system as backing store for a stack-based model of a project's current to-do state, with the entire scope of work for the project represented as a tree structure.

This allows the user to define a complex branching workflow, where tasks can be subdivided into more granular tasks and eventually merged into their parent task when complete. Each task is represented by a VCS branch, and has an initial commit that creates the task within the overall project. This initial commit can be used to track which parent branch the task branched off from.

A parent task can contain one or more child tasks, each of which represents an independent unit of work (whether that is a feature or set of features). The VCS branch topology expresses dependencies between two different tasks (a parent branch depends on all its child branches). All tasks are attached to their parent via the parent task file's `subtask: [ ]` frontmatter; the order of these entries defines the order of child tasks. All tasks have their own VCS branch and can have arbitrarily deeply nested child tasks.

The project task graph must form a **tree structure**: each task has exactly one parent branch. DAG use cases (multiple parents refrencing the same child task) are not allowed. On encountering a task with multiple parents, the tool commands notify the user and refuse to make changes. Multiple non-task root branches are still allowed, but this would represent multiple task trees (effectively multiple sub-projects within the same workspace).

A **root branch** is a merge target that cannot itself be merged any further (e.g. the branch the user was on when they created the top-level task). A workspace can contain multiple root branches, each acting as the root of a separate task tree. All development happens by splitting off task branches from a parent (root or task branch), merging them back when the unit of work is complete. Thus the parent branch gradually becomes more complete as more of its child branches are merged. When a given parent branch has no remaining child branches, the parent branch is eligible for merging into its own parent(s), or new child branches can be created to add more work on the parent branch. A task is eligible for merging when all its child tasks are complete.

Key to the branching model is the notion of task context. Each branch stores its own local task context in a 'task file', and can introspect the task hierarchy to read the parent branch's context. This can be traced arbitrarily far back to the root branch(es). This means that all child branches will have access to the whole chain of parent context, so they are aware of where they stand in the overall project plan.

There are two components to the context. One is the high-level overall to-do list, which stores the entire to-do state of the project, and the other is individual granular task files.

The project to-do list is a markdown listing of all tasks, grouped by root branch. Each root branch has a section header (e.g. `Tasks on branch \`main\`:`). Top-level tasks whose branch's VCS parent is not a root branch are listed under a **detached** section: `Tasks with no branch parent:`. Within each section, the task tree is shown as nested bullets. Each bullet contains the following, separated by spaces:

- A GFM checkbox indicating the status of the task:
  - To-do: `[ ]`
  - In progress: `[-]`
  - Done: `[x]`
- A Markdown relative link to the task file for that task, labeled by the machine-readable name of the branch for that task
- A single-line human-readable task summary

The user can filter output with **`--root <branch-name>`** (repeatable) and **`--orphan`**. With no flags, all root sections and the detached section (if any) are shown. With `--root main` (or `--root main --root next`, etc.) and/or `--orphan`, only the listed root section(s) are shown.

Example of an in-progress project to-do list:

```markdown
Tasks on branch `main`:

- [-] [task/authentication-ea434dde](.tt/task/authentication-ea434dde.md) Implement user authentication
  - [x] [task/email-signup-a4048c0f](.tt/task/email-signup-a4048c0f.md) Allow user creation with email address
  - [-] [task/add-oauth-flow-8cf8d966](.tt/task/add-oauth-flow-8cf8d966.md) Integrate OAuth2 signin flow
    - [x] [task/research-oauth-flow-c10103b7](.tt/task/research-oauth-flow-c10103b7.md) Research SSO auth flow
    - [-] [task/determine-sso-providers-3ddc3c2f](.tt/task/determine-sso-providers-3ddc3c2f.md) Determine supported SSO providers
    - [ ] [task/plan-feature-9fdbbd60](.tt/task/plan-feature-9fdbbd60.md) Plan feature
    - [ ] [task/write-e2e-tests-8961d5b1](.tt/task/write-e2e-tests-8961d5b1.md) Write end-to-end tests
    - [ ] [task/implement-feature-7702ec93](.tt/task/implement-feature-7702ec93.md) Implement feature
    - [ ] [task/review-implementation-34a0507c](.tt/task/review-implementation-34a0507c.md) Review feature implementation
    - [ ] [task/update-docs-6369ad14](.tt/task/update-docs-6369ad14.md) Update documentation
    - [ ] [task/update-context-48c3fa01](.tt/task/update-context-48c3fa01.md) Update parent task context
  - [ ] [task/forgotten-password-ef19c63e](.tt/task/forgotten-password-ef19c63e.md) Implement 'forgotten password' signin
- [ ] [task/landing-page-4613e4c8](.tt/task/landing-page-4613e4c8.md) Build landing page
- [ ] [task/pricing-page-cdf2d632](.tt/task/pricing-page-cdf2d632.md) Build pricing page

Tasks on branch `next`:

...

Tasks with no branch parent:

- [ ] [task/product-research-5fb4e979](.tt/task/product-research-5fb4e979) Initial product research
```

The second component to project context is individual task files. Each file pertains to one specific task and it gives the context for that task. Metadata is stored in Markdown frontmatter, including the one-line task summary, the task status, a full task description encoded as a JSON string, a list of labels used to categorize the task, and a list of child tasks via `subtask:` entries. The order of `subtask:` entries in frontmatter defines the display order of child tasks in the todo list.

Example of a task file for a task which has not yet been started (`.tt/task/pricing-page-cdf2d632.md`):

```markdown
---
title: Build pricing page
status: TODO
description: "Create a basic web page that explains the different pricing tiers.\n\nWe'll need a pricing grid that shows the various tiers, making sure to include options for monthly/yearly plans."
label: design
label: front-end
label: back-end
---
```

Example of a task file for an in-progress task (`.tt/task/add-oauth-flow-8cf8d966.md`):

```markdown
---
title: Integrate OAuth2 signin flow
status: IN-PROGRESS
description: "Users should be able to sign into the application from a variety of providers via a Single-Sign-On (SSO) process.\n\n\The list of providers should be extensible and configurable via environment variables.\n\nSupported providers are TBD."
label: back-end
label: auth
subtask: [x] task/research-oauth-flow-c10103b7 Research SSO auth flow
subtask: [-] task/determine-sso-providers-3ddc3c2f
subtask: [ ] task/plan-feature-9fdbbd60
subtask: [ ] task/write-e2e-tests-8961d5b1
subtask: [ ] task/implement-feature-7702ec93
subtask: [ ] task/review-implementation-34a0507c
subtask: [ ] task/update-docs-6369ad14
subtask: [ ] task/update-context-48c3fa01
---
- OAuth2 spec: https://oauth.net/2/
- Relevant project source files:
  - `docs/auth`
  - `src/views/login`
```

While working on the task, context can be added to this task file in markdown format. This context can be used as a 'scratch pad' to record anything that could be useful during implementation of the task. Importantly however, only the current task's task file, and the task file of any immediate parent tasks are writable. All other task files are considered read-only. This rule is enforced by `tt task checkin`: validation fails if the merge range contains modifications to any other task files (see *Checkin validation* below). This maintains focus on the current task context, and prevents task context that relates to one task leaking into other tasks. Note that parent task files are only writable from within a child task in order to persist the completed-child summary (and optional `subtask:` update) at the point the child task is merged.

At the point of merging, the parent task's frontmatter is updated with the completed child (e.g. `subtask: [x] <task-id> [<task-title>]`). The user may optionally request that the child task file be deleted when merging (`tt task checkin --delete`), leaving no trace beyond the parent's frontmatter; otherwise the task file remains in the repository for future records.

## Implementation details

### Tech stack

Due to the inherent branching necessary, the `jj` (Jujutsu) tool will initially be used as the backing store, with git support potentially added further down the line.

The tool keeps the VCS in sync with the current task or branch (e.g. after `tt task checkout` and `tt task checkin`), so that the working copy reflects the current task context.

**Source of truth** is split as follows:

- **VCS** is the source of truth for: which branches exist (task branches and root branches); and **root attachment** — which root branch each top-level task branch belongs to (the VCS parent of that task's branch). The VCS is *not* used to define parent/child relations between tasks.
- **Parent task file `subtask:` frontmatter** is the source of truth for: **task hierarchy** (which task is whose parent, and the order of children under a parent). A task **P** is the parent of task **C** if and only if P's task file lists C in its `subtask:` list. Top-level tasks are those that do not appear in any other task's `subtask:` list.

Importantly, the todo list itself is not persisted anywhere; it is derived from the branch set, root attachment (from VCS), task hierarchy and metadata (from frontmatter), and the rule below for where each task's file is read.

#### Identifiers and naming

- **Task ID:** Each task has a unique identifier of the form `<prefix><slug>-<hex>`, where `<prefix>` is a configurable string (set via `tt project init`, stored in `.tt/config.toml`, defaulting to `task/`), `<slug>` is a human-readable segment, and `<hex>` is an auto-generated 8-character hexadecimal string (e.g. `task/authentication-ea434dde`). The user cannot set the hex suffix; it is generated by the tool to avoid collisions. The slug defaults to a value derived from the task summary (e.g. lowercased, hyphenated); the user may override it with `tt task new --slug <slug>`. If two tasks share the same slug, the 8-hex suffix keeps branch and file names unique; duplicate slugs are allowed silently.
- **Branch and file naming:** Task branches and task files use the machine-readable name `<prefix><slug>-<hex>` (e.g. with default prefix: `task/add-oauth-flow-8cf8d966`). Regardless of the branch prefix, task files are stored in the `.tt/task` directory (e.g. `.tt/task/<slug>-<hex>.md`).

#### Metadata storage

Task files for ongoing tasks are only present within their respective branches. This means that when generating the overall todo list, the task file contents must be retrieved from all the respective branches.

Within a task's own branch, the task file is referenced via a `TASK.md` symbolic link in the repository root directory (e.g. `./TASK.md -> .tt/task/add-oauth-flow-8cf8d966.md`)

When retrieving task metadata from the task file frontmatter, only the most recent state of the task file will be considered; all former revisions are ignored. This has the consequence that the change history for a task's metadata can be tracked by introspecting the revision history of the task file.

#### Task creation (`tt task new`)

When creating a task via `tt task new`, the tool adds the new task to the parent's child list by creating a commit directly on the parent task's branch (regardless of which branch is currently checked out). That commit adds a `subtask: [ ] <task-id>` frontmatter entry to the parent task file. The child task's branch is then created from this parent commit. The task file for the new task is created in the child task's branch (with `status: TODO`, the `TASK.md` symlink, etc.).

Adding the `subtask:` frontmatter to the parent task file means that changes to the parent task list may need to be propagated to sibling branches to avoid conflicts when checking in tasks. The `tt task new` command accepts an optional `--propagate` flag (and corresponding propagate command flags) to propagate the parent change to descendant task branches after creating the new task.

If the named child branch already exists, the tool notifies the user and refuses to proceed unless the `--force` flag is specified.

#### Merging completed tasks (checkin)

Completing a task entails merging the task branch into its parent. The default `tt task checkin` behavior checks for conflicts with the parent task branch; if conflicts exist, validation fails and the command refuses to proceed.

To reduce the likelihood of frontmatter conflicts (e.g. due to sibling tasks having been added or reordered on the parent), `tt task checkin` can be called with `--rebase` or `--merge`. In that case, the tool first attempts to propagate changes from the parent task into the current (child) branch; if the parent's changes cannot be propagated without conflicts, the command bails out. If `--force` is provided, the task is merged into the parent regardless of conflicts, and the same `--force` behavior is forwarded to the propagate command when used.

The checkin process entails creating a 'checkin' commit on the child branch with the following changes:

- Rewrites the `TASK.md` symbolic link to point to the parent task's task file (to resolve conflicting with the parent branch's `TASK.md` alias)
- Optionally, if `--delete` was provided, delete the child task file, so that no trace of the task remains beyond the `subtask:` entry in the parent's frontmatter. This allows ephemeral child tasks whose files need not be retained.
- Update the parent task file's frontmatter: the corresponding `subtask:` line is set to `subtask: [x] <task-id>`, or `subtask: [x] <task-id> <task-title>` if the `--delete` flag was provided (so that the title remains available despite the task file having been deleted).

Once this checkin commit has been created, the child branch is then merged into the parent branch. After merging the child branch into the parent, that parent's tree will include the completed child task file (unless `--delete` was used), as well as any other completed descendant task files which had already been merged into the child branch. When generating the overall todo list, a completed task's metadata is read from the parent branch (either from the merged task file or from the parent's `subtask: [x] <task-id> <task-title>` line if the task file was deleted).

#### Checkin validation

Before attempting any merge, `tt task checkin` performs validation and refuses to proceed if any check fails. The **merge range** is defined as the set of commits on the child branch that are not in the parent (the commits that would be merged in). High-level checks include:

- Working copy is clean
- Current branch is a task branch
- Current task has exactly one parent
- No incomplete child tasks (all child tasks must be merged before the parent can be checked in)
- No conflicts with parent once the checkin commit has been applied (unless `--force`), or after optional pre-checkin propagate step when using `--rebase`/`--merge`
- No modifications to non-editable task files anywhere in the merge range: only the current task file and (optionally) the immediate parent task file context scratchpad may be modified in that range. No modifications to the parent file frontmatter are allowed apart from the `subtask: [x]` update introduced by the checkin commit. Any other `.tt/task` file changes in the merge range cause checkin to abort.
- The only change to `TASK.md` in the merge range from the child is the symlink pointing to the child's task file and then being reverted by the checkin commit

On failure, `tt task checkin` aborts with an error message and leaves the repository unchanged. Implementations may add further checks via hook scripts.

#### Lifecycle hooks

Hooks are shell scripts or executables under `.tt/hooks/<name>`, one script per hook (no `.d` directory). They follow the same exit-code convention as Git: exit 0 means the workflow may proceed; non-zero means abort, with stderr shown to the user. If a hook is missing, it is skipped.

Every hook receives at least:

- **TT_WORKSPACE_DIR** — Path to the virtual project root (the directory containing all jj worktrees).
- **TT_WORKTREE_DIR** — Path to the jj workspace directory for the current or affected task (where the hook runs), except where noted below.

| Hook | When | Where | Blocking? | Extra env |
|------|------|-------|-----------|-----------|
| **setup** | When initializing a new worktree for a task (during `tt task checkout`) | New task worktree | Optional (non-blocking so init doesn't fail) | TT_TASK_ID, TT_BRANCH, TT_PARENT_TASK_ID, TT_ROOT_BRANCH |
| **pre-checkout** | Before switching branch in `tt task checkout` | Current (outgoing) worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH (newly-checked-out target), TT_PREVIOUS_TASK_ID, TT_PREVIOUS_TASK_BRANCH (outgoing) |
| **post-checkout** | After successful `tt task checkout` | Checked-out task worktree | Optional | TT_TASK_ID, TT_TASK_BRANCH (newly-checked-out), TT_PREVIOUS_TASK_ID, TT_PREVIOUS_TASK_BRANCH (outgoing) |
| **pre-new** | Before creating task in `tt task new` | Parent task worktree | Yes | TT_PARENT_TASK_ID, TT_PARENT_BRANCH, TT_TITLE, TT_SLUG, TT_DESCRIPTION, TT_LABELS (space-separated; labels with spaces/special chars quoted) |
| **post-new** | After task created in `tt task new` | New task worktree if created, else worktree we end up in | Optional | TT_TASK_ID (new), TT_TASK_BRANCH (new), TT_PARENT_TASK_ID, TT_PARENT_BRANCH; TT_WORKTREE_DIR = that same worktree |
| **pre-checkin** | Before checkin in `tt task checkin` | Child (current) task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH, TT_PARENT_TASK_ID, TT_PARENT_BRANCH |
| **pre-receive** | Before merge applied on parent (during checkin) | Parent task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH (parent), TT_INCOMING_TASK_ID, TT_INCOMING_BRANCH (child being merged) |
| **post-receive** | After merge applied on parent (during checkin) | Parent task worktree | Optional | Same as pre-receive |
| **pre-propagate** | Before `tt task propagate` updates descendants | Current (source) task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH |
| **post-propagate** | After `tt task propagate` completes | Same | Optional | TT_TASK_ID, TT_TASK_BRANCH |
| **pre-remove** | Before `tt task remove` | Parent task worktree (task whose frontmatter is updated) | Yes | TT_TASK_ID, TT_TASK_BRANCH (removed task), TT_PARENT_TASK_ID, TT_PARENT_TASK_BRANCH (task we're removing from) |
| **post-remove** | After `tt task remove` | Same | Optional | Same as pre-remove |

**Blocking vs optional:** Pre- hooks are blocking: a non-zero exit aborts the command. Post- hooks and **setup** are best-effort: a non-zero exit may be logged but does not abort the workflow, so optional bookkeeping does not fail the operation.

**post-new:** If no new worktree is created, TT_WORKTREE_DIR is the worktree we end up in (e.g. the parent's); TT_TASK_ID and TT_TASK_BRANCH still refer to the new task and its branch.

**TT_LABELS:** Format is space-separated; labels containing spaces or special characters are quoted (implementation detail).

#### Checkout behavior (`tt task checkout`)

When checking out a task via `tt task checkout <task-id>`, the user may optionally provide a `--worktree` flag.

- **With `--worktree`:** The tool ensures the task is checked out in its own jj workspace (creating it if necessary).
- **Without `--worktree`:** The tool checks out the task branch within the closest ancestor task workspace (if any exist), or the current workspace if no ancestors of the task have been checked out in their own workspace.

If the target workspace's working copy is an ancestor task's workspace (i.e. not the workspace for the task itself) and contains changes (e.g. due to another currently-checked-out task), the tool alerts the user and refuses to proceed unless the `--force` flag is provided.

The `--worktree` argument does not need to be provided for subsequent checkouts of the same task: the default `tt task checkout` behavior is to check whether a workspace already exists for that task and use it when present.

If multiple workspaces exist for a given task branch, the user must specify the desired workspace via `--worktree=<path-to-workspace>`. This form can always be specified if the user wants to control the path of the workspace.

#### Task reorder and remove

Child tasks of the current task are ordered and managed via the `subtask:` frontmatter of the current task file.

- **`tt task reorder <task-id> <modifier>`** — Reorder a direct child task. The modifier is one of: `--up`, `--down`, `--after <other-task-id>`, or `--before <other-task-id>` (mutually exclusive). If the reorder is impossible (e.g. the task is already at the first list item with the `--up` modifier, or if the provided `<other-task-id>` is not a sibling of the `<task-id>`)
- **`tt task remove <task-id>`** — Remove a direct child task from the current task (updates frontmatter; the child's branch and task file are not deleted by this command).

#### Status and child list

**`tt task status`** shows the current task and branch, and the status of all `subtask:` entries directly assigned to the current task (i.e. the direct children listed in the current task file's frontmatter).

### Propagate

When the current task branch gains new commits (e.g. after merging another child with `tt task checkin`, or after direct work on the parent), its descendant task branches still have the old parent revision as their base. **`tt task propagate [--from=<parent-id>] [--to=<descendant-id> [--to=<descendant-id> ...]]`** updates the provided descendant branch(es) (by default, recursively) so that it is based on the parent task branch's current tip. `--from` defaults to the current task ID; `--to` defaults to the task IDs of all immediate children of the parent task. Strategy defaults to **`--rebase`**; use **`--merge`** to merge the parent into each child instead. Use **`--shallow`** to update only direct children of the current branch. Use **`--force`** to proceed regardless of whether the propagation produces conflicts.

**Scope:** The parent branch must be a task branch or a root branch with task-branch children. By default, all descendant task branches in the subtree are updated; with `--shallow`, only direct children are updated. Branches are processed in a deterministic order (parent before children) so each branch is rebased or merged onto its parent's already-updated tip.

**Preconditions (all checked before any updates; any failure causes the command to error and refuse to proceed):**

- Working copy of the current task is clean.
- Every branch that would be updated has exactly one parent (no merge commits at tip). If any has multiple parents, the command errors.
- No worktree that would be affected may contain untracked changes in its working copy. If any does, the command errors.
- When `--rebase` is used (default), the rebase must be applicable cleanly for every branch that would be updated. If any rebase would not apply cleanly, the command errors unless `--force` is specified. With `--force`, the implementation may leave conflict state for the user to resolve. Under JJ, conflicts are allowed in the model; no special conflict-failure handling is required beyond this.

**Worktrees:** After updating branch tips, the tool syncs all changed child worktrees to the new commit so their working copy reflects the updated branch tip. The user's current working copy (HEAD) is not switched unless it was one of the updated branches.

Propagate does not perform checkin-style merge-range validation (task-file rules for checkin do not apply when updating a child's base).

### Generating the overall todo list

To generate the overall todo list, the tool must enumerate all active task branches, then merge the active branch's primary task file with the task files of all completed tasks.

#### Detailed algorithm

1. Enumerate task branches and root branches

  - **List branches** that represent tasks (e.g. names matching `<prefix><slug>-<hex>`). These are the task branches; each has an "owner" task (the task whose ID matches the branch name).
  - **Identify root branches**: A **root branch** is a branch that is not a task branch (does not match the task naming pattern) and is used as a merge target; a project may have multiple root branches (multiple task trees). For each task branch, the VCS (e.g. jj's revision parent) gives its parent revision; map that to a branch. This is used *only* for root attachment (step 4), not for building the task tree. If a task branch has multiple parent revisions (merge commit), the tool treats it as invalid and shows an error marker.

  At this stage you have: all task branches, and for each task branch its VCS parent branch (so you know which are roots and which task branches have a root as VCS parent).

2. For each task, choose where to read its task file

  Do *not* use the VCS parent branch to decide this. For every task **T**:

  - **Merged (done)**  
    Some task branch **B** has an owner task file (the task file for the task that owns B) whose frontmatter contains `subtask: [x] <T> ...`. That branch B is the parent task's branch (the one that received the checkin).  
    → **Read** task **T**'s metadata from **branch B**: either from `.tt/task/<T>.md` on B if the task file was retained at checkin, or from the `subtask: [x] <task-id> [<task-title>]` line in B's owner task file if the task file was deleted at checkin.

  - **Not merged (ongoing)**  
    No task branch's owner task file contains `subtask: [x] <T> ...`.  
    → **Read** task file (and `subtask:` list for children) **from task T's own branch** (e.g. via `TASK.md` or `.tt/task/<T>.md`).

  Implementation: for each task T, scan all task branches B; on B, read the owner task file (the task file for the task that has branch B). If any such file contains `subtask: [x] <T> ...`, then T is merged and the canonical source for T is that branch B; otherwise the canonical source for T is T's own branch.

3. Load metadata and build the task tree from frontmatter

  - From the chosen revision for each task (from step 2), parse the task file metadata from **frontmatter** (title, status, labels, `subtask:` list).
  - **Build the task tree** from frontmatter only:
    - **Top-level tasks**: tasks that do not appear in any other task's `subtask:` list.
    - **Children of a task P**: the tasks listed in P's `subtask:` list, in that order.
    - **Parent of task C**: the unique task P whose `subtask:` list contains C (if C is not top-level).
  - **Validation**: Every non–top-level task must appear in exactly one other task's `subtask:` list. If a task appears in more than one list (multiple parents) or is not top-level but appears in none (orphan), the tool treats it as invalid and reports an error or shows an error marker.

4. Attach top-level tasks to roots and build output sections

  - **Root attachment**: For each top-level task T, use the **VCS parent of T's branch** to assign T to a section. If the VCS parent is a root branch R, T belongs under "Tasks on branch `R`:". If the VCS parent is not a root branch (e.g. it is a task branch), T is **detached** and belongs under "Tasks with no branch parent:". Order top-level tasks within each section e.g. by branch name or creation time.
  - **Filtering**: If the user specified `--root <branch-name>` (one or more), only emit sections for those roots. If the user specified `--orphan`, only emit the detached section. If neither is specified, emit all root sections and the detached section (if it has any tasks).

5. Emit the markdown

  - For each section to be output (in order: requested roots, then detached if included), emit a **section header** line: `Tasks on branch \`<name>\`:` or `Tasks with no branch parent:` (no trailing blank line in the spec; one blank line after the header is conventional before the first bullet).
  - Under each section, for each top-level task in that section, output a task line, then recurse into its children (from the `subtask:` order) with one more indent level per nesting. Sibling order is always the order of `subtask:` entries in the parent task file.

  For each task line, output:

  - Checkbox from status: `[ ]` / `[-]` / `[x]` (from task file or from `subtask: [x] ...` on parent)
  - Link: `[<prefix><slug>-<hex>](.tt/task/<slug>-<hex>.md)` (e.g. `[task/add-oauth-flow-8cf8d966](.tt/task/add-oauth-flow-8cf8d966.md)`)
  - Title (from `title:` task file frontmatter or from the `subtask: [x] <task-id> <task-title>` on parent)

  Indentation reflects hierarchy (task → child task → …).

#### End-to-end flow (summary)

```text
  → enumerate task branches; identify root branches (VCS parent used only for root attachment)
  → for each task T: find where to read T's file
       scan all task branches for owner task file containing subtask: [x] <T>
       if found on branch B → merged → read T from B (file or frontmatter line)
       else → ongoing → read T from T's branch
  → build task tree from frontmatter (top-level = not in any subtask list; children = subtask list order)
  → attach top-level tasks to roots or detached via VCS parent of each top-level task's branch
  → filter sections by --root / --orphan if present
  → for each section: emit "Tasks on branch \`<name>\`:" or "Tasks with no branch parent:"; then walk tree (depth-first); emit checkbox + link + title per task
  → output markdown
```

So: **completed** tasks are read from the **branch whose owner task file** contains `subtask: [x] <T> ...` (the parent task's branch); **ongoing** tasks from the **task branch** only. The **hierarchy** comes from frontmatter; **root attachment** comes from VCS.

### Generating the 'focused' todo list for the current task

**Input:** The current branch (or current task ID). Resolve the current branch to a task branch **T**; if the current branch is not a task branch, the focused list may be empty or show only a message.

**Algorithm:**

1. **Resolve current task:** From the current branch, determine the task branch **T** (e.g. current branch is a task branch, or the branch name identifies the task).
2. **Walk to root:** From **T**, walk backwards via the frontmatter-defined parent chain (the task that lists this one in `subtask:`) to the top-level task. Collect the path: **T**, its parent task, and so on up to the root. The root branch for grouping is the VCS parent of that top-level task's branch.
3. **Load task files:** For each task on this path, choose where to read its task file using the same rule as the full algorithm (merged = some branch's owner task file has `subtask: [x] <T>` → read from that branch; else read from task branch). Load child order from each task's `subtask:` list.
4. **Order and emit:** Order and emit markdown in the same format as the full list, but only for this subset of tasks. Indentation and hierarchy are preserved for the focused slice.

**Output:** Same markdown format as the full todo list. Useful for establishing context without pulling in the entire project tree.

### Commands

The canonical form for CLI commands is `tt <entity-type> <command>`, e.g. `tt project init` or `tt task checkout`. The following aliases exist for ease of typing:

- `tt init` → `tt project init`
- `tt new` → `tt task new`
- `tt checkout` → `tt task checkout`
- `tt checkin` → `tt task checkin`
- `tt status` → `tt task status`
- `tt show` → `tt task show`
- `tt propagate` → `tt task propagate`
- `tt list` → `tt task list`

- **`tt task list`** — Generate and print the full todo list to stdout. Top-level tasks are grouped under section headers by root branch. Optional: **`[--root <branch-name>]`** (repeatable) and **`[--orphan]`** to show only the listed root section(s). Example: `tt task list --root main` or `tt task list --root main --root next --orphan`.
- **`tt task list --focused`** — Generate and print the focused todo list (current task and its direct ancestors only) to stdout.
- **`tt task status`** — Show the current task and branch, and the status of all direct child tasks (the `subtask:` entries in the current task file).
- **`tt task show [<task-id>]`** — Show the full context of the current task, or of the task specified by `<task-id>`. Full context means the contents of that task's task file (frontmatter and body). Output is to stdout only.
- **`tt task propagate [--rebase | --merge] [--shallow] [--force]`** — Propagate the current task branch state to descendant task branches so their base is the parent's current tip (see *Propagate* above).
- **`tt task reorder <task-id> <modifier>`** — Reorder a direct child task (see *Task reorder and remove* above).
- **`tt task remove <task-id>`** — Remove a direct child task from the current task (see *Task reorder and remove* above).

Other commands used in the workflow: `tt project init`, `tt task new`, `tt task checkout`, `tt task checkin`, `tt task propagate`.

### User workflow

The standard workflow proceeds as follows:

1. User initializes a todo-tree project via `tt project init <path-to-repo> <path-to-virtual-project-folder> [--prefix <prefix>]`
  - The tool checks that the repository's working directory is clean, and that there exists no `.tt` directory in the repository root directory
  - The tool creates a directory at `<path-to-virtual-project-folder>`; this will contain the various workspace checkouts
  - The tool creates a `.tt/config.toml` file containing a configurable `prefix` for task IDs, defaulting to `task/`
  - The tool creates a symbolic link at `<path-to-virtual-project-folder>/HEAD` which (initially) references the repository directory. This symbolic link is automatically updated to the most recently checked-out task whenever the user checks out a task, serving as a 'quick link' to the current development branch.

2. User creates a new task via `tt task new [--parent <parent-task-id>] [--slug <slug>] [--title <title>] [--description <description>] [--label <label> [--label <label>...]] [--propagate [<propagate-flags>]]`
  - The tool checks that the current working directory is clean (for the parent's workspace if creating on parent's branch)
  - The tool prompts the user for task summary, autosuggested branch name, and description if none were provided
  - The tool locates the parent branch via the provided parent task ID, defaulting to the current branch (if the parent branch is not itself a task branch, it will be used as a project root). If the parent would result in multiple parents (e.g. a merge commit), the tool notifies the user and refuses to create the task.
  - A commit is created **on the parent task's branch** (regardless of which branch is currently checked out) that adds `subtask: [ ] <task-id>` to the parent task file's frontmatter.
  - A new branch is created for the task, from this parent commit.
  - A new commit is created on the newly-created task branch with: a new task file in `.tt/task/<slug>-<hex>.md` (with `status: TODO`) and a `./TASK.md -> .tt/task/<slug>-<hex>.md` symbolic link.
  - If `--propagate` is provided, the tool runs propagate (with any given propagate flags) to propagate the parent's new commit to sibling (and optionally descendant) task branches.

3. User starts working on a task via `tt task checkout <task-id> [--worktree [=<path>]]`
  - The tool checks that the target workspace's working copy is clean (or that the user has provided `--force` when the target is an ancestor workspace with changes)
  - The tool verifies that the task branch exists, returning an error if not
  - If `--worktree` (or `--worktree=<path>`) is provided, or a workspace already exists for this task, the tool uses or creates the appropriate jj workspace; otherwise it checks out the task branch in the closest ancestor task workspace or the current workspace (see *Checkout behavior* above)
  - If the task file has `status: TODO`, the tool updates it to `IN-PROGRESS`
  - The tool runs `.tt/hooks/setup` (project-specific setup script; see *Lifecycle hooks*) within the task's worktree directory when initializing a new workspace
  - The tool updates the `HEAD` symbolic link within the virtual project folder to reference the task's workspace directory

4. User works on the task in the current branch, committing changes on the branch and accumulating relevant task context in `./TASK.md`

5. User finishes working on a task via `tt task checkin [--rebase | --merge] [--force] [--delete]`
  - The tool runs pre-merge validation (see *Checkin validation* above). If any check fails, `tt task checkin` aborts with an error message and leaves the repository unchanged. When `--rebase` or `--merge` is used, the tool first attempts to propagate from the parent; if propagation cannot complete without conflicts, the command bails out unless `--force` is used.
  - The tool runs `.tt/hooks/pre-checkin` within the current task's worktree directory
  - The tool updates the parent task file's frontmatter: the corresponding `subtask:` line is set to `subtask: [x] <task-id> <task-summary>`. If `--delete` is provided, the child task file is removed as part of the merge (so only the frontmatter update remains on the parent).
  - The tool merges the child branch into its parent branch: the tool locates the parent task worktree (creating and initializing if necessary), runs `.tt/hooks/pre-receive`, performs the merge (resolving any `TASK.md` conflict by keeping the parent's version), then runs `.tt/hooks/post-receive`. If there is no parent task (i.e. the task is a direct child of a root branch), the tool merges directly into that root branch
  - After a successful checkin, the tool switches the worktree to the parent by updating the `HEAD` symlink to point to the parent's worktree and deleting the child worktree (if it was dedicated to this task). If as a result the user's working directory is now set to a path that was deleted (i.e. they were working within the child branch directory rather than the `HEAD` symlink working copy), the tool will switch directories to the equivalent path within the `HEAD` symlink, so that the user sees the updated parent task working copy.
  - If a merge conflict occurs in the working copy or in other `.tt/` files, the user must resolve it manually; for `TASK.md`, the intended resolution is to keep the parent's version. After resolving, the user can retry the merge or complete the checkin as appropriate
