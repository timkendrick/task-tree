# Design document: todo-tree

todo-tree (`tt`) is a CLI tool that can be used for task tracking and context management within complex software development projects

## Overview

todo-tree is intended to combine both lightweight in-repository task tracking, with straightforward and structured task context management.

The tool will use the version control system as backing store for a stack-based model of a project's current to-do state, with the entire scope of work for the project represented as a tree structure.

This allows the user to define a complex branching workflow, where tasks can be subdivided into more granular tasks and eventually merged into their parent task when complete. Each task is represented by a VCS branch, and has an initial commit that creates the task within the overall project. This initial commit can be used to track which parent branch the task branched off from.

A parent task can contain one or more child tasks, each of which represents an independent unit of work (whether that is a feature or set of features). The VCS branch topology expresses dependencies between two different tasks (a parent branch depends on all its child branches).

While most tasks have a single parent, technically a VCS branch can be spawned from a merge commit of multiple parents. This is fully supported: branch merges cause the overall project task dependencies to form a DAG, effectively allowing tasks that are linked from multiple places in the overall work tree.

Subtasks are similar to tasks, however they must be attached to a single task, and their development takes place directly in this task's VCS branch. Subtasks are atomic, and cannot contain further tasks or subtasks. Subtasks typically represent a workflow of individual steps needed to produce a single deliverable unit of work. A task is eligible for merging when all its subtasks (and child tasks) are complete.

Each self-contained project has a single main branch which contains the published code, and all development happens by splitting off feature branches that represent units of work to be done, merging them into the parent branch when the unit of work is complete. Thus the parent branch gradually becomes more complete as more of its child branches are merged. When a given parent branch has no remaining child branches, the parent branch is eligible for merging into its own parent, or new child branches can be created to add more work on the parent branch.

Key to the branching model is the notion of task context. Each branch has its own local task context, and has a reference to its parent branch that allows the child branch to read the parent branch's context. This can be traced arbitrarily far back to the top-level main branch. This means that all child branches will have access to the whole chain of parent context, so they are aware of where they stand in the overall project plan. 

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
- [-] [task/ea434dde-authentication](.tt/task/ea434dde-authentication.md) Implement user authentication
  - [x] [task/a4048c0f-email-signup](.tt/task/a4048c0f-email-signup.md) Allow user creation with email address
  - [-] [task/8cf8d966-add-oauth-flow](.tt/task/8cf8d966-add-oauth-flow.md) Integrate OAauth2 signin flow
    1. [x] [subtask/c10103b7-research-oauth-flow](.tt/subtask/c10103b7-research-oauth-flow.md) Research SSO auth flow
    2. [-] [subtask/3ddc3c2f-determine-sso-providers](.tt/subtask/3ddc3c2f-determine-sso-providers.md) Determine supported SSO providers
    3. [ ] [subtask/9fdbbd60-plan-feature](.tt/subtask/9fdbbd60-plan-feature.md) Plan feature
    4. [ ] [subtask/8961d5b1-write-e2e-tests](.tt/subtask/8961d5b1-write-e2e-tests.md) Write end-to-end tests
    5. [ ] [subtask/7702ec93-implement-feature](.tt/subtask/7702ec93-implement-feature.md) Implement feature
    6. [ ] [subtask/34a0507c-review-implementation](.tt/subtask/34a0507c-review-implementation.md) Review feature implementation
    7. [ ] [subtask/6369ad14-update-docs](.tt/subtask/6369ad14-update-docs.md) Update documentation
    8. [ ] [subtask/48c3fa01-update-context](.tt/subtask/48c3fa01-update-context.md) Update parent task context
  - [ ] [task/ef19c63e-forgotten-password](.tt/task/ef19c63e-forgotten-password) Implement 'forgotten password' signin
- [ ] [task/4613e4c8-landing-page](.tt/task/4613e4c8-landing-page.md) Build landing page
- [ ] [task/cdf2d632-pricing-page](.tt/task/cdf2d632-pricing-page.md) Build pricing page
```

The second component to project context is individual task files. Each file pertains to one specific task and it gives the context for that task. Metadata is stored in Markdown frontmatter, including the one-line task summary, the task status, a full task description encoded as a JSON string, a list of labels used to categorize the task, and a list of any subtasks contained within the task.

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

Example of a task file for an in-progress task (`.tt/task/8cf8d966-add-oauth-flow.md`):

```markdown
---
title: Integrate OAuth2 signin flow
status: IN-PROGRESS
description: "Users should be able to sign into the application from a variety of providers via a Single-Sign-On (SSO) process.\n\n\The list of providers should be extensible and configurable via environment variables.\n\nSupported providers are TBD."
label: back-end
label: auth
subtask: [x] subtask/c10103b7-research-oauth-flow
subtask: [-] subtask/3ddc3c2f-determine-sso-providers
subtask: [ ] subtask/9fdbbd60-plan-feature
subtask: [ ] subtask/8961d5b1-write-e2e-tests
subtask: [ ] subtask/7702ec93-implement-feature
subtask: [ ] subtask/34a0507c-review-implementation
subtask: [ ] subtask/6369ad14-update-docs
subtask: [ ] subtask/48c3fa01-update-context
---
- OAuth2 spec: https://oauth.net/2/
- Relevant project source files:
  - `docs/auth`
  - `src/views/login`
```

While working on the task, context can be added to this task file in markdown format. This context can be used as a 'scratch pad' to record anything that could be useful during implementation of the task. Importantly however, only the current task's task file, and the task file of any immediate parent tasks are writable. All other task files are considered read-only. This maintains focus on the current task context, and prevents task context that relates to one task leaking into other tasks. Note that parent task files are only writable from within a child task in order to persist a context summary from the child task to the parent task at the point the child task is merged.

At the point of merging, the task file is updated to a 'done' state, and the task file can no longer be modified: future changes must be created as a new ticket. Task files for completed tasks remain in the repository for future records, however subtask files are considered to be ephemeral context and are only present within the branch for the task they relate to. At the point a task is merged, any subtask files are deleted from its branch.

## Implementation details

### Tech stack

Due to the inherent branching necessary, the `jj` (Jujutsu) tool will initially be used as the backing store, with git support potentially added further down the line.

As far as possible, the VCS will be used as the source of truth for all relations between tasks, storing the project dependency DAG via branches, with fast-forward commits representing simple parent/child task relations and merge commits representing tasks with multiple parents.

Importantly, the todo list itself is not persisted anywhere, rather it is derived entirely from the VCS branch structure and the contents of the task files.

This has the consequence that tasks cannot be reordered within their parent: initially there will be no support for defining the order of child tasks within a parent (tasks will displayed in order of task file creation commit time).

#### Metadata storage

Task files themselves for ongoing tasks are only present within their respective branches. This means that when generating the overall todo list, the task file contents must be retrieved from all the respective branches.

Within a task branch, the task file is referenced via a `TASK.md` symbolic link in the repository root directory (e.g. `./TASK.md -> .tt/task/8cf8d966-add-oauth-flow.md`)

When retrieving task metadata from the task file frontmatter, only the most recent state of the task file will be considered; all former revisions are ignored. This has the consequence that the change history of a task can be tracked by introspecting the revision history of the task file.

#### Merging completed tasks

Completing a task entails creating a commit with the following changes:

- Update the task file status on the child branch to 'DONE'
- Remove all subtasks from the task file and delete their respective task files
- Update the parent task file with any context relevant to the parent task

The child branch is then merged into the parent branch, ignoring the conflicting change to the `TASK.md` symbolic link from the child branch to prevent clobbering the parent task file.

After merging the child branch, the parent's tree will include the completed child task file, as well as any other completed descendant task files which had already been merged into the child branch.

Tasks cannot be marked as completed if they have one or more outstanding child tasks.

### Generating the overall todo list

To generate the overall todo list, the tool must enumerate all active task branches, then merge the active branch's primary task file with the task files of all completed tasks.

#### Detailed algorithm

For a given project root branch, e.g. `main`:

1. Enumerate task branches and the branch tree

  - **List branches** that represent tasks (e.g. names like `task/<id>-<slug>`).
  - **Resolve parents**: For each such branch, use the VCS (e.g. jj's revision parent / merge parents) to get the parent revision(s). Map those revisions to branches (e.g. which branch has that revision in its history or as its tip).
  - **Build the task DAG**: Root = `main`. Each task branch is a node; its parent node(s) are the branch(es) it was created from (or merged into). That gives you the tree/DAG of tasks under `main`.

  So at this stage you have: "all task branches" and "each task's parent(s) in the tree."

2. For each task, choose where to read its task file

  For every task branch **T**:

  - **Merged (done)**  
    The task's file was merged into its parent, so it exists on the **parent branch** at that parent's current revision.  
    → **Read** `.tt/task/<T>.md` **from the parent branch**.

  - **Not merged (ongoing)**  
    The file exists only on **T**.  
    → **Read** `TASK.md` **from the task branch T**.

  "Merged" can be implemented as: at the parent branch's tip (or the merge-base with **T**), does the path `.tt/task/<T>.md` exist? If yes → merged → read from parent. If no → read from **T**.

  So you get one "canonical" task file per task, from either the parent or the task branch.

3. Load metadata and subtasks

  - For that chosen revision (parent or **T**), parse the task file metadata from **frontmatter** (title, status, labels, subtask list).
  - Resolve **subtasks** the same way: subtask files live under `.tt/subtask/<id>.md`. They exist only on the **same branch as the task** (and are ephemeral, only existing on active task branches). So for each subtask, read from the **task branch T**.

  That gives you, for each task: summary, status, link, and ordered list of subtasks with their statuses.

4. Order siblings and flatten to a list

  - **Order** child tasks under the same parent (e.g. by task-file creation time on the parent, or by commit time, per your "no reorder" rule).
  - **Walk the tree** from `main` downward (e.g. depth-first): at each level, emit the parent task line, then recurse into its children with one more indent level, then continue with the next sibling. Subtasks are emitted under their task (e.g. numbered list under that task's bullet). Tasks with multiple parents will appear multiple times in the tree.

5. Emit the markdown

  For each task (and subtask) line, output:

  - Checkbox from status: `[ ]` / `[-]` / `[x]`
  - Link: `[task/<id>-<slug>](.tt/task/<id>-<slug>.md)`
  - Summary (title from frontmatter)

  Indentation reflects hierarchy (task → child task → subtasks), with subtasks expressed as numbered lists.

#### End-to-end flow (summary)

```text
main (root)
  → enumerate task branches + parent pointers
  → build task DAG (who is child of main, who is child of whom)
  → for each task node:
       if .tt/task/<id>.md exists on parent → merged → read task file from parent
       else → ongoing → read task file from task branch
       load subtask list from task branch (if still present)
  → sort siblings (e.g. by creation)
  → walk tree depth-first, emit checkbox + link + title per task/subtask
  → output markdown
```

So: **completed** tasks contribute to the list by reading their (merged) task file from the **parent branch**; **ongoing** tasks by reading from the **child branch** only.

### Generating the 'focused' todo list for the current task

A more efficient algorithm can be used to generate the todo list for just the current task and its direct ancestor tasks (walking the branch tree backwards from the current branch).

This can be useful for establishing context within the overall project without pulling in unnecessary detail.

### User workflow

The standard workflow proceeds as follows:

1. User initializes a todo-tree project via `tt init <path-to-repo> <path-to-virtual-project-folder>`
  - script checks that the repository's working directory is clean, and that there exists no `.tt` directory in the repository root directory
  - script creates an directory at `<path-to-virtual-project-folder>`; this will contain the various workspace checkouts
  - script creates a symbolic link at `<path-to-virtual-project-folder>/HEAD` which (initially) references the repository directory. This symbolic link will be automatically be updated to the most recently checked-out task whenever the user checks out a task, serving as a 'quick link' to the current development branch.

2. User creates a new task entry via `tt new [--parent <parent-task-id> [--parent <parent-task-id>...]] [--label <label> [--label <label>...]] [--id <task-id>] [--summary <summary>] [--description <description>]`
  - script checks that the current working directory is clean
  - script prompts user for task summary, autosuggested branch name, and description if none were provided
  - script locates the parent branch(es) via the provided parent task ID, defaulting to the current branch (if the parent branch is not itself a task branch, it will be used as the project root)
  - a new branch is created for the task, at the parent commit (if multiple parent branches were specified, this will be a merge commit).
  - a new commit is created on the newly-created task branch with the following contents:
   - a new task file in `.tt/task/<id>.md` containing the frontmatter header for the task's metadata (with `status: TODO`)
   - a `./TASK.md -> .tt/task/<id>.md` symbolic link. 

3. User starts working on a task via `tt checkout <task-id>`
  - script checks that the current working directory is clean
  - script verifies that the task branch has been created within the repository, returning an error if not
  - if the task branch's task file has `status: TODO`:
    - script creates a new jj workspace within the virtual project folder that references the task branch
    - script runs `.tt/hooks/setup` (project-specific setup script) within the task's worktree directory
    - script updates task file `status: IN-PROGRESS`
  - script updates the `HEAD` symbolic link within the virtual project folder to reference the task's jj workspace directory

4. User works on the task in the current branch, committing changes on the branch and accumulating relevant task context in `./TASK.md`

5. User finishes working on a task via `tt checkin`
  - script checks that the current working directory is clean and that the current branch is a task branch
  - script diffs with the parent task branch and verifies that the only modified `.tt/task` files are the current task file and (optionally) the parent task file
  - script runs `.tt/hooks/pre-checkin` within the current task's worktree directory
  - script updates task file to `status: DONE` and removes any subtask metadata
  - script removes any subtask task files
  - script locates the parent task worktree (creating and initializing if necessary) runs `.tt/hooks/pre-receive`, merges the child branch into the parent worktree, runs `.tt/hooks/post-receive`. If there is no parent task (i.e. the task is a direct child of the root branch), it merges directly into the parent branch.
