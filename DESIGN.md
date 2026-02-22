# Design document: task-tree

task-tree (`tt`) is a CLI tool for task tracking and context management within complex software development projects. It combines lightweight in-repository task tracking with structured task context management, using the version control system as a backing store.

---

## 1. Overview

task-tree combines lightweight in-repository task tracking with straightforward, structured task context management. The tool uses the version control system as the backing store: the project's current to-do state is represented as a tree structure, with the full scope of work expressed as tasks that can be subdivided and eventually merged back into their parents.

**Branching workflow.** Each task is represented by a VCS branch and has an initial commit that creates the task in the project; that commit records which parent branch the task branched off from. A parent task can contain one or more child tasks, each an independent unit of work (e.g. a feature or set of features). The VCS branch topology expresses dependencies (a parent branch depends on all its child branches). Tasks are attached to their parent via the parent task file's `subtask:` frontmatter; the order of these entries defines the order of child tasks. Tasks have their own VCS branch and can have arbitrarily deeply nested children.

**Tree constraint.** The project task graph must form a **tree**: each task has exactly one parent. DAG use cases (multiple parents referencing the same child task) are not allowed; the tool notifies the user and refuses to make changes when it encounters a task with multiple parents. Work is organized under **projects**, which contain **tasks**. Each project is the root of a separate task tree (effectively multiple sub-projects in the same workspace). All development happens by splitting off task branches from a parent (project or task branch) and merging them back when the unit of work is complete. The parent branch gradually becomes more complete as child branches are merged. When a parent has no remaining child branches, it is eligible to be merged into its own parent(s) or to have new child branches created. A task is eligible for merging when all its child tasks are complete.

**Task context.** Each branch stores its own local task metadata and context in a version-controlled **task file** and can introspect the task hierarchy to read parent context, traceable back to the enclosing project. Child branches therefore have access to the whole chain of parent context and can see where they stand in the overall project plan.

The overall project state can be determined based on two artifacts: (1) a **high-level project to-do list** — a derived markdown listing of all tasks, grouped by project (and optionally a "detached" section for orphaned tasks), with nested bullets showing status, links to task files, and summaries; (2) **individual task files** — one per task, with metadata (title, status, description, labels, child list) in frontmatter and a free-form body used as a scratch pad during implementation. The todo list is not stored separately; it is derived from project branches, task hierarchy, and task file contents. See §2 for source of truth and writability rules, §4 for exact data formats, and §9 for the standard user workflow.

---

## 2. Concepts and model

### Branching model

Tasks are represented by VCS branches. A parent task can have one or more child tasks; each child is an independent unit of work with its own branch. Parent/child relationships are expressed by the parent task file's `subtask:` frontmatter; the order of entries defines the order of children. The project task graph must form a **tree**: each task has exactly one parent, except for project tasks, which have no parents. DAG use cases (multiple parents referencing the same child task) are not allowed; on encountering a task with multiple parents, the tool notifies the user and refuses to make changes. Multiple **projects** are allowed; each is the root of a separate task tree (effectively multiple sub-projects in the same workspace).

A **project** is a parentless root task identified by a different branch/ID prefix. Projects are otherwise identical to tasks: they have their own branch and task file, and they are merge targets for their direct child tasks. A workspace can contain multiple projects. All development happens by splitting off task branches from a parent (project or task branch) and merging them back when the unit of work is complete. The parent branch becomes more complete as child branches are merged. When a parent has no remaining child branches, it is eligible to be merged into its own parent(s) or to have new child branches created. A task is eligible for merging when all its child tasks are complete.

### Source of truth

- **VCS** is the source of truth for: which branches exist (project branches and task branches). The VCS is *not* used to determine parent/child relations between tasks.
- **Parent task file `subtask:` frontmatter** is the source of truth for: **task hierarchy** (which task is whose parent, and the order of children). Task **P** is the parent of task **C** if and only if P's task file lists C in its `subtask:` list. Top-level tasks under a project are those listed in that project's `subtask:` list. Task discovery for the todo list is driven by traversing from projects via `subtask:` entries, not by VCS parent relationships.

The todo list is not persisted; it is derived from project branches, task hierarchy and metadata (frontmatter), and the rule for where each task's file is read (see §7 and Appendix A).

### Task context

Each branch stores its own local task context in a task file and can introspect the hierarchy to read parent context, traceable back to its enclosing project.

Only the **current** task's task file is writable by the user; all other task files (including the parent task file) are read-only. This is enforced by `tt task checkin` (see §6.6): validation fails if the unmerged range contains modifications to any task file other than the current task's. The parent task file is updated only by the tool itself, not by the user: the `Handoff:` and `Merge subtask:` commits (which are created on the parent branch, not the child branch) mark the subtask as done in the parent's frontmatter at checkin time.

---

## 3. Identifiers and naming

- **Task ID:** Each task has a unique identifier of the form `<prefix><slug>-<hex>`, where `<prefix>` is the task prefix (configurable in `.tt/config.toml`, default `task/`), `<slug>` is a human-readable segment, and `<hex>` is an auto-generated 8-character hexadecimal string (e.g. `task/authentication-ea434dde`). The user cannot set the hex suffix; it is generated to avoid collisions. The slug defaults to a value derived from the task summary (e.g. lowercased, hyphenated); the user may override with `tt task create --slug <slug>`. Duplicate slugs are allowed; the 8-hex suffix ensures task IDs are unique.
- **Project ID:** Projects use the same format with a different prefix: `<project_prefix><slug>-<hex>` (e.g. `project/main-app-ea434dde`). The project prefix is configurable in `.tt/config.toml`, default `project/`.
- **Config:** `.tt/config.toml` stores `task_prefix` (default `task/`) and `project_prefix` (default `project/`), both set via `tt workspace init`.
- **Branch and file naming:** Task branches use `task/<slug>-<hex>`; project branches use `project/<slug>-<hex>`. Task files for both are stored in `.tt/task` (e.g. `.tt/task/<slug>-<hex>.md`).

---

## 4. Data formats

### 4.1 Project to-do list

The project to-do list is a nested markdown listing of all tasks, grouped by project. Orphaned tasks (not reachable from any project's subtree) are excluded by default; with **`--detached`**, they are listed under a separate section: `Orphaned tasks:`. Within each section, the task tree is shown as nested bullets. Each bullet contains the following, separated by spaces:

- A GFM checkbox: To-do `[ ]`, In progress `[-]`, Done `[x]`
- A Markdown relative link to the task file, labeled by the machine-readable branch name
- A single-line human-readable task summary

Filtering: **`--project <project-id>`** (repeatable) and **`--detached`**. With no flags, all project sections are shown; orphaned tasks are not shown. With `--detached`, the detached section (if any orphaned tasks exist) is shown. With `--all`, all project sections and orphaned tasks are shown. With `--project project/main-app-ea434dde` (and/or other project IDs), only the listed project section(s) are shown; `--detached` can be combined to also include the detached section.

Example:

```markdown
- [-] [project/main-app-2c382538](.tt/task/main-app-2c382538.md) Main app
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
- [ ] [project/docs-site-28cecfa8](.tt/task/docs-site-28cecfa8.md) Documentation website
- [ ] [project/deployment-f7b045f1](.tt/task/deployment-f7b045f1.md) Deploy to cloud infrastructure

Orphaned tasks:

- [ ] [task/product-research-5fb4e979](.tt/task/product-research-5fb4e979.md) Initial product research
- [ ] [task/auth-mvp-spike-3a2e63d2](.tt/task/auth-mvp-spike-3a2e63d2.md) Auth MVP spike
```

### 4.2 Task file

Each task file pertains to one task and holds its context. Metadata is in Markdown frontmatter: one-line summary (`title`), task status, full description (e.g. JSON string), labels, and child tasks via `subtask:` entries. The order of `subtask:` entries defines the display order of children in the todo list. The body is free-form markdown used as a scratch pad during implementation.

Example — task not yet started (`.tt/task/pricing-page-cdf2d632.md`):

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

Example — in-progress task (`.tt/task/add-oauth-flow-8cf8d966.md`):

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

At merge time, the parent task's frontmatter is updated with the completed child (e.g. `subtask: [x] <task-id> [<task-title>]`). The user may request full removal of the child task from the parent branch using `tt task delete` (or `tt task checkin --delete`, which runs the normal checkin and then delegates to `tt task delete`). This removes the child task file and its `subtask:` entry from the parent's frontmatter entirely, making the task invisible in the todo list. If `--delete` is not used, the task file remains in the repository and the `subtask: [x]` entry is preserved.

### 4.3 Metadata storage and TASK.md

Task files for ongoing tasks exist only on their respective branches; when generating the overall todo list, the task file contents must be retrieved from all the respective branches. Within a task's own branch, the task file is referenced via a `TASK.md` symbolic link in the repository root (e.g. `./TASK.md -> .tt/task/add-oauth-flow-8cf8d966.md`). When retrieving task metadata from frontmatter, only the most recent state of the task file is considered; all former revisions are ignored. Change history for a task's metadata can be tracked via the revision history of the task file.

The tool uses **jj (Jujutsu)** initially as the backing store; git support may be added later. The tool keeps the VCS in sync with the current task or branch (e.g. after `tt task checkout` and `tt task checkin`) so the working copy reflects the current task context.

---

## 5. Commands

The canonical form is `tt <entity-type> <command>`, e.g. `tt workspace init` or `tt task checkout`. Aliases:

| Alias | Canonical |
|-------|-----------|
| `tt init` | `tt workspace init` |
| `tt switch` | `tt workspace switch` |
| `tt create` | `tt task create` |
| `tt checkout` | `tt task checkout` |
| `tt checkin` | `tt task checkin` |
| `tt status` | `tt task status` |
| `tt show` | `tt task show` |
| `tt propagate` | `tt task propagate` |
| `tt checkpoint` | `tt task checkpoint` |
| `tt complete` | `tt task complete` |
| `tt delete` | `tt task delete` |
| `tt list` | `tt task list` |
| `tt add-context` | `tt task add-context` |

### 5.1 Workspace

- **`tt workspace init <path-to-repo> <path-to-virtual-project-folder> [--task-prefix <prefix>] [--project-prefix <prefix>]`** — Initialize a task-tree project. Creates the virtual workspace directory, `.tt/config.toml` (with optional task prefix and project prefix), and a `HEAD` symlink that initially points to the repo and is later updated to the most recently checked-out task workspace (serving as a quick link to the current development context). Requires a clean working directory and no existing `.tt` in the repo root. See §9 step 1 and §6.2 (HEAD symlink).

- **`tt workspace switch <task-id> [--worktree=<path>] [--force]`** — Update the virtual project's `HEAD` symlink to point to an existing worktree for the given task or project. Unlike `tt task checkout --switch`, this command does not create worktrees, switch VCS branches, or update task status; it only redirects `HEAD`. Refuses if no worktree exists for the task (the user must run `tt task checkout --worktree` first). If multiple worktrees exist for the task, `--worktree=<path>` is required to disambiguate. Refuses if the workspace currently pointed to by `HEAD` has uncommitted changes, unless `--force` is provided. Runs `pre-checkout` and `post-checkout` hooks; hook env vars `TT_PREVIOUS_TASK_ID`/`TT_PREVIOUS_TASK_BRANCH` reflect the task that `HEAD` was pointing to before the switch. Output is the same confirmation as `tt task checkout`. See §6.2.

### 5.2 Task

- **`tt task create [--parent <parent-task-id> | --project [--target <commit-rev>]] [--slug <slug>] [--title <title>] [--description <description>] [--label <label> ...] [--propagate [--rebase | --merge] [--shallow] [--force]] [--force]`** — Create a new task or project. With `--parent` (default: current branch): creates a commit on the parent's branch that both creates the new task file (with `status: TODO`) and registers `subtask: [ ] <task-id>` in the parent's task file; the child branch is forked as an empty commit from this updated parent tip. The `TASK.md` symlink is created at first checkout. With `--project` (mutually exclusive with `--parent`): creates a parentless project using the project prefix; the project branch forks from `--target` if specified, else the current revision. Prompts for summary/description if not provided. With `--propagate`, propagates the parent's new commit to its existing descendant branches after creation (equivalent to running `tt task propagate --from <parent>` with any given flags); supports `--rebase | --merge` (strategy; default rebase), `--shallow` (direct children only), and `--force` (proceed despite conflicts). With `--force` (outside of `--propagate`), overwrites if the child branch already exists. See §6.1.

- **`tt task checkout <task-id> [--worktree [=<path>] [--switch]] [--force]`** — Switch to the given task branch. With `--worktree`, uses or creates a dedicated jj workspace for that task; otherwise uses the closest ancestor task workspace or the current workspace. Refuses if the target workspace has local changes unless `--force`. Updates task status to IN-PROGRESS if TODO, runs `setup` hook when creating a new worktree. Without `--worktree`, always updates the virtual project's `HEAD` symlink; with `--worktree`, only updates `HEAD` if `--switch` is also provided (`--switch` is only valid with `--worktree`). See §6.2.

- **`tt task checkpoint [--message <msg>]`** — Record the current state and advance the task bookmark. If the working copy is empty, moves the bookmark to the working copy's parent commit (and updates that commit's description if `--message` is given). If the working copy has pending changes, creates a new commit from those changes (`jj commit`, using `--message` as the description) and moves the bookmark to it. The target commit must be a strict descendant of the current bookmark tip, unless `--force` is specified. Prints a short confirmation on success. See §6.3. Hooks: **pre-checkpoint**, **post-checkpoint**.

- **`tt task complete [--force]`** — Mark the current task as done. Creates a `Complete task: <title> (<task-id>)` commit on the task branch that sets `status` to `DONE` in the task file, and advances the task bookmark to this commit. Requires a clean working copy and all child tasks to be done (every `subtask:` entry marked `[x]`) unless `--force` is specified. See §6.4. Hooks: **pre-complete** (blocking), **post-complete** (optional).

- **`tt task checkin [--context <markdown>] [--complete] [--rebase | --merge] [--force] [--delete] [--target <branch>]`** — Merge the current task branch into its parent (or, for a project task, into the branch specified by `--target`). Supports **partial checkins** (task status `IN-PROGRESS`; shares work-in-progress with the parent) and **complete checkins** (task status `DONE`; marks the task finished). Always creates a **handoff commit** (child bookmark does not advance) and merges it into the parent as `Merge subtask: <title> (<task-id>)`. If the task's `status` is `DONE`, the handoff also marks the corresponding `subtask:` entry as `[x]` in the parent's frontmatter, and after the merge the user is switched to the parent worktree. With `--complete`: first runs `tt task complete` if the task is not already `DONE`, then proceeds with checkin. With `--context <markdown>`, appends a summary section to the parent task file body. With `--delete` (requires task `status: DONE`): after the normal checkin completes, delegates to `tt task delete` to remove the child task file and `subtask:` entry from the parent branch (two separate commits on the parent branch). Runs validation (see §6.6); with `--rebase`/`--merge`, first propagates from parent and bails on conflict unless `--force`. Project tasks must specify `--target`; regular tasks cannot use `--target`. See §6.5 and §6.6.

- **`tt task add-context [-m <msg>] [--no-timestamp]`** — Append a free-form context block to the current task file body, without creating a commit. The block is formatted as `## YYYY-MM-DD HH:MM\n\n<text>\n\n---`. If `--message` is not provided, opens an editor pre-filled with the timestamp heading. With `--no-timestamp`, omits the timestamp heading from both the inline message and the editor template. Aborts if the resulting message is empty. Modifies the task file directly in the working copy.

- **`tt task list [--project <project-id>]... [--detached] | [--all]`** — Generate and print the full project todo list to stdout. Tasks are grouped by project; orphaned tasks are excluded by default. Optional `--project`, `--detached` and `--all` filter which sections are shown. Output format is the markdown described in §4.1. See §7.1 and Appendix A.

- **`tt task list --focus`** — Generate and print the focused todo list (current task and its direct ancestors only) in the same markdown format. See §7.2 and Appendix A.

- **`tt task status`** — Show the current task and branch, and the status of all direct child tasks (the `subtask:` entries in the current task file's frontmatter).

- **`tt task show [<task-id>]`** — Show the full context of the current task or the given task: frontmatter and body of that task's task file. Output to stdout only.

- **`tt task propagate [--from=<parent-id>] [--to=<descendant-id>]... [--rebase | --merge] [--shallow] [--force]`** — Update descendant task branches so their base is the parent's current tip. Default is to rebase all descendants of the current task; `--merge` merges instead; `--shallow` updates only direct children; `--force` proceeds despite rebase/merge conflicts. Preconditions: clean WC, no merge commits at tip, no untracked changes in affected worktrees. See §6.8.

- **`tt task reorder <task-id> <modifier>`** — Reorder a direct child task. Modifier is one of `--up`, `--down`, `--after <other-task-id>`, or `--before <other-task-id>` (mutually exclusive). Fails if the reorder is impossible (e.g. already first with `--up`, or `<other-task-id>` is not a sibling). See §6.7.

- **`tt task delete [<task-id>] [--force]`** — Remove a task and its entire descendant subtree from the parent branch. Collects the full subtree via union traversal (reads subtask lists from both each task's own branch and the parent branch's copy at every level). Creates a single `Remove subtask: <title> (<task-id>)` commit on the parent branch that removes the top-level `subtask:` entry and all descendant task files present on that branch. After the commit, deletes all bookmarks in the subtree (`jj bookmark delete`). Dedicated workspaces are forgotten from jj; files left on disk with a warning. Defaults to the current branch if no `<task-id>` is given. Requires task `status: DONE` unless `--force` is specified (which also skips the clean working-copy check). Aborts if no parent is found. See §6.9.

---

## 6. Task and branch operations

### 6.0 Branch topology and commit conventions

Each task and project branch follows a structured lifecycle of named commits. The table below describes each commit type, the command that creates it, and its purpose:

| Commit description | Command | Purpose |
|--------------------|---------|---------|
| `Create workspace: <desc>` | `tt workspace init` | Adds `.tt/config.toml` to the base branch |
| `Create project: <title>` | `tt task create --project` | Creates the project task file on the project branch |
| `Begin task: <title> (<task-id>)` | `tt task checkout` | First checkout: creates `TASK.md` symlink and sets status → `IN-PROGRESS`; advances task bookmark |
| `Create task: <child-title> (<task-id>)` | `tt task create` | On the parent branch: creates child task file and registers `subtask: [ ] <task-id>` in the parent file; parent bookmark advances |
| `Describe task: <title> (<task-id>)` | `tt task create` | First commit on the child branch: adds description frontmatter to the child task file; task bookmark initialised here |
| `Checkpoint: <message> (<task-id>)` or `Checkpoint: <task-title> (<task-id>)` | `tt task checkpoint` | Advances the task bookmark to the current working state |
| `Complete task: <title> (<task-id>)` | `tt task complete` | Sets status → `DONE` in the task file; final task bookmark advance |
| `Handoff: <title> (<task-id>)` | `tt task checkin` | Off-mainline merge-source commit; child bookmark does **not** advance to this commit |
| `Merge subtask: <title> (<task-id>)` | `tt task checkin` | Empty merge commit on the parent branch; parent bookmark advances |
| `Remove subtask: <title> (<task-id>)` | `tt task delete` | On the parent branch: removes child task file and `subtask:` entry from parent frontmatter; parent bookmark advances |

**Branch lifecycle diagram.** The diagram below shows the commit graph for a project `project/P` containing one task `task/T`, from workspace initialisation through to task completion. Commits are shown newest-first (top) to oldest (bottom), matching `jj log` output. `↑` marks where the named bookmark sits after each commit; `├─╮` is a branch fork (task branches from parent); `○─╯` is a merge (handoff merges into parent).

```
(base):
  ○  Create workspace: <desc>
     ↑ base

project/P:
  ○  Checkpoint: ...                                 (continued project work, optional)
  │  ↑ project/P
  ○  Merge subtask: <T-title> (task/T)               ← tt task checkin
  ├─╮
  │ ○  Handoff: <T-title> (task/T)                   ← tt task checkin  (NOT on mainline)
  │ ○  Complete task: <T-title> (task/T)             ← tt task complete  (status → DONE)
  │ │  ↑ task/T  (final bookmark position)
  │ ○  Checkpoint: ...                               ← tt task checkpoint
  │ │  ↑ task/T
  │ ○  Begin task: <T-title> (task/T)                ← tt task checkout
  │ │  ↑ task/T
  │ ○  Describe task: <T-title> (task/T)             ← tt task create  (child branch init)
  │    ↑ task/T  (initial bookmark position)
  ├─╯
  ○  Create task: <T-title> (task/T)                 ← tt task create  (on parent branch)
  │  ↑ project/P
  ○  Checkpoint: ...                                 (optional project work)
  │  ↑ project/P
  ○  Begin task: <title> (project/P)                 ← tt task checkout
  │  ↑ project/P
  ○  Create project: <title>                         ← tt task create --project
     ↑ project/P  (initial bookmark position)
```

**Partial checkin.** When `tt task checkin` is called while the task is still `IN-PROGRESS`, a handoff is created but the child bookmark does not advance and the task is not marked done. The parent absorbs the work-in-progress; the task continues from its current bookmark tip. A subsequent checkin (after more work, or after `tt task complete`) produces another handoff from the same task. The graph below shows one partial checkin followed by a complete checkin:

```
project/P:
  ○  Merge subtask: <T-title> (task/T)               ← tt task checkin  (complete)
  ├─╮
  │ ○  Handoff: <T-title> (task/T)                   (NOT on mainline)
  │ ○  Complete task: <T-title> (task/T)             ← tt task complete
  │ │  ↑ task/T  (final)
  │ ○  Checkpoint: ... (more work)
  │ │  ↑ task/T
  ○─╯  Merge subtask: <T-title> (task/T)             ← tt task checkin  (partial)
  ├─╮
  │ ○  Handoff: <T-title> (task/T)                   (NOT on mainline)
  │ ○  Checkpoint: ...
  │    ↑ task/T  (bookmark stayed here during partial checkin)
  ├─╯
  ○  Create task: <T-title> (task/T)                 ← tt task create
  ...
```

Note that `Checkpoint:` at the bottom of the task/T arm in the partial diagram is the common ancestor of both the subsequent `Checkpoint: (more work)` commits (task continues from this point) and the partial `Handoff:` (which branches off from the same commit).

---

### 6.1 Task creation (`tt task create`)

**With `--parent`:** The tool creates a commit **on the parent task's branch** (regardless of which branch is currently checked out) that both creates the new task file (with `status: TODO`) in `.tt/task/` and adds `subtask: [ ] <task-id>` to the parent task file, described as `Create task: <title> (<task-id>)`. The parent bookmark is advanced to this commit. The child task's branch is then initialised with a `Describe task: <title> (<task-id>)` commit that adds the description frontmatter; the task bookmark is set to this commit. The `TASK.md` symlink is created when the task is first checked out (see §6.2). After task creation, if the working copy was already on the parent branch, it is left at the updated parent branch tip; otherwise it is restored to its original position.

Because the parent task file is modified, sibling (and descendant) branches may need to be updated to avoid conflicts at checkin. The optional `--propagate` flag runs `tt task propagate --from <parent>` after creating the task; it accepts `--rebase | --merge` (propagation strategy; default rebase), `--shallow` (direct children of the parent only), and `--force` (proceed despite conflicts). If the named child branch already exists, the tool notifies the user and refuses unless `--force` is specified.

**With `--project`:** The tool creates a parentless project task using the project prefix. The project branch is created from `--target <commit-rev>` if specified, else the current revision (any branch). The tool refuses to proceed if the target revision already exists within a task tree. No parent task file is modified. The project task file is created on the project branch.

### 6.2 Checkout behavior (`tt task checkout`)

With **`--worktree`**: the tool ensures the task is checked out in its own jj workspace (creating it if necessary). Without `--worktree`: the tool checks out the task branch in the closest ancestor task workspace (if any), or the current workspace if no ancestors have their own workspace.

If the target workspace's working copy is an ancestor task's workspace (not the task's own) and contains changes, the tool alerts and refuses unless `--force` is provided. For subsequent checkouts of the same task, the default is to use an existing workspace for that task if present. If multiple workspaces exist for a task branch, the user must specify `--worktree=<path-to-workspace>`; this form can always be specified if the user wants to control the path of the workspace. The `HEAD` symlink in the virtual project folder is updated to the task's workspace whenever a task is checked out, **except** when `--worktree` is used without `--switch`: in that case the worktree is created or updated but `HEAD` is not changed. Pass `--switch` (only valid with `--worktree`) to also update `HEAD` to the new worktree.

### 6.3 Checkpoint (`tt task checkpoint`)

`tt task checkpoint` records the current state of work and advances the task bookmark. It always creates a new commit, even if the working copy is empty.

**Commit message:** `Checkpoint: <message> (<task-id>)`. The `<message>` part comes from `--message` if provided; otherwise the user is prompted to enter it in an editor (see §6.3.1 below).

**Commit flow:** Always `jj commit -m "<full-message>"` regardless of whether the working copy has pending changes. This works for both empty and non-empty WC and always leaves a clean open working copy on top.

#### 6.3.1 Interactive message editing

When `--message` is not provided, `tt task checkpoint` opens an editor for the user to enter the `<message>` portion of the commit message. This mirrors `git commit` behaviour, using an ephemeral temporary file to store the in-progress prompt.

**Editor selection:** `$TT_EDITOR` → `$GIT_EDITOR` → `$VISUAL` → `$EDITOR` → `"vi"` (first non-empty value wins). The editor executable receives the temporary file path as its only argument.

**Messge editor template (written to temporary file):**

```
<task-title>

# Task: <task-title> (<task-id>)
# An empty message cancels the checkpoint.
```

The file is opened in the resolved editor. Once the editor exits:

- **Editor exits non-zero:** Print an error to stderr and exit 1. No VCS operation is performed.
- **Editor exits zero:** Strip all lines beginning with `#`, then trim leading/trailing whitespace. If nothing remains, print `Checkpoint cancelled.` to stderr and exit 1. Otherwise use the stripped text as `<message>`.

**Preconditions** (all checked before any VCS operation; any failure aborts the command):

- Current branch is a task or project branch (verified via `resolve_current`).

**Behavior:** After the operation, print a short confirmation, e.g.:

```
Checkpoint: task/foo-abc12345 → <commit-id>
```

**Hooks:** Runs **pre-checkpoint** (blocking) before any VCS operation, and **post-checkpoint** (optional) after success. Both run in the current task worktree. See §8.

### 6.4 Complete (`tt task complete`)

`tt task complete` marks the current task as done. It creates a `Complete task: <title> (<task-id>)` commit on the task branch that updates `status` from `IN-PROGRESS` to `DONE` in the task file, and advances the task bookmark to this commit.

**Preconditions** (all checked before any VCS operation; any failure aborts the command):

- Current branch is a task or project branch.
- Working copy is clean.
- All child tasks are done: every `subtask:` entry in the current task file is marked `[x]`. `--force` bypasses this check.

**Behavior:** Updates `status: DONE` in the task file frontmatter, describes the commit as `Complete task: <title> (<task-id>)`, advances the task bookmark, and leaves a clean working copy on top. Once a task is marked `DONE`, `tt task checkin` will automatically mark the corresponding `subtask:` entry in the parent's frontmatter as `[x]` when the handoff is created (see §6.5).

**Hooks:** Runs **pre-complete** (blocking) before any VCS operation, and **post-complete** (optional) after success. Both run in the current task worktree.

### 6.5 Checkin (merging task work into the parent)

`tt task checkin` merges the current task branch's work into its parent branch. It supports two modes based on the task's current `status`:

- **Partial checkin** (task status `IN-PROGRESS`): Shares work-in-progress with the parent so it can be propagated to siblings, without marking the task as done. The user remains on the child branch to continue working.
- **Complete checkin** (task status `DONE`): Marks the `subtask:` entry as done in the parent frontmatter and switches the user to the parent worktree. Use `tt task complete` (or pass `--complete`) to transition to `DONE` first.

With `--complete`: if the task is not already `DONE`, first runs `tt task complete` (subject to its preconditions, including the incomplete-children check), then proceeds with checkin.

In both modes, with `--rebase` or `--merge`, the tool first propagates from the parent into the current (child) branch; if propagation cannot complete without conflicts, the command bails unless `--force` is used.

**Handoff commit.** `tt task checkin` always creates a **handoff commit** as a child of the current task bookmark commit. The child branch bookmark does **not** advance to the handoff commit; it remains at the current bookmark. The handoff commit is used as the merge source for merging into the parent. Handoff commits are not on the mainline child branch and are ignored during propagation (see §6.8).

The handoff commit contains:

1. `TASK.md` rewritten to point to the parent task's task file (`rm TASK.md && ln -s .tt/task/<parent-slug>.md TASK.md`), resolving the TASK.md conflict with the parent branch.
2. If `--context <markdown>` is provided: a new section appended to the **parent task file's body** in the format:
   ```markdown
   [`<task-id>`](.tt/task/<task-slug>.md) <task-title>

   <markdown>

   ---
   ```
3. If the task's `status` is `DONE`: the corresponding `subtask:` entry in the parent task file's frontmatter updated to `subtask: [x] <task-id>`.

The handoff commit is described as `Handoff: <task-title> (<task-id>)`.

**Merging into the parent.** After the handoff commit is created, the tool locates the parent task worktree (creating and initializing it if necessary) and merges the handoff commit into the parent branch. The resulting merge commit is described as `Merge subtask: <task-title> (<task-id>)`. The parent branch bookmark advances to this merge commit.

**After checkin:**
- **Partial checkin (task status `IN-PROGRESS`):** The user remains on the child branch to continue working. The child bookmark has not moved. The parent now contains the merged handoff commit and sibling branches can be propagated.
- **Complete checkin (task status `DONE`):** The tool switches the worktree to the parent (updates `HEAD` symlink, deletes the child worktree if it was dedicated). If the user's working directory was inside the deleted child path, the tool switches them to the equivalent path under the `HEAD` symlink.

If there is no parent task (the task being merged is a project task), the tool requires `--target <branch>`; it merges the handoff commit into the specified target branch. Merge conflicts in the working copy or other `.tt/` files must be resolved manually; for `TASK.md`, the intended resolution is to keep the parent's version.

### 6.6 Checkin validation

Before attempting any merge, `tt task checkin` performs validation and refuses if any check fails. The **unmerged range** is the set of commits on the child branch that are not yet in the parent's ancestry (commits since the last handoff commit, if any, or all commits on the child branch if no prior checkin has occurred). Checks include:

- Working copy is clean
- Current branch is a task branch (or project branch)
- Current task has exactly one parent, or is a project task with no parents (in which case `--target <branch>` must be specified; regular tasks cannot use `--target`)
- No conflicts with parent (or target branch, for project checkin) once the handoff commit has been applied (unless `--force`), or after the optional pre-checkin propagate step when using `--rebase`/`--merge`
- No modifications to non-editable task files in the unmerged range: only the current task file may be modified by the user. Any changes to any other `.tt/task` file in the unmerged range cause checkin to abort. (The parent task file is updated by the tool itself via the `Handoff:` and `Merge subtask:` commits, which are on the parent branch and are not part of the child's unmerged range.)
- The only change to `TASK.md` in the unmerged range from the child is the symlink pointing to the child's task file, then reverted by the handoff commit

On failure, `tt task checkin` aborts with an error and leaves the repository unchanged. Implementations may add further checks via hooks.

### 6.7 Task reorder

Child tasks are ordered via the current task file's `subtask:` frontmatter. **`tt task reorder <task-id> <modifier>`** reorders a direct child; modifier is `--up`, `--down`, `--after <other-task-id>`, or `--before <other-task-id>` (mutually exclusive).

### 6.9 Delete (`tt task delete`)

`tt task delete` removes a task and its entire descendant subtree from the parent branch. It is the canonical mechanism for purging a task from the project: after this command, the task is no longer discoverable via `tt task list` because its `subtask:` entry is gone from the parent task file.

**Usage:** `tt task delete [<task-id>] [--force] [--worktree=<path>] [--repo PATH] [--workspace-dir PATH]`

If no `<task-id>` is given, the command operates on the current branch.

**Preconditions** (all checked before any VCS operation; any failure aborts unless noted):

- Working copy is clean. Skipped with `--force`.
- Current branch is a task or project branch (when no explicit `<task-id>` is given).
- Top-level task `status` is `DONE`. Skipped with `--force`. (Descendants' status is not checked.)
- Exactly one parent branch is found (via `find_parent_branch`). Parentless tasks (top-level projects with no parent) cannot be deleted this way; the command aborts.

**Behavior:**

1. Locate the parent branch using `find_parent_branch` (same logic as `tt task checkin`).
2. Collect the full descendant subtree via union traversal: for each discovered task, read subtask lists from both (a) the task's own branch and (b) the parent branch's copy of the task file. Union of both is used at every level, recursively, until no new IDs are found.
3. Determine the target workspace using `find_worktrees_for_branch` on the parent branch: 0 found → use main repo workspace; 1 found → use that workspace; 2+ → require `--worktree=<path>`.
4. Run **pre-delete** hook (blocking) in the current worktree.
5. In the target workspace, create a new WC branching from the parent bookmark (`jj new <parent_bookmark>`).
6. Remove the `subtask:` entry for the top-level task from the parent task file's frontmatter.
7. Remove the top-level task file and all descendant task files present on the parent branch (best-effort).
8. Commit: `Remove subtask: <title> (<task-id>)`. Advance the parent bookmark to this commit.
9. Leave a clean open WC in the target workspace (`jj new '@'`).
10. Bulk delete bookmarks: run `jj bookmark delete` for every task in the subtree (root + all descendants). Log a warning for any that cannot be deleted.
11. For each task in the subtree: if a dedicated workspace exists at `<workspace-dir>/<task-id>/`, run `jj workspace forget <name>` to deregister it from jj, but **do not delete the files**. Alert the user that the workspace directory still exists and must be cleaned up manually.
12. Run **post-delete** hook (non-blocking).

**Delegation from `tt task checkin --delete`:** When `tt task checkin` is run with `--delete`, it first performs the normal checkin (handoff + merge commits on the parent branch), then invokes `tt task delete` on the same task. This produces two commits on the parent branch: the `Merge subtask:` commit from checkin, followed by the `Remove subtask:` commit from delete. All subtree bookmarks are deleted after the `Remove subtask:` commit.

**Hooks:** Runs **pre-delete** (blocking) before any VCS operation, and **post-delete** (non-blocking) after success.

### 6.8 Propagate

When the current task branch gains new commits (e.g. after merging a child with checkin or after direct work on the parent), descendant task branches still have the old parent revision as their base. **`tt task propagate`** updates the given descendant branch(es) (by default, recursively) so each is based on the parent's current tip. `--from` defaults to the current task ID; `--to` defaults to all immediate children of the parent. Strategy defaults to **`--rebase`**; **`--merge`** merges the parent into each child instead. **`--shallow`** updates only direct children. **`--force`** proceeds even if propagation produces conflicts.

**Scope:** The parent must be a task branch or a project branch with task-branch children. By default all descendant task branches in the subtree are updated; with `--shallow`, only direct children. Branches are processed in a deterministic order (parent before children) so each branch is rebased or merged onto its parent's already-updated tip.

**Preconditions (all checked before any updates; any failure causes the command to error):** Working copy of the current task is clean. Every branch that would be updated has exactly one parent (no merge commits at tip). No affected worktree may have untracked changes in its working copy. When `--rebase` is used (default), the rebase must apply cleanly for every branch to be updated unless `--force` is specified; with `--force`, the implementation may leave conflict state for the user to resolve. Under jj, conflicts are allowed in the model; no special conflict-failure handling is required beyond this.

**Worktrees:** After updating branch tips, the tool syncs all changed child worktrees to the new commit. The user's current working copy (HEAD) is not switched unless it was one of the updated branches. Propagate does not perform checkin-style merge-range validation (task-file rules for checkin do not apply when updating a child's base).

**Handling partially-checked-in children.** When a child task has been partially checked in (i.e., a handoff commit from the child has already been merged into the parent), the child's earlier commits are already part of the parent's ancestry. Attempting to naively rebase the child bookmark onto the parent would cause a cycle, since the child bookmark's tip would be a descendant of commits already inside the parent's history.

Instead, propagate identifies only the **unmerged range** of the child branch — the commits that are ancestors of the child bookmark but are **not** yet in the parent's ancestry — and rebases only those. Handoff commits are not on the mainline child branch (the child bookmark does not advance to them), so they are not included in this range and do not interfere with the calculation.

Concretely, for a child branch `C` and parent branch `P`:

- **Unmerged range:** `::C ~ ::P` — ancestors of C not yet in P's ancestry.
- **Rebase roots:** `roots(::C ~ ::P)` — the root commits of that range (those whose parents are already in P's ancestry). These are the commits that need to be rebased directly onto P.
- If the unmerged range is empty (the child has no new commits beyond what is already in the parent), the child is considered up to date and is skipped.
- Otherwise, the rebase roots and all their descendants (within the unmerged range) are rebased onto P: `jj rebase -s "roots(::C ~ ::P)" -d P`.

---

## 7. Todo list generation

### 7.1 Full list (summary)

To generate the overall todo list, the tool: (1) enumerates project branches (names matching `<project_prefix><slug>-<hex>`); (2) for each project P, traverses its subtree by reading P's task file and following `subtask:` entries recursively, discovering tasks via top-down traversal; (3) for each discovered task T, determines where to read T's file — **merged** tasks (where a parent branch's owner task file contains `subtask: [x] <T> ...`) are read from that parent branch; **ongoing** tasks are read from T's own branch; tasks deleted via `tt task delete` have no `subtask:` entry and are not discovered; (4) if `--detached` is present, enumerates all task branches and identifies orphaned tasks (not reachable from any project's subtree), adding them to a detached section; (5) filters sections by `--project`/`--detached` if present; (6) walks the tree depth-first, outputting checkbox, link, and title per task in the format of §4.1.

The full step-by-step algorithm is in **Appendix A**.

### 7.2 Focused list (summary)

The focused list shows the current task and its direct ancestors only. The tool resolves the current branch to a task branch T, walks backwards via the frontmatter-defined parent chain to the top-level task, loads each task's file using the same "where to read" rule as the full list (§7.1 / Appendix A), and emits markdown in the same format for this subset with hierarchy preserved.

The detailed steps are in **Appendix A**.

---

## 8. Lifecycle hooks

Hooks are shell scripts or executables under `.tt/hooks/<name>`, one script per hook. They follow the same exit-code convention as Git: exit 0 means the workflow may proceed; non-zero means abort, with stderr shown to the user. If a hook is missing, it is skipped.

Every hook receives at least:

- **TT_WORKSPACE_DIR** — Path to the virtual project root (the directory containing all jj worktrees).
- **TT_WORKTREE_DIR** — Path to the jj workspace directory for the current or affected task (where the hook runs), except where noted below.

| Hook | When | Where | Blocking? | Extra env |
|------|------|-------|-----------|-----------|
| **setup** | When initializing a new worktree for a task (during `tt task checkout`) | New task worktree | Optional (non-blocking so init doesn't fail) | TT_TASK_ID, TT_BRANCH, TT_PARENT_TASK_ID, TT_PROJECT_ID (containing project when in a task; equal to TT_TASK_ID when checking out a project task) |
| **pre-checkout** | Before switching branch in `tt task checkout` | Current (outgoing) worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH (newly-checked-out target), TT_PREVIOUS_TASK_ID, TT_PREVIOUS_TASK_BRANCH (outgoing) |
| **post-checkout** | After successful `tt task checkout` | Checked-out task worktree | Optional | TT_TASK_ID, TT_TASK_BRANCH (newly-checked-out), TT_PREVIOUS_TASK_ID, TT_PREVIOUS_TASK_BRANCH (outgoing) |
| **pre-create** | Before creating task in `tt task create` | Parent task worktree | Yes | TT_PARENT_TASK_ID, TT_PARENT_BRANCH, TT_TITLE, TT_SLUG, TT_DESCRIPTION, TT_LABELS (space-separated; labels with spaces/special chars quoted) |
| **post-create** | After task created in `tt task create` | New task worktree if created, else worktree we end up in | Optional | TT_TASK_ID (new), TT_TASK_BRANCH (new), TT_PARENT_TASK_ID, TT_PARENT_BRANCH; TT_WORKTREE_DIR = that same worktree |
| **pre-checkpoint** | Before `tt task checkpoint` performs any VCS operation | Current task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH, TT_MESSAGE (value of `--message`; empty if not provided) |
| **post-checkpoint** | After `tt task checkpoint` succeeds | Same | Optional | TT_TASK_ID, TT_TASK_BRANCH, TT_COMMIT (the commit the bookmark was moved to), TT_MESSAGE |
| **pre-complete** | Before `tt task complete` performs any VCS operation | Current task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH |
| **post-complete** | After `tt task complete` succeeds | Same | Optional | TT_TASK_ID, TT_TASK_BRANCH, TT_COMMIT (the commit the bookmark was moved to) |
| **pre-checkin** | Before checkin in `tt task checkin` | Child (current) task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH, TT_PARENT_TASK_ID, TT_PARENT_BRANCH |
| **pre-receive** | Before merge applied on parent (during checkin) | Parent task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH (parent), TT_INCOMING_TASK_ID, TT_INCOMING_BRANCH (child being merged) |
| **post-receive** | After merge applied on parent (during checkin) | Parent task worktree | Optional | Same as pre-receive |
| **pre-propagate** | Before `tt task propagate` updates descendants | Current (source) task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH |
| **post-propagate** | After `tt task propagate` completes | Same | Optional | TT_TASK_ID, TT_TASK_BRANCH |
| **pre-delete** | Before `tt task delete` | Current (child) task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH (task being deleted), TT_PARENT_TASK_ID, TT_PARENT_TASK_BRANCH (parent task whose frontmatter is updated) |
| **post-delete** | After `tt task delete` succeeds | Same | Optional | Same as pre-delete |

**Blocking vs optional:** Pre- hooks are blocking: a non-zero exit aborts the command. Post- hooks and **setup** are best-effort: a non-zero exit is relayed to the user but does not abort the workflow, so optional bookkeeping does not fail the operation.

**post-create:** If no new worktree is created, TT_WORKTREE_DIR is the worktree we end up in (e.g. the parent's); TT_TASK_ID and TT_TASK_BRANCH still refer to the new task and its branch.

**TT_LABELS:** Format is space-separated; labels containing spaces or special characters are quoted (implementation detail).

---

## 9. User workflow

The standard workflow:

1. **Initialize** — `tt workspace init <path-to-repo> <path-to-virtual-project-folder> [--task-prefix <prefix>] [--project-prefix <prefix>]`. The tool checks that the repo working directory is clean and there is no `.tt` in the repo root. It creates the virtual project directory, `.tt/config.toml` (task prefix default `task/`, project prefix default `project/`), and a `HEAD` symlink that initially points to the repo and is updated on each checkout. See §5.1 and §6.2.

2. **Create a project** — `tt task create --project [--target <commit-rev>] [--slug <slug>] [--title <title>] [--description <description>] [--label <label> ...]`. The tool prompts for title/description (and autosuggested branch name) if needed, creates the project branch from the `--target` VCS revision if specified, defaulting to the current revision, and creates the project task file. If the target revision itself exists within a task tree, the tool notifies the user and refuses to proceed. See §6.1.

3. **Create a task** — `tt task create [--parent <parent-task-id>] [--slug <slug>] [--title <title>] [--description <description>] [--label <label> ...] [--propagate [--rebase | --merge] [--shallow] [--force]]`. The tool checks the parent's workspace is clean, prompts for summary/description (and autosuggested branch name) if needed, locates the parent branch (default current branch; parent can be a project or task branch). Creates a single commit on the parent's branch that both creates the new task file (with `status: TODO`) and adds `subtask: [ ] <task-id>` to the parent's task file; advances the parent bookmark to this commit. Forks the child task branch as an empty commit from the updated parent tip. The `TASK.md` symlink is created at first checkout. With `--propagate`, it runs `tt task propagate --from <parent>` with any given flags to bring sibling branches up to date with the parent's new commit. See §6.1.

4. **Begin a task** — `tt task checkout <task-id> [--worktree [=<path>] [--switch]] [--force]`. The tool checks the target workspace is clean (or clobbers changes if `--force` is specified), verifies the task or project branch exists, uses or creates the appropriate workspace per §6.2, sets task status to IN-PROGRESS in a new commit if the task status is currently TODO, runs `setup` when initializing a new worktree, and updates the `HEAD` symlink (unless `--worktree` is used without `--switch`). See §6.2.

5. **Work on the task** — User commits changes on the branch and accumulates context in `./TASK.md`. Periodically run `tt task checkpoint [--message <message>]` to create a named `Checkpoint: <message>` commit and advance the task bookmark. See §6.3.

6. **Complete the task** — `tt task complete [--force]`. When work is done, marks the task `DONE` with a `Complete task: <title> (<task-id>)` commit and advances the task bookmark. Requires all child tasks to be done unless `--force`. See §6.4.

7. **Finish the task** — `tt task checkin [--rebase | --merge] [--force] [--delete] [--target <branch>]`. The tool runs checkin validation (§6.6); if using `--rebase`/`--merge`, first propagates from parent and bails on conflict unless `--force`. It runs pre-checkin, creates the checkin commit, merges into the parent (or, for project tasks, into `--target`), runs pre-receive and post-receive, then switches to the parent worktree and cleans up the child worktree. Project tasks require `--target`. See §6.5 and §6.6. If merge conflicts occur (e.g. in other `.tt/` files), the user resolves manually; for `TASK.md`, keep the parent's version.

Multiple tasks can be checked out simultaneously; the symlinked HEAD worktree facilitates quick switching between ongoing tasks.

---

## Appendix A. Todo list algorithms (detailed)

### A.1 Generating the overall todo list

1. **Enumerate project branches**

   - List branches that represent projects (names matching `<project_prefix><slug>-<hex>`). Each has an "owner" project (the project whose ID matches the branch name).

2. **For each project P, traverse its subtree and discover tasks**

   - Read P's task file from P's branch. For each `subtask:` entry (task or project ID), the child is discovered. Each child's `subtask:` list will recursively be discovered strictly top-down from projects; only tasks reachable via this traversal are included (unless `--detached`, see step 4).

3. **For each discovered task T, choose where to read its task file**

   Do *not* use VCS parent to decide this. For every task **T**:

   - **Merged (done):** Some task or project branch **B** has an owner task file whose frontmatter contains `subtask: [x] <T> ...`. That branch B is the parent task's branch (the one that received the checkin). → **Read** task **T**'s metadata from `.tt/task/<T>.md` on **branch B**.
   - **Not merged (ongoing):** No branch's owner task file contains `subtask: [x] <T> ...`. → **Read** task file (and `subtask:` list for children) **from task T's own branch**.
   - **Deleted:** Task was removed via `tt task delete`; no branch contains a `subtask:` entry for T. → T is not discovered and does not appear in the todo list.
   - Implementation: for each task T, scan all task and project branches B; on B, read the owner task file. If any such file contains `subtask: [x] <T> ...`, then T is merged and the canonical source for T is that branch B; otherwise the canonical source for T is T's own branch.

4. **Orphan detection (when `--detached` is present)**

   - Enumerate all task branches (names matching `<task_prefix><slug>-<hex>`).
   - Compute the set of task IDs reachable from any project's subtree (from step 2).
   - Orphaned tasks = task branches whose ID is not in that set. These are added as a flat list to the "Tasks with no project (detached)" section.

5. **Filter sections and build output**

   - Filtering: If the user specified `--project <project-id>` (one or more), only emit sections for those projects. If the user specified `--detached`, include the detached section (if it has any orphaned tasks). If `--all` is specified, show all projects and the detached section. If no filter is specified, emit all project sections, but not the detached section.
   - Order projects within output by branch name (lexicographical). Order tasks within each project section by the order of `subtask:` entries in the project's task file.

6. **Emit the markdown**

   - For each project section to be output, emit the project task as an unindented bullet entry, then recurse into each child's children. Under the detached section, each orphaned task is a top-level bullet nested under the detached section header (they have no parent in the discovered tree). Sibling order is always the order of `subtask:` entries in the parent task file.
   - For each task line, output: checkbox from status (`[ ]` / `[-]` / `[x]`); link `[<prefix><slug>-<hex>](.tt/task/<slug>-<hex>.md)`; title (from task file frontmatter or from `subtask: [x] <task-id> <task-title>` on parent). Indentation reflects hierarchy.

**End-to-end summary:** Enumerate project branches → for each project traverse subtree via `subtask:` entries → for each discovered task T find where to read T's file (merged vs ongoing) → if `--detached`, find orphaned task branches and add to detached section → filter sections by `--project`/`--detached` → for each section emit header and walk tree depth-first (checkbox + link + title per task) → output markdown.

### A.2 Generating the focused todo list for the current task

**Input:** The current branch (or current task ID). Resolve to a task or project branch **T**; if the current branch is not a task or project branch, show a message explaining this.

1. **Resolve current task:** From the current branch, determine the task or project branch **T** (e.g. current branch is a task branch or project branch, or the branch name identifies the entity).
2. **Walk to project:** From **T**, walk backwards via the frontmatter-defined parent chain (the task or project that lists this one in `subtask:`) to the top-level task. If **T** is already a project, the path is just **T**. Otherwise collect the path: **T**, its parent task, and so on up to the project.
3. **Load task files:** For each task on this path, choose where to read its task file using the same rule as the full algorithm (merged = some branch's owner task file has `subtask: [x] <T>` → read from that branch; else read from task branch). Load child order from each task's `subtask:` list.
4. **Order and emit:** Order and emit markdown in the same format as the full list, but only for this subset of tasks. Indentation and hierarchy are preserved for the focused slice.

**Output:** Same markdown format as the full todo list. Useful for establishing context without pulling in the entire project tree.
