# Design document: todo-tree

todo-tree (`tt`) is a CLI tool that can be used for task tracking and context management within complex software development projects

## Overview

todo-tree is intended to combine both lightweight in-repository task tracking, with straightforward and structured task context management.

The tool will use the version control system as backing store for a stack-based model of a project's current to-do state, with the entire scope of work for the project represented as a tree structure.

This allows the user to define a complex branching workflow, where tasks can be subdivided into more granular tasks and eventually merged into their parent task when complete. Each task is represented by a VCS branch, and has an initial commit that creates the task within the overall project. This initial commit can be used to track which parent branch the task branched off from.

A parent task can contain one or more child tasks, each of which represents an independent unit of work (whether that is a feature or set of features). The VCS branch topology expresses dependencies between two different tasks (a parent branch depends on all its child branches).

The project task graph must form a **tree structure**: each task has exactly one parent branch. DAG use cases (multiple parents per task) are not allowed. On encountering a task with multiple parents, the tool commands notify the user and refuse to make changes. Multiple non-task root branches are still allowed, but this would represent multiple task trees (effectively multiple sub-projects within the same workspace).

Subtasks are similar to tasks, however they must be attached to a single task, and their development takes place directly in this task's VCS branch. Subtasks are atomic, and cannot contain further tasks or subtasks. Subtasks typically represent a workflow of individual steps needed to produce a single deliverable unit of work. They are created, reordered, and completed via the CLI (see *Subtask lifecycle* under Implementation details). A task is eligible for merging when all its subtasks (and child tasks) are complete.

A **root branch** is a merge target that cannot itself be merged any further (e.g. the branch the user was on when they created the top-level task). A workspace can contain multiple root branches, each acting as the root of a separate task tree. All development happens by splitting off task branches from a parent (root or task branch), merging them back when the unit of work is complete. Thus the parent branch gradually becomes more complete as more of its child branches are merged. When a given parent branch has no remaining child branches, the parent branch is eligible for merging into its own parent(s), or new child branches can be created to add more work on the parent branch.

Key to the branching model is the notion of task context. Each branch has its own local task context, and has a reference to its parent branch that allows the child branch to read the parent branch's context. This can be traced arbitrarily far back to the root branch(es). This means that all child branches will have access to the whole chain of parent context, so they are aware of where they stand in the overall project plan. 

There are two components to the context. One is the high-level overall to-do list, which stores the entire to-do state of the project, and the other is individual granular task files.

The project to-do list is merely a markdown bullet point listing of all the different tasks that have been added to the project, where each bullet point contains the following, separated by spaces:

- A GFM checkbox indicating the status of the tasks:
  - To-do: `[ ]`
  - In progress: `[-]`
  - Done: `[x]`
- A Markdown relative link to the task file for that task, labeled by the machine-readable name of the branch for that task
- A single-line human-readable task summary

Example of an in-progress project to-do list:

```markdown
- [-] [task/authentication-ea434dde](.tt/task/authentication-ea434dde.md) Implement user authentication
  - [x] [task/email-signup-a4048c0f](.tt/task/email-signup-a4048c0f.md) Allow user creation with email address
  - [-] [task/add-oauth-flow-8cf8d966](.tt/task/add-oauth-flow-8cf8d966.md) Integrate OAuth2 signin flow
    1. [x] [subtask/research-oauth-flow-c10103b7](.tt/subtask/research-oauth-flow-c10103b7.md) Research SSO auth flow
    2. [-] [subtask/determine-sso-providers-3ddc3c2f](.tt/subtask/determine-sso-providers-3ddc3c2f.md) Determine supported SSO providers
    3. [ ] [subtask/plan-feature-9fdbbd60](.tt/subtask/plan-feature-9fdbbd60.md) Plan feature
    4. [ ] [subtask/write-e2e-tests-8961d5b1](.tt/subtask/write-e2e-tests-8961d5b1.md) Write end-to-end tests
    5. [ ] [subtask/implement-feature-7702ec93](.tt/subtask/implement-feature-7702ec93.md) Implement feature
    6. [ ] [subtask/review-implementation-34a0507c](.tt/subtask/review-implementation-34a0507c.md) Review feature implementation
    7. [ ] [subtask/update-docs-6369ad14](.tt/subtask/update-docs-6369ad14.md) Update documentation
    8. [ ] [subtask/update-context-48c3fa01](.tt/subtask/update-context-48c3fa01.md) Update parent task context
  - [ ] [task/forgotten-password-ef19c63e](.tt/task/forgotten-password-ef19c63e.md) Implement 'forgotten password' signin
- [ ] [task/landing-page-4613e4c8](.tt/task/landing-page-4613e4c8.md) Build landing page
- [ ] [task/pricing-page-cdf2d632](.tt/task/pricing-page-cdf2d632.md) Build pricing page
```

The second component to project context is individual task files. Each file pertains to one specific task and it gives the context for that task. Metadata is stored in Markdown frontmatter, including the one-line task summary, the task status, a full task description encoded as a JSON string, a list of labels used to categorize the task, and a list of any subtasks contained within the task. The order of `subtask:` entries in frontmatter defines the display order of subtasks in the todo list.

Example of a task file for a task which has not yet been started (`.tt/task/cdf2d632-pricing-page.md`):

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
subtask: [x] subtask/research-oauth-flow-c10103b7
subtask: [-] subtask/determine-sso-providers-3ddc3c2f
subtask: [ ] subtask/plan-feature-9fdbbd60
subtask: [ ] subtask/write-e2e-tests-8961d5b1
subtask: [ ] subtask/implement-feature-7702ec93
subtask: [ ] subtask/review-implementation-34a0507c
subtask: [ ] subtask/update-docs-6369ad14
subtask: [ ] subtask/update-context-48c3fa01
---
- OAuth2 spec: https://oauth.net/2/
- Relevant project source files:
  - `docs/auth`
  - `src/views/login`
```

While working on the task, context can be added to this task file in markdown format. This context can be used as a 'scratch pad' to record anything that could be useful during implementation of the task. Importantly however, only the current task's task file, and the task file of any immediate parent tasks are writable. All other task files are considered read-only. This rule is enforced by `tt checkin`: validation fails if the merge range contains modifications to any other task or subtask files (see *Checkin validation* below). This maintains focus on the current task context, and prevents task context that relates to one task leaking into other tasks. Note that parent task files are only writable from within a child task in order to persist a context summary from the child task to the parent task at the point the child task is merged.

At the point of merging, the task file is updated to a 'done' state, and the task file can no longer be modified: future changes must be created as a new ticket. Task files for completed tasks remain in the repository for future records, however subtask files are considered to be ephemeral context and are only present within the branch for the task they relate to. At the point a task is merged, any subtask files are deleted from its branch.

## Implementation details

### Tech stack

Due to the inherent branching necessary, the `jj` (Jujutsu) tool will initially be used as the backing store, with git support potentially added further down the line.

The tool keeps the VCS in sync with the current task or branch (e.g. after `tt checkout` and `tt checkin`), so that the working copy reflects the current task context.

As far as possible, the VCS will be used as the source of truth for all relations between tasks, storing the project task tree via branches, with each task having exactly one parent branch.

Importantly, the todo list itself is not persisted anywhere, rather it is derived entirely from the VCS branch structure and the contents of the task files.

This has the consequence that tasks cannot be reordered within their parent: initially there will be no support for defining the order of child tasks within a parent (tasks are displayed in order of task file creation commit time).

#### Identifiers and naming

- **Task ID:** Each task has a unique identifier of the form `<prefix><slug>-<hex>`, where `<prefix>` is a configurable string (set via `tt init`, stored in `.tt/config.toml`, defaulting to `task/`), `<slug>` is a human-readable segment, and `<hex>` is an auto-generated 8-character hexadecimal string (e.g. `task/authentication-ea434dde`). The user cannot set the hex suffix; it is generated by the tool to avoid collisions. The slug defaults to a value derived from the task summary (e.g. lowercased, hyphenated); the user may override it with `tt new --slug <slug>`. If two tasks share the same slug, the 8-hex suffix keeps branch and file names unique; duplicate slugs are allowed silently.
- **Subtask ID:** Subtasks use the same format (prefix + slug + hyphen + hex). Uniqueness is per repository. The slug defaults from the subtask summary (or prompt); the user may override with `tt subtask add --slug <slug>`.
- **Branch and file naming:** Task branches and task files use the machine-readable name `<prefix><slug>-<hex>` (e.g. with default prefix: `task/add-oauth-flow-8cf8d966`). Subtask files live at `.tt/subtask/<slug>-<hex>.md` (subtask prefix is fixed).

#### Metadata storage

Task files themselves for ongoing tasks are only present within their respective branches. This means that when generating the overall todo list, the task file contents must be retrieved from all the respective branches.

Within a task branch, the task file is referenced via a `TASK.md` symbolic link in the repository root directory (e.g. `./TASK.md -> .tt/task/add-oauth-flow-8cf8d966.md`)

When retrieving task metadata from the task file frontmatter, only the most recent state of the task file will be considered; all former revisions are ignored. This has the consequence that the change history of a task can be tracked by introspecting the revision history of the task file.

#### Merging completed tasks

Completing a task entails creating a commit with the following changes:

- Update the task file status on the child branch to 'DONE'
- Remove all subtasks from the task file and delete their respective task files
- Update the parent task file with any context relevant to the parent task

The child branch is then merged into its parent branch. On merge, the parent's `TASK.md` is kept (the conflict is resolved by discarding the child's symlink change).

After merging the child branch into the parent, that parent's tree will include the completed child task file, as well as any other completed descendant task files which had already been merged into the child branch. When generating the overall todo list, a completed task's file is read from its parent branch.

Tasks cannot be marked as completed if they have one or more outstanding child tasks.

#### Checkin validation

Before attempting any merge, `tt checkin` performs validation and refuses to proceed if any check fails. The **merge range** is defined as the set of commits on the child branch that are not in the parent (the commits that would be merged in). High-level checks include:

- Working copy is clean
- Current branch is a task branch
- Current task has exactly one parent
- No incomplete child tasks (all child tasks must be merged before the parent can be checked in)
- No modifications to non-editable task files anywhere in the merge range: only the current task file and (optionally) the immediate parent task file may be modified in that range. Any other `.tt/task` or `.tt/subtask` file changes in the merge range cause checkin to abort
- The only change to `TASK.md` in the merge range from the child is the symlink pointing to the child's task file (which will be discarded on merge)

On failure, `tt checkin` aborts with an error message and leaves the repository unchanged. Implementations may add further checks (e.g. hook failures, conflict detection before merge).

#### Subtask lifecycle

Subtasks are created and ordered via the CLI; the order of `subtask:` entries in the task file frontmatter is maintained by the tool and defines display order.

- **`tt subtask add [--summary <summary>] [--slug <slug>]`** — Add a subtask to the current task. If `--summary` is omitted, the user is prompted (as with `tt new`). The slug defaults from the summary; `--slug` overrides it. The new subtask is appended to the task's subtask list.
- **`tt subtask remove <subtask-id>`** — Remove a subtask from the current task.
- **`tt subtask move <subtask-id> <modifier>`** — Reorder a subtask. The modifier is one of: `--up`, `--down`, `--after <subtask-id>`, or `--before <subtask-id>` (mutually exclusive).
- **`tt subtask complete <subtask-id>`** — Mark the subtask as done (updates frontmatter and checkbox).

There is no separate branch for subtasks; focus is on the current task's branch, and the task file (and subtask files) live only on that branch until the task is merged.

### Generating the overall todo list

To generate the overall todo list, the tool must enumerate all active task branches, then merge the active branch's primary task file with the task files of all completed tasks.

#### Detailed algorithm

1. Enumerate task branches and the branch tree

  - **List branches** that represent tasks (e.g. names matching `<prefix><slug>-<hex>`).
  - **Resolve parent**: For each such branch, use the VCS (e.g. jj's revision parent) to get the parent revision. Map that revision to a branch. A **root branch** is a branch that is not a task branch (does not match the task naming pattern) and is used as a merge target; a project may have multiple root branches (multiple task trees). If a task branch has multiple parent revisions (merge commit), the tool treats it as invalid and shows an error marker node under each of its parent tasks, to draw the user's attention to the invalid task.
  - **Build the task tree**: Each task branch is a node with exactly one parent branch. Tasks whose parent is a root branch are top-level tasks.

  So at this stage you have: "all task branches," "each task's parent in the tree," and which branches are roots.

2. For each task, choose where to read its task file

  For every task branch **T**:

  - **Merged (done)**  
    The task's file was merged into its parent branch, so it exists on the **parent branch** at that parent's current revision.  
    → **Read** `.tt/task/<T>.md` **from the parent branch**.

  - **Not merged (ongoing)**  
    The file exists only on **T**.  
    → **Read** `TASK.md` **from the task branch T**.

  "Merged" can be implemented as: at the parent branch's tip (or the merge-base with **T**), does the path `.tt/task/<T>.md` exist? If yes → merged → read from parent. If no → read from **T**.

  So you get one "canonical" task file per task, from either a parent or the task branch.

3. Load metadata and subtasks

  - For that chosen revision (parent or **T**), parse the task file metadata from **frontmatter** (title, status, labels, subtask list).
  - Resolve **subtasks** the same way: subtask files are stored under `.tt/subtask/<slug>-<hex>.md`. They exist only on the **same branch as the task** (and are ephemeral, only existing on active task branches). So for each subtask, read from the **task branch T**.

  That gives you, for each task: summary, status, link, and ordered list of subtasks with their statuses.

4. Order siblings and flatten to a list

  - **Order** child tasks under the same parent (e.g. by task-file creation time on the parent, or by commit time, per the "no reorder" rule).
  - **Walk the tree** for the full list: with multiple roots, show all root-level task branches as top-level bullets (flat), with their children under each. That is, emit each top-level task (a task whose parent is a root branch), then recurse into its children with one more indent level, then continue with the next top-level task. Order top-level tasks e.g. by branch name or creation time. Subtasks are emitted under their task (e.g. numbered list under that task's bullet).

5. Emit the markdown

  For each task (and subtask) line, output:

  - Checkbox from status: `[ ]` / `[-]` / `[x]`
  - Link: `[<prefix><slug>-<hex>](.tt/task/<slug>-<hex>.md)` (e.g. `[task/add-oauth-flow-8cf8d966](.tt/task/add-oauth-flow-8cf8d966.md)`)
  - Summary (title from frontmatter)

  Indentation reflects hierarchy (task → child task → subtasks), with subtasks expressed as numbered lists.

#### End-to-end flow (summary)

```text
  → enumerate task branches + parent pointer; identify root branches (reject task branches with multiple parents)
  → build task tree (top-level tasks = tasks whose parent is a root)
  → for each task node:
       if .tt/task/<id>.md exists on parent → merged → read task file from parent
       else → ongoing → read task file from task branch
       load subtask list from task branch (if still present)
  → sort siblings (e.g. by creation)
  → walk: top-level tasks as flat bullets, then depth-first under each; emit checkbox + link + title per task/subtask
  → output markdown
```

So: **completed** tasks contribute to the list by reading their (merged) task file from the **parent branch**; **ongoing** tasks by reading from the **task branch** only.

### Generating the 'focused' todo list for the current task

**Input:** The current branch (or current task ID). Resolve the current branch to a task branch **T**; if the current branch is not a task branch, the focused list may be empty or show only a message.

**Algorithm:**

1. **Resolve current task:** From the current branch, determine the task branch **T** (e.g. current branch is a task branch, or the branch name identifies the task).
2. **Walk to root:** From **T**, walk backwards via its direct ancestry to the root branch. Collect the path: **T**, its parent task, and so on up to the root.
3. **Load task files:** For each task on this path, choose where to read its task file using the same rule as the full algorithm (merged → read from parent; ongoing → read from task branch). Load subtask lists from the task branch for each task that has subtasks.
4. **Order and emit:** Order and emit markdown in the same format as the full list, but only for this subset of tasks (and their subtasks). Indentation and hierarchy are preserved for the focused slice.

**Output:** Same markdown format as the full todo list. Useful for establishing context without pulling in the entire project tree.

### Commands

- **`tt list`** — Generate and print the full todo list to stdout. Output can be piped to a file if needed; the tool does not write to a file directly.
- **`tt list --focused`** — Generate and print the focused todo list (current task and its direct ancestors only) to stdout.
- **`tt status`** — Show the current task and branch.
- **`tt show [<task-id>]`** — Show the full context of the current task, or of the task specified by `<task-id>`. Full context means the contents of that task's task file (frontmatter and body). Output is to stdout only.

Other commands used in the workflow: `tt init`, `tt new`, `tt checkout`, `tt checkin`, and the subtask commands (see *Subtask lifecycle* below).

### User workflow

The standard workflow proceeds as follows:

1. User initializes a todo-tree project via `tt init <path-to-repo> <path-to-virtual-project-folder> [--prefix <prefix>]`
  - The tool checks that the repository's working directory is clean, and that there exists no `.tt` directory in the repository root directory
  - The tool creates a directory at `<path-to-virtual-project-folder>`; this will contain the various workspace checkouts
  - The tool creates a `.tt/config.toml` file containing a configurable `prefix` for task IDs, defaulting to `task/`
  - The tool creates a symbolic link at `<path-to-virtual-project-folder>/HEAD` which (initially) references the repository directory. This symbolic link is automatically updated to the most recently checked-out task whenever the user checks out a task, serving as a 'quick link' to the current development branch.

2. User creates a new task entry via `tt new [--parent <parent-task-id>] [--slug <slug>] [--summary <summary>] [--description <description>] [--label <label> [--label <label>...]]`
  - The tool checks that the current working directory is clean
  - The tool prompts the user for task summary, autosuggested branch name, and description if none were provided
  - The tool locates the parent branch via the provided parent task ID, defaulting to the current branch (if the parent branch is not itself a task branch, it will be used as a project root). If the parent would result in multiple parents (e.g. a merge commit), the tool notifies the user and refuses to create the task.
  - A new branch is created for the task, at the parent commit
  - A new commit is created on the newly-created task branch with the following contents:
   - a new task file in `.tt/task/<slug>-<hex>.md` (using the configured prefix for the task ID) containing the frontmatter header for the task's metadata (with `status: TODO`)
   - a `./TASK.md -> .tt/task/<slug>-<hex>.md` symbolic link

3. User starts working on a task via `tt checkout <task-id>`
  - The tool checks that the current working directory is clean
  - The tool verifies that the task branch has been created within the repository, returning an error if not
  - If the task branch's task file has `status: TODO`:
    - The tool creates a new jj workspace within the virtual project folder that references the task branch
    - The tool runs `.tt/hooks/setup` (project-specific setup script) within the task's worktree directory
    - The tool updates the task file `status` to `IN-PROGRESS`
  - The tool updates the `HEAD` symbolic link within the virtual project folder to reference the task's jj workspace directory

4. User works on the task in the current branch, committing changes on the branch and accumulating relevant task context in `./TASK.md`

5. User finishes working on a task via `tt checkin`
  - The tool runs pre-merge validation (see *Checkin validation* below). If any check fails, `tt checkin` aborts with an error message and leaves the repository unchanged
  - The tool runs `.tt/hooks/pre-checkin` within the current task's worktree directory
  - The tool updates the task file to `status: DONE` and removes any subtask metadata
  - The tool removes any subtask task files
  - The tool merges the child branch into its parent branch: the tool locates the parent task worktree (creating and initializing if necessary), runs `.tt/hooks/pre-receive`, performs the merge (resolving any `TASK.md` conflict by keeping the parent's version), then runs `.tt/hooks/post-receive`. If there is no parent task (i.e. the task is a direct child of a root branch), the tool merges directly into that root branch
  - After a successful checkin, the tool switches the worktree to the parent by updating the `HEAD` symlink to point to the parent's worktree and deleting the child worktree. If as a result the user's working directory is now set to a path that was deleted (i.e. they were working within the child branch directory rather than the `HEAD` symlink working copy), the tool will switch directories to the equivalent path within the `HEAD` symlink, so that the user sees the updated parent task working copy.
  - If a merge conflict occurs in the working copy or in other `.tt/` files, the user must resolve it manually; for `TASK.md`, the intended resolution is to keep the parent's version. After resolving, the user can retry the merge or complete the checkin as appropriate
