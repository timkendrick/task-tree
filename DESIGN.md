# Design document: task-tree

task-tree (`tt`) is a CLI tool for task tracking and context management within complex software development projects. It combines lightweight in-repository task tracking with structured task context management, using the version control system as a backing store.

---

## 1. Overview

task-tree combines lightweight in-repository task tracking with straightforward, structured task context management. The tool uses the version control system as the backing store: the project's current to-do state is represented as a tree structure, with the full scope of work expressed as tasks that can be subdivided and eventually merged back into their parents.

**Branching workflow.** Each task is represented by a VCS branch and has an initial commit that creates the task in the project; that commit records which parent branch the task branched off from. A parent task can contain one or more child tasks, each an independent unit of work (e.g. a feature or set of features). The VCS branch topology expresses dependencies (a parent branch depends on all its child branches). Tasks are attached to their parent via the parent task file's `subtask:` frontmatter; the order of these entries defines the order of child tasks. Tasks have their own VCS branch and can have arbitrarily deeply nested children.

**Tree constraint.** The project task graph must form a **tree**: each task has exactly one parent. DAG use cases (multiple parents referencing the same child task) are not allowed; the tool notifies the user and refuses to make changes when it encounters a task with multiple parents. Multiple non-task **root branches** are allowed; each acts as the root of a separate task tree (effectively multiple sub-projects in the same workspace). A root branch is a merge target that cannot itself be merged further (e.g. the branch the user was on when they created the top-level task). All development happens by splitting off task branches from a parent (root or task branch) and merging them back when the unit of work is complete. The parent branch gradually becomes more complete as child branches are merged. When a parent has no remaining child branches, it is eligible to be merged into its own parent(s) or to have new child branches created. A task is eligible for merging when all its child tasks are complete.

**Task context.** Each branch stores its own local task metadata and context in a version-controlled **task file** and can introspect the task hierarchy to read parent context, traceable back to the root branch(es). Child branches therefore have access to the whole chain of parent context and can see where they stand in the overall project plan.

The overall project state can be determined based on two artifacts: (1) a **high-level project to-do list** — a derived markdown listing of all tasks, grouped by root branch (and a "detached" section for top-level tasks whose branch parent is not a root), with nested bullets showing status, links to task files, and summaries; (2) **individual task files** — one per task, with metadata (title, status, description, labels, child list) in frontmatter and a free-form body used as a scratch pad during implementation. The todo list is not stored separately; it is derived from branches and task file contents. See §2 for source of truth and writability rules, §4 for exact data formats, and §9 for the standard user workflow.

---

## 2. Concepts and model

### Branching model

Tasks are represented by VCS branches. A parent task can have one or more child tasks; each child is an independent unit of work with its own branch. Parent/child relationships are expressed by the parent task file's `subtask:` frontmatter; the order of entries defines the order of children. The project task graph must form a **tree**: each task has exactly one parent. DAG use cases (multiple parents referencing the same child task) are not allowed; on encountering a task with multiple parents, the tool notifies the user and refuses to make changes. Multiple non-task root branches are allowed and represent multiple task trees (effectively multiple sub-projects in the same workspace).

A **root branch** is a merge target that cannot itself be merged further (e.g. the branch the user was on when they created the top-level task). A workspace can contain multiple root branches, each the root of a separate task tree. All development happens by splitting off task branches from a parent (root or task branch) and merging them back when the unit of work is complete. The parent branch becomes more complete as child branches are merged. When a parent has no remaining child branches, it is eligible to be merged into its own parent(s) or to have new child branches created. A task is eligible for merging when all its child tasks are complete.

### Source of truth

- **VCS** is the source of truth for: which branches exist (task and root branches), and **root attachment** — which root branch each top-level task branch belongs to (the VCS parent of that task's branch). The VCS is *not* used to define parent/child relations between tasks.
- **Parent task file `subtask:` frontmatter** is the source of truth for: **task hierarchy** (which task is whose parent, and the order of children). Task **P** is the parent of task **C** if and only if P's task file lists C in its `subtask:` list. Top-level tasks are those that do not appear in any other task's `subtask:` list.

The todo list is not persisted; it is derived from the branch set, root attachment (VCS), task hierarchy and metadata (frontmatter), and the rule for where each task's file is read (see §7 and Appendix A).

### Task context

Each branch stores its own local task context in a task file and can introspect the hierarchy to read parent context, traceable back to the root branch(es). There are two components: (1) the high-level project to-do list (derived markdown listing all tasks), and (2) individual task files (one per task, with metadata and a scratch-pad body).

Only the **current** task's task file and the **immediate parent** task file are writable; all other task files are read-only. This is enforced by `tt task checkin` (see §6.4): validation fails if the merge range contains modifications to any other task files. Parent task files are only writable from within a child task so that the completed-child summary (and optional `subtask:` update) can be persisted at merge time. This keeps focus on the current task and prevents context from one task leaking into another.

---

## 3. Identifiers and naming

- **Task ID:** Each task has a unique identifier of the form `<prefix><slug>-<hex>`, where `<prefix>` is configurable (set via `tt project init`, stored in `.tt/config.toml`, default `task/`), `<slug>` is a human-readable segment, and `<hex>` is an auto-generated 8-character hexadecimal string (e.g. `task/authentication-ea434dde`). The user cannot set the hex suffix; it is generated to avoid collisions. The slug defaults to a value derived from the task summary (e.g. lowercased, hyphenated); the user may override with `tt task create --slug <slug>`. Duplicate slugs are allowed; the 8-hex suffix ensures task IDs are unique.
- **Branch and file naming:** Task branches and task files use the machine-readable name `<prefix><slug>-<hex>` (e.g. with default prefix: `task/add-oauth-flow-8cf8d966`). Regardless of the branch prefix, task files are stored in `.tt/task` (e.g. `.tt/task/<slug>-<hex>.md`).

---

## 4. Data formats

### 4.1 Project to-do list

The project to-do list is a markdown listing of all tasks, grouped by root branch. Each root branch has a section header (e.g. `Tasks on branch \`main\`:`). Top-level tasks whose branch's VCS parent is not a root branch are listed under a **detached** section: `Tasks with no branch parent:`. Within each section, the task tree is shown as nested bullets. Each bullet contains the following, separated by spaces:

- A GFM checkbox: To-do `[ ]`, In progress `[-]`, Done `[x]`
- A Markdown relative link to the task file, labeled by the machine-readable branch name
- A single-line human-readable task summary

Filtering: **`--root <branch-name>`** (repeatable) and **`--orphan`**. With no flags, all root sections and the detached section (if any) are shown. With `--root main` (and/or `--root next`, etc.) and/or `--orphan`, only the listed section(s) are shown.

Example:

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

- [ ] [task/product-research-5fb4e979](.tt/task/product-research-5fb4e979.md) Initial product research
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

At merge time, the parent task's frontmatter is updated with the completed child (e.g. `subtask: [x] <task-id> [<task-title>]`). The user may request deletion of the child task file with `tt task checkin --delete`, leaving only the parent's frontmatter; otherwise the task file remains in the repository.

### 4.3 Metadata storage and TASK.md

Task files for ongoing tasks exist only on their respective branches; when generating the overall todo list, the task file contents must be retrieved from all the respective branches. Within a task's own branch, the task file is referenced via a `TASK.md` symbolic link in the repository root (e.g. `./TASK.md -> .tt/task/add-oauth-flow-8cf8d966.md`). When retrieving task metadata from frontmatter, only the most recent state of the task file is considered; all former revisions are ignored. Change history for a task's metadata can be tracked via the revision history of the task file.

The tool uses **jj (Jujutsu)** initially as the backing store; git support may be added later. The tool keeps the VCS in sync with the current task or branch (e.g. after `tt task checkout` and `tt task checkin`) so the working copy reflects the current task context.

---

## 5. Commands

The canonical form is `tt <entity-type> <command>`, e.g. `tt project init` or `tt task checkout`. Aliases:

| Alias | Canonical |
|-------|-----------|
| `tt init` | `tt project init` |
| `tt create` | `tt task create` |
| `tt checkout` | `tt task checkout` |
| `tt checkin` | `tt task checkin` |
| `tt status` | `tt task status` |
| `tt show` | `tt task show` |
| `tt propagate` | `tt task propagate` |
| `tt list` | `tt task list` |

### 5.1 Project

- **`tt project init <path-to-repo> <path-to-virtual-project-folder> [--prefix <prefix>]`** — Initialize a task-tree project. Creates the virtual project directory, `.tt/config.toml` (with optional task ID prefix), and a `HEAD` symlink that initially points to the repo and is later updated to the most recently checked-out task workspace (serving as a quick link to the current development context). Requires a clean working directory and no existing `.tt` in the repo root. See §9 step 1 and §6.2 (HEAD symlink).

### 5.2 Task

- **`tt task create [--parent <parent-task-id>] [--slug <slug>] [--title <title>] [--description <description>] [--label <label> ...] [--propagate [<propagate-flags>]] [--force]`** — Create a new task as a child of the given parent (default: current branch). Adds a `subtask: [ ] <task-id>` entry to the parent's task file on the parent's branch, then creates the child branch and task file (with `status: TODO` and `TASK.md` symlink). Prompts for summary/description if not provided. With `--propagate`, propagates the parent's new commit to descendant branches after creation. With `--force`, overwrites if the child branch already exists. See §6.1.

- **`tt task checkout <task-id> [--worktree [=<path>]] [--force]`** — Switch to the given task branch. With `--worktree`, uses or creates a dedicated jj workspace for that task; otherwise uses the closest ancestor task workspace or the current workspace. Refuses if the target workspace has local changes unless `--force`. Updates task status to IN-PROGRESS if TODO, runs `setup` hook when creating a new worktree, and updates the virtual project's `HEAD` symlink. See §6.2.

- **`tt task checkin [--rebase | --merge] [--force] [--delete]`** — Merge the current task branch into its parent. Runs validation (clean WC, task branch, one parent, no incomplete children, no conflicting or disallowed task-file changes); with `--rebase`/`--merge`, first propagates from parent and bails on conflict unless `--force`. Creates a checkin commit (TASK.md rewrite, optional child file deletion, parent frontmatter update), then merges into the parent. Runs pre-checkin, pre-receive, post-receive hooks; switches user to parent worktree and cleans up child worktree. See §6.3 and §6.4.

- **`tt task list [--root <branch-name>]... [--orphan]`** — Generate and print the full project todo list to stdout. Tasks are grouped by root branch (and detached section). Optional `--root` and `--orphan` filter which sections are shown. Output format is the markdown described in §4.1. See §7.1 and Appendix A.

- **`tt task list --focused`** — Generate and print the focused todo list (current task and its direct ancestors only) in the same markdown format. See §7.2 and Appendix A.

- **`tt task status`** — Show the current task and branch, and the status of all direct child tasks (the `subtask:` entries in the current task file's frontmatter).

- **`tt task show [<task-id>]`** — Show the full context of the current task or the given task: frontmatter and body of that task's task file. Output to stdout only.

- **`tt task propagate [--from=<parent-id>] [--to=<descendant-id>]... [--rebase | --merge] [--shallow] [--force]`** — Update descendant task branches so their base is the parent's current tip. Default is to rebase all descendants of the current task; `--merge` merges instead; `--shallow` updates only direct children; `--force` proceeds despite rebase/merge conflicts. Preconditions: clean WC, no merge commits at tip, no untracked changes in affected worktrees. See §6.6.

- **`tt task reorder <task-id> <modifier>`** — Reorder a direct child task. Modifier is one of `--up`, `--down`, `--after <other-task-id>`, or `--before <other-task-id>` (mutually exclusive). Fails if the reorder is impossible (e.g. already first with `--up`, or `<other-task-id>` is not a sibling). See §6.5.

- **`tt task remove <task-id>`** — Remove a direct child task from the current task by updating the current task file's frontmatter. The child's branch and task file are not deleted. See §6.5.

---

## 6. Task and branch operations

### 6.1 Task creation (`tt task create`)

The tool adds the new task to the parent's child list by creating a commit **on the parent task's branch** (regardless of which branch is currently checked out) that adds `subtask: [ ] <task-id>` to the parent task file. The child task's branch is then created from this parent commit. The task file for the new task is created on the child branch (with `status: TODO`, the `TASK.md` symlink, etc.). If the parent branch has multiple parents (e.g. a merge commit), the tool notifies the user and refuses to create the task.

Because the parent task file is modified, sibling (and descendant) branches may need to be updated to avoid conflicts at checkin. The optional `--propagate` flag runs propagate with any given flags after creating the task. If the named child branch already exists, the tool notifies the user and refuses unless `--force` is specified.

### 6.2 Checkout behavior (`tt task checkout`)

With **`--worktree`**: the tool ensures the task is checked out in its own jj workspace (creating it if necessary). Without `--worktree`: the tool checks out the task branch in the closest ancestor task workspace (if any), or the current workspace if no ancestors have their own workspace.

If the target workspace's working copy is an ancestor task's workspace (not the task's own) and contains changes, the tool alerts and refuses unless `--force` is provided. For subsequent checkouts of the same task, the default is to use an existing workspace for that task if present. If multiple workspaces exist for a task branch, the user must specify `--worktree=<path-to-workspace>`; this form can always be specified if the user wants to control the path of the workspace. The `HEAD` symlink in the virtual project folder is updated to the task's workspace whenever a task is checked out.

### 6.3 Checkin (merging completed tasks)

Completing a task means merging the task branch into its parent. Default `tt task checkin` checks for conflicts with the parent; if conflicts exist, validation fails. With `--rebase` or `--merge`, the tool first attempts to propagate from the parent into the current (child) branch; if propagation cannot complete without conflicts, the command bails unless `--force` is used (and the same `--force` is forwarded to the propagate step when used).

The checkin process:

1. Create a **checkin commit** on the child branch with: (a) rewrite `TASK.md` to point to the parent task's task file (resolving conflict with the parent branch's `TASK.md`); (b) optionally delete the child task file if `--delete` was provided; (c) update the parent task file's frontmatter so the corresponding `subtask:` line is `subtask: [x] <task-id>` or `subtask: [x] <task-id> <task-title>` if `--delete` was used.
2. Merge the child branch into the parent branch. The tool locates the parent task worktree (creating and initializing it if necessary). The parent's tree then includes the completed child task file (unless `--delete` was used) and any completed descendants already merged into the child. When generating the todo list, a completed task's metadata is read from the parent branch (merged file or the `subtask: [x] <task-id> <task-title>` line if the file was deleted).

After a successful checkin, the tool switches the worktree to the parent (updates `HEAD` symlink, deletes the child worktree if it was dedicated). If the user's working directory was inside the deleted child path, the tool switches them to the equivalent path under the `HEAD` symlink. If there is no parent task (direct child of a root branch), the merge is into that root branch. Merge conflicts in the working copy or other `.tt/` files must be resolved manually; for `TASK.md`, the intended resolution is to keep the parent's version.

### 6.4 Checkin validation

Before attempting any merge, `tt task checkin` performs validation and refuses if any check fails. The **merge range** is the set of commits on the child branch that are not in the parent (the commits that would be merged in). Checks include:

- Working copy is clean
- Current branch is a task branch
- Current task has exactly one parent
- No incomplete child tasks (all children must be merged before the parent can be checked in)
- No conflicts with parent once the checkin commit has been applied (unless `--force`), or after the optional pre-checkin propagate step when using `--rebase`/`--merge`
- No modifications to non-editable task files in the merge range: only the current task file and (optionally) the immediate parent task file's context scratchpad may be modified. No modifications to the parent file's frontmatter except the `subtask: [x]` update introduced by the checkin commit. Any other `.tt/task` file changes in the merge range cause checkin to abort
- The only change to `TASK.md` in the merge range from the child is the symlink pointing to the child's task file, then reverted by the checkin commit

On failure, `tt task checkin` aborts with an error and leaves the repository unchanged. Implementations may add further checks via hooks.

### 6.5 Task reorder and remove

Child tasks are ordered via the current task file's `subtask:` frontmatter. **`tt task reorder <task-id> <modifier>`** reorders a direct child; modifier is `--up`, `--down`, `--after <other-task-id>`, or `--before <other-task-id>` (mutually exclusive). **`tt task remove <task-id>`** removes a direct child from the current task's frontmatter; the child's branch and task file are not deleted.

### 6.6 Propagate

When the current task branch gains new commits (e.g. after merging a child with checkin or after direct work on the parent), descendant task branches still have the old parent revision as their base. **`tt task propagate`** updates the given descendant branch(es) (by default, recursively) so each is based on the parent's current tip. `--from` defaults to the current task ID; `--to` defaults to all immediate children of the parent. Strategy defaults to **`--rebase`**; **`--merge`** merges the parent into each child instead. **`--shallow`** updates only direct children. **`--force`** proceeds even if propagation produces conflicts.

**Scope:** The parent must be a task branch or a root branch with task-branch children. By default all descendant task branches in the subtree are updated; with `--shallow`, only direct children. Branches are processed in a deterministic order (parent before children) so each branch is rebased or merged onto its parent's already-updated tip.

**Preconditions (all checked before any updates; any failure causes the command to error):** Working copy of the current task is clean. Every branch that would be updated has exactly one parent (no merge commits at tip). No affected worktree may have untracked changes in its working copy. When `--rebase` is used (default), the rebase must apply cleanly for every branch to be updated unless `--force` is specified; with `--force`, the implementation may leave conflict state for the user to resolve. Under jj, conflicts are allowed in the model; no special conflict-failure handling is required beyond this.

**Worktrees:** After updating branch tips, the tool syncs all changed child worktrees to the new commit. The user's current working copy (HEAD) is not switched unless it was one of the updated branches. Propagate does not perform checkin-style merge-range validation (task-file rules for checkin do not apply when updating a child's base).

---

## 7. Todo list generation

### 7.1 Full list (summary)

To generate the overall todo list, the tool: (1) enumerates task branches and identifies root branches (VCS parent is used only for root attachment, not for building the task tree); (2) for each task T, determines where to read T's file — **merged** tasks are read from the branch whose owner task file contains `subtask: [x] <T> ...` (that parent's branch), either from the merged task file or from the `subtask: [x] <task-id> [<task-title>]` line if the file was deleted; **ongoing** tasks are read from T's own branch; (3) builds the task tree from frontmatter (top-level = not in any `subtask:` list; children = order in parent's `subtask:` list); (4) attaches top-level tasks to roots or detached via each top-level task's branch VCS parent; (5) filters sections by `--root`/`--orphan` if present; (6) emits section headers and walks the tree depth-first, outputting checkbox, link, and title per task in the format of §4.1.

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
| **setup** | When initializing a new worktree for a task (during `tt task checkout`) | New task worktree | Optional (non-blocking so init doesn't fail) | TT_TASK_ID, TT_BRANCH, TT_PARENT_TASK_ID, TT_ROOT_BRANCH |
| **pre-checkout** | Before switching branch in `tt task checkout` | Current (outgoing) worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH (newly-checked-out target), TT_PREVIOUS_TASK_ID, TT_PREVIOUS_TASK_BRANCH (outgoing) |
| **post-checkout** | After successful `tt task checkout` | Checked-out task worktree | Optional | TT_TASK_ID, TT_TASK_BRANCH (newly-checked-out), TT_PREVIOUS_TASK_ID, TT_PREVIOUS_TASK_BRANCH (outgoing) |
| **pre-create** | Before creating task in `tt task create` | Parent task worktree | Yes | TT_PARENT_TASK_ID, TT_PARENT_BRANCH, TT_TITLE, TT_SLUG, TT_DESCRIPTION, TT_LABELS (space-separated; labels with spaces/special chars quoted) |
| **post-create** | After task created in `tt task create` | New task worktree if created, else worktree we end up in | Optional | TT_TASK_ID (new), TT_TASK_BRANCH (new), TT_PARENT_TASK_ID, TT_PARENT_BRANCH; TT_WORKTREE_DIR = that same worktree |
| **pre-checkin** | Before checkin in `tt task checkin` | Child (current) task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH, TT_PARENT_TASK_ID, TT_PARENT_BRANCH |
| **pre-receive** | Before merge applied on parent (during checkin) | Parent task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH (parent), TT_INCOMING_TASK_ID, TT_INCOMING_BRANCH (child being merged) |
| **post-receive** | After merge applied on parent (during checkin) | Parent task worktree | Optional | Same as pre-receive |
| **pre-propagate** | Before `tt task propagate` updates descendants | Current (source) task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH |
| **post-propagate** | After `tt task propagate` completes | Same | Optional | TT_TASK_ID, TT_TASK_BRANCH |
| **pre-remove** | Before `tt task remove` | Parent task worktree (task whose frontmatter is updated) | Yes | TT_TASK_ID, TT_TASK_BRANCH (removed task), TT_PARENT_TASK_ID, TT_PARENT_TASK_BRANCH (task we're removing from) |
| **post-remove** | After `tt task remove` | Same | Optional | Same as pre-remove |

**Blocking vs optional:** Pre- hooks are blocking: a non-zero exit aborts the command. Post- hooks and **setup** are best-effort: a non-zero exit is relayed to the user but does not abort the workflow, so optional bookkeeping does not fail the operation.

**post-create:** If no new worktree is created, TT_WORKTREE_DIR is the worktree we end up in (e.g. the parent's); TT_TASK_ID and TT_TASK_BRANCH still refer to the new task and its branch.

**TT_LABELS:** Format is space-separated; labels containing spaces or special characters are quoted (implementation detail).

---

## 9. User workflow

The standard workflow:

1. **Initialize** — `tt project init <path-to-repo> <path-to-virtual-project-folder> [--prefix <prefix>]`. The tool checks that the repo working directory is clean and there is no `.tt` in the repo root. It creates the virtual project directory, `.tt/config.toml` (prefix default `task/`), and a `HEAD` symlink that initially points to the repo and is updated on each checkout. See §5.1 and §6.2.

2. **Create a task** — `tt task create [--parent <parent-task-id>] [--slug <slug>] [--title <title>] [--description <description>] [--label <label> ...] [--propagate [<propagate-flags>]]`. The tool checks the parent's workspace is clean, prompts for summary/description (and autosuggested branch name) if needed, locates the parent branch (default current branch; used as project root if not a task branch). If the parent branch has multiple parents (e.g. a merge commit), the tool notifies the user and refuses. It creates a commit on the parent's branch adding `subtask: [ ] <task-id>`, creates the child branch from that commit, then a commit on the child with the new task file and `TASK.md` symlink. With `--propagate`, it runs propagate with any given flags. See §6.1.

3. **Start working** — `tt task checkout <task-id> [--worktree [=<path>]]`. The tool checks the target workspace is clean (or `--force`), verifies the task branch exists, uses or creates the appropriate workspace per §6.2, sets task status to IN-PROGRESS if TODO, runs `setup` when initializing a new worktree, and updates the `HEAD` symlink. See §6.2.

4. **Work** — User commits changes on the branch and accumulates context in `./TASK.md`.

5. **Finish the task** — `tt task checkin [--rebase | --merge] [--force] [--delete]`. The tool runs checkin validation (§6.4); if using `--rebase`/`--merge`, first propagates from parent and bails on conflict unless `--force`. It runs pre-checkin, creates the checkin commit, merges into the parent (running pre-receive and post-receive), then switches to the parent worktree and cleans up the child worktree. See §6.3 and §6.4. If merge conflicts occur (e.g. in other `.tt/` files), the user resolves manually; for `TASK.md`, keep the parent's version.

---

## Appendix A. Todo list algorithms (detailed)

### A.1 Generating the overall todo list

1. **Enumerate task branches and root branches**

   - List branches that represent tasks (names matching `<prefix><slug>-<hex>`). Each has an "owner" task (the task whose ID matches the branch name).
   - Identify root branches: a root branch is not a task branch and is used as a merge target; a project may have multiple root branches. For each task branch, the VCS (e.g. jj's revision parent) gives its parent revision; map that to a branch. This is used *only* for root attachment (step 4), not for building the task tree. If a task branch has multiple parent revisions (merge commit), the tool treats it as invalid and shows an error marker.
   - Result: all task branches, and for each task branch its VCS parent branch (so which are roots and which task branches have a root as VCS parent).

2. **For each task, choose where to read its task file**

   Do *not* use the VCS parent branch to decide this. For every task **T**:

   - **Merged (done):** Some task branch **B** has an owner task file whose frontmatter contains `subtask: [x] <T> ...`. That branch B is the parent task's branch (the one that received the checkin). → **Read** task **T**'s metadata from **branch B**: either from `.tt/task/<T>.md` on B if the task file was retained at checkin, or from the `subtask: [x] <task-id> [<task-title>]` line in B's owner task file if the task file was deleted at checkin.
   - **Not merged (ongoing):** No task branch's owner task file contains `subtask: [x] <T> ...`. → **Read** task file (and `subtask:` list for children) **from task T's own branch** (e.g. via `TASK.md` or `.tt/task/<T>.md`).
   - Implementation: for each task T, scan all task branches B; on B, read the owner task file. If any such file contains `subtask: [x] <T> ...`, then T is merged and the canonical source for T is that branch B; otherwise the canonical source for T is T's own branch.

3. **Load metadata and build the task tree from frontmatter**

   - From the chosen revision for each task (from step 2), parse task file metadata from frontmatter (title, status, labels, `subtask:` list).
   - Build the task tree from frontmatter only: **Top-level tasks** = tasks that do not appear in any other task's `subtask:` list. **Children of a task P** = the tasks listed in P's `subtask:` list, in that order. **Parent of task C** = the unique task P whose `subtask:` list contains C (if C is not top-level).
   - Validation: Every non–top-level task must appear in exactly one other task's `subtask:` list. If a task appears in more than one list (multiple parents) or is not top-level but appears in none (orphan), the tool treats it as invalid and reports an error or shows an error marker.

4. **Attach top-level tasks to roots and build output sections**

   - Root attachment: For each top-level task T, use the **VCS parent of T's branch** to assign T to a section. If the VCS parent is a root branch R, T belongs under "Tasks on branch `R`:". If the VCS parent is not a root branch (e.g. it is a task branch), T is **detached** and belongs under "Tasks with no branch parent:". Order top-level tasks within each section e.g. by branch name or creation time.
   - Filtering: If the user specified `--root <branch-name>` (one or more), only emit sections for those roots. If the user specified `--orphan`, only emit the detached section. If neither is specified, emit all root sections and the detached section (if it has any tasks).

5. **Emit the markdown**

   - For each section to be output (in order: requested roots, then detached if included), emit a section header: `Tasks on branch \`<name>\`:` or `Tasks with no branch parent:` (no trailing blank line in the spec; one blank line after the header is conventional before the first bullet).
   - Under each section, for each top-level task in that section, output a task line, then recurse into its children (from the `subtask:` order) with one more indent level per nesting. Sibling order is always the order of `subtask:` entries in the parent task file.
   - For each task line, output: checkbox from status (`[ ]` / `[-]` / `[x]`); link `[<prefix><slug>-<hex>](.tt/task/<slug>-<hex>.md)`; title (from task file frontmatter or from `subtask: [x] <task-id> <task-title>` on parent). Indentation reflects hierarchy.

**End-to-end summary:** Enumerate task branches and root branches → for each task T find where to read T's file (scan branches for owner task file containing `subtask: [x] <T>`; if found on B → read T from B; else read T from T's branch) → build task tree from frontmatter → attach top-level tasks to roots/detached via VCS parent → filter sections by `--root`/`--orphan` → for each section emit header and walk tree depth-first (checkbox + link + title per task) → output markdown.

### A.2 Generating the focused todo list for the current task

**Input:** The current branch (or current task ID). Resolve to a task branch **T**; if the current branch is not a task branch, the focused list may be empty or show only a message.

1. **Resolve current task:** From the current branch, determine the task branch **T** (e.g. current branch is a task branch, or the branch name identifies the task).
2. **Walk to root:** From **T**, walk backwards via the frontmatter-defined parent chain (the task that lists this one in `subtask:`) to the top-level task. Collect the path: **T**, its parent task, and so on up to the root. The root branch for grouping is the VCS parent of that top-level task's branch.
3. **Load task files:** For each task on this path, choose where to read its task file using the same rule as the full algorithm (merged = some branch's owner task file has `subtask: [x] <T>` → read from that branch; else read from task branch). Load child order from each task's `subtask:` list.
4. **Order and emit:** Order and emit markdown in the same format as the full list, but only for this subset of tasks. Indentation and hierarchy are preserved for the focused slice.

**Output:** Same markdown format as the full todo list. Useful for establishing context without pulling in the entire project tree.
