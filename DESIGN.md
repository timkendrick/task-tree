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

Only the **current** task's task file is writable by the user; all other task files (including the parent task file) are read-only. This is enforced by `tt task checkin` (see §6.6): validation fails if the unmerged range contains modifications to any task file other than the current task's. The parent task file is updated only by the tool itself, not by the user: the `[tt:task:<id>:handoff]` and `[tt:task:<id>:checkin]` commits (which are created on the parent branch, not the child branch) mark the subtask as done in the parent's frontmatter at checkin time.

---

## 3. Identifiers and naming

- **Task ID:** Each task has a unique identifier of the form `<prefix><slug>-<hex>`, where `<prefix>` is the task prefix (configurable in `.tt/config.toml`, default `task/`), `<slug>` is a human-readable segment, and `<hex>` is an auto-generated 8-character hexadecimal string (e.g. `task/authentication-ea434dde`). The user cannot set the hex suffix; it is generated to avoid collisions. The slug defaults to a value derived from the task summary (e.g. lowercased, hyphenated); the user may override with `tt task create --slug <slug>`. Duplicate slugs are allowed; the 8-hex suffix ensures task IDs are unique.
- **Project ID:** Projects use the same format with a different prefix: `<project_prefix><slug>-<hex>` (e.g. `project/main-app-ea434dde`). The project prefix is configurable in `.tt/config.toml`, default `project/`.
- **Context ID:** Each context file has an identifier of the form `context/<slug>-<hex>`, where `<slug>` is derived from the context title and `<hex>` is an auto-generated 8-character hexadecimal string (e.g. `context/initial-research-ab3243f0`). Context IDs are referenced within the owning task file's frontmatter.
- **Config:** `.tt/config.toml` stores `task_prefix` (default `task/`) and `project_prefix` (default `project/`), both set via `tt workspace init`.
- **Branch and file naming:** Task branches use `task/<slug>-<hex>`; project branches use `project/<slug>-<hex>`. Each task file is stored in its own directory: `.tt/task/<slug>-<hex>/TASK.md`. Context files for a task are stored alongside it: `.tt/task/<slug>-<hex>/context/<ctx-slug>-<ctx-hex>.md`.

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
- [-] [project/main-app-2c382538](.tt/task/main-app-2c382538/TASK.md) Main app
   - [-] [task/authentication-ea434dde](.tt/task/authentication-ea434dde/TASK.md) Implement user authentication
   - [x] [task/email-signup-a4048c0f](.tt/task/email-signup-a4048c0f/TASK.md) Allow user creation with email address
   - [-] [task/add-oauth-flow-8cf8d966](.tt/task/add-oauth-flow-8cf8d966/TASK.md) Integrate OAuth2 signin flow
      - [x] [task/research-oauth-flow-c10103b7](.tt/task/research-oauth-flow-c10103b7/TASK.md) Research SSO auth flow
      - [-] [task/determine-sso-providers-3ddc3c2f](.tt/task/determine-sso-providers-3ddc3c2f/TASK.md) Determine supported SSO providers
      - [ ] [task/plan-feature-9fdbbd60](.tt/task/plan-feature-9fdbbd60/TASK.md) Plan feature
      - [ ] [task/write-e2e-tests-8961d5b1](.tt/task/write-e2e-tests-8961d5b1/TASK.md) Write end-to-end tests
      - [ ] [task/implement-feature-7702ec93](.tt/task/implement-feature-7702ec93/TASK.md) Implement feature
      - [ ] [task/review-implementation-34a0507c](.tt/task/review-implementation-34a0507c/TASK.md) Review feature implementation
      - [ ] [task/update-docs-6369ad14](.tt/task/update-docs-6369ad14/TASK.md) Update documentation
      - [ ] [task/update-context-48c3fa01](.tt/task/update-context-48c3fa01/TASK.md) Update parent task context
   - [ ] [task/forgotten-password-ef19c63e](.tt/task/forgotten-password-ef19c63e/TASK.md) Implement 'forgotten password' signin
   - [ ] [task/landing-page-4613e4c8](.tt/task/landing-page-4613e4c8/TASK.md) Build landing page
   - [ ] [task/pricing-page-cdf2d632](.tt/task/pricing-page-cdf2d632/TASK.md) Build pricing page
- [ ] [project/docs-site-28cecfa8](.tt/task/docs-site-28cecfa8/TASK.md) Documentation website
- [ ] [project/deployment-f7b045f1](.tt/task/deployment-f7b045f1/TASK.md) Deploy to cloud infrastructure

Orphaned tasks:

- [ ] [task/product-research-5fb4e979](.tt/task/product-research-5fb4e979/TASK.md) Initial product research
- [ ] [task/auth-mvp-spike-3a2e63d2](.tt/task/auth-mvp-spike-3a2e63d2/TASK.md) Auth MVP spike
```

### 4.2 Task file

Each task file pertains to one task and holds its context. Metadata is in Markdown frontmatter: one-line summary (`title`), task status, creation and modification timestamps, labels, child tasks via `subtask:` entries, and associated context files via `context:` entries. The order of `subtask:` entries defines the display order of children in the todo list. The **body** (everything after the closing `---`) is free-form markdown used as the task description and implementation notes.

Example — task not yet started (`.tt/task/pricing-page-cdf2d632/TASK.md`):

```markdown
---
title: Build pricing page
status: TODO
created: 2026-03-12T23:04:57Z
updated: 2026-03-12T23:04:57Z
label: design
label: front-end
label: back-end
---
Create a basic web page that explains the different pricing tiers.

We'll need a pricing grid that shows the various tiers, making sure to include
options for monthly/yearly plans.
```

Example — in-progress task with context files (`.tt/task/add-oauth-flow-8cf8d966/TASK.md`):

```markdown
---
title: Integrate OAuth2 signin flow
status: IN-PROGRESS
created: 2026-03-12T23:04:57Z
updated: 2026-03-12T23:10:00Z
label: back-end
label: auth
context: context/initial-research-ab3243f0
context: context/provider-comparison-7f8e2d1a
subtask: [x] task/research-oauth-flow-c10103b7
subtask: [-] task/determine-sso-providers-3ddc3c2f
subtask: [ ] task/plan-feature-9fdbbd60
subtask: [ ] task/write-e2e-tests-8961d5b1
subtask: [ ] task/implement-feature-7702ec93
subtask: [ ] task/review-implementation-34a0507c
subtask: [ ] task/update-docs-6369ad14
subtask: [ ] task/update-context-48c3fa01
---
Users should be able to sign into the application from a variety of providers
via a Single-Sign-On (SSO) process.

The list of providers should be extensible and configurable via environment
variables.
```

**Canonical frontmatter field order.** All task files must use the following canonical field ordering within the frontmatter block:

```
title:       (required, exactly one)
status:      (required, exactly one)
created:     (required, exactly one)
updated:     (required, exactly one)
label:       (zero or more; each on its own line)
context:     (zero or more; each on its own line)
subtask:     (zero or more; each on its own line)
```

All tool commands that mutate task file frontmatter maintain this ordering automatically. The `write_task_file` shared helper in `scripts/cli/lib/common.sh` normalises ordering on full rewrites; `write_context_file` handles context file creation (no status/label/context/subtask fields); `append_frontmatter_context` and `append_frontmatter_subtask` insert at the correct position for incremental mutations.

At merge time, the parent task's frontmatter is updated with the completed child (e.g. `subtask: [x] <task-id>`). The user may request full removal of the child task from the parent branch using `tt task delete` (or `tt task checkin --delete`, which runs the normal checkin and then delegates to `tt task delete`). This removes the child task directory and its `subtask:` entry from the parent's frontmatter entirely, making the task invisible in the todo list. If `--delete` is not used, the task directory remains in the repository and the `subtask: [x]` entry is preserved.

### 4.3 Metadata storage and TASK.md

Task files for ongoing tasks exist only on their respective branches; when generating the overall todo list, the task file contents must be retrieved from all the respective branches. Within a task's own branch, the task file is referenced via a `TASK.md` symbolic link in the repository root (e.g. `./TASK.md -> .tt/task/add-oauth-flow-8cf8d966/TASK.md`). When retrieving task metadata from frontmatter, only the most recent state of the task file is considered; all former revisions are ignored. Change history for a task's metadata can be tracked via the revision history of the task file.

### 4.4 Context files

Context files are standalone freeform markdown documents associated with a task. They are stored alongside the task file in its directory: `.tt/task/<slug>-<hex>/context/<ctx-slug>-<ctx-hex>.md`. Each context file has a `title` (mandatory), `created` (ISO 8601 UTC timestamp), and `updated` (ISO 8601 UTC timestamp, refreshed on each edit) in its YAML frontmatter, followed by an arbitrary markdown body.

Example (`.tt/task/add-oauth-flow-8cf8d966/context/initial-research-ab3243f0.md`):

```markdown
---
title: "Initial OAuth2 research"
created: 2026-03-12T23:04:57Z
updated: 2026-03-12T23:04:57Z
---
OAuth2 spec: https://oauth.net/2/

Relevant project source files:
- `docs/auth`
- `src/views/login`
```

Context files are referenced in the owning task's frontmatter via `context: context/<ctx-slug>-<ctx-hex>` entries (one per file).

The tool uses **jj (Jujutsu)** initially as the backing store; git support may be added later. The tool keeps the VCS in sync with the current task or branch (e.g. after `tt task checkout` and `tt task checkin`) so the working copy reflects the current task context.

---

## 5. Commands

The canonical form is `tt <entity-type> <command>`, e.g. `tt workspace init` or `tt task checkout`. The tt dispatcher supports arbitrary nesting depth through directory structures: directories represent namespaces and executable files represent final commands. For example, `tt task context add` dispatches to `scripts/cli/task/context/add`, where `task/context/` is the namespace and `add` is the executable command. This allows for flexible organization of related subcommands (e.g., all context operations under `tt task context *`) without requiring dispatcher code changes. Aliases:

| Alias | Canonical |
|-------|-----------|
| `tt init` | `tt workspace init` |
| `tt switch` | `tt worktree switch` |
| `tt create` | `tt task create` |
| `tt checkout` | `tt task checkout` |
| `tt checkin` | `tt task checkin` |
| `tt publish` | `tt task publish` |
| `tt show` | `tt task show` |
| `tt parent` | `tt task parent` |
| `tt propagate` | `tt task propagate` |
| `tt checkpoint` | `tt task checkpoint` |
| `tt complete` | `tt task complete` |
| `tt delete` | `tt task delete` |
| `tt tree` | `tt task tree` |
| `tt add-context` | `tt task context add` |
| `tt get-context` | `tt task context get` |
| `tt list-context` | `tt task context list` |
| `tt delete-context` | `tt task context delete` |
| `tt current` | `tt task current` |
| `tt revset` | `tt task revset` |
| `tt edit` | `tt task edit` |
| `tt prompt` | `tt task prompt` |
| `tt move` | `tt task move` |
| `tt undo` | `tt history undo` |
| `tt active` | `tt worktree active` |
| `tt repo` | `tt workspace repo` |
| `tt root` | `tt workspace root` |

### 5.0 Repository root resolution

All `tt` commands that accept a `--repo PATH` option resolve the repository root using the following priority order:

1. **`--repo PATH`** — the explicit flag value, if provided.
2. **`TT_REPO`** — the value of the `TT_REPO` environment variable, if set and non-empty.
3. **CWD walk** — walk up from the current working directory until a `.jj` directory is found.

The command exits with an error if none of these resolves to a valid jj repository. `tt workspace init` is exempt — it always takes the repository path as a required positional argument.

### 5.2 History

- **`tt history undo [--force] [--repo PATH]`** — Undo the most recent mutating `tt` command by restoring the jj repository to the operation state before that command ran. Multiple invocations go further back in history. There is no `tt history redo`; instead, the outgoing jj operation ID is logged to stderr before undoing so the user can manually restore it with `jj op restore <operation-id>`.

  **Safety checks** (all bypassed by `--force`):
  - No in-progress transaction (last history entry has a non-empty after-op-id). An in-progress entry indicates a `tt` command crashed mid-transaction; `--force` allows reverting it.
  - Current jj operation ID matches the last recorded after-op-id. A mismatch indicates the repository was modified outside of `tt` since the last recorded command; `--force` allows undoing anyway.
  - Working copy is clean (no uncommitted changes).

  See §6.12 for the full transaction history mechanism.

- **`tt history unlock [--force] [--repo PATH]`** — Clear a stale in-progress transaction from `.tt/history` without reverting the jj repository state. Use this when a `tt` process crashed mid-transaction and the jj repository is already in an acceptable state.

  - If there is no in-progress transaction: exits 0 silently (no-op).
  - If the history file is empty: exits 0 silently (no-op).
  - If the history file does not exist: exits 1 with an error message.
  - If there is an in-progress transaction and `--force` is not given: exits 1 with a message.
  - With `--force`: completes the transaction entry by writing `<before-op-id>:<current-op-id>` (where `<current-op-id>` is the current jj operation ID) — this marks the history as clean without changing the jj repository state.

  **Contrast with `tt history undo --force`:** `undo --force` reverts the jj repository to the state before the crashed command ran. Use `unlock --force` when you want to keep the current jj state and just unblock future `tt` commands.

  See §6.12 for the full transaction history mechanism.

### 5.3 Workspace

- **`tt workspace init <path-to-repo> <path-to-virtual-project-folder> [--task-prefix <prefix>] [--project-prefix <prefix>] [--force]`** — Initialize a task-tree project. Creates the virtual workspace directory, `.tt/config.toml` (with optional task prefix and project prefix), `.tt/.gitignore` (containing `/history` and `/workspace`), an empty `.tt/history` transaction log, a `.tt/workspace` symlink pointing to the virtual project directory, and a `HEAD` symlink in the virtual directory that initially points to the repo and is later updated to the most recently checked-out task workspace (serving as a quick link to the current development context). Creates a `[tt:workspace:init] Create workspace` commit in the jj repository (`.tt/config.toml` and `.tt/.gitignore` are committed; `.tt/history` and `.tt/workspace` are gitignored). Requires a clean working directory; aborts if `.tt` exists in the repo root as a non-directory entry (use `--force` to remove it). With `--force`, also allows overwriting files in an already-populated virtual folder. See §9 step 1, §6.2 (HEAD symlink and `.tt/workspace`), and §6.12 (transaction history).

- **`tt workspace root [--repo PATH]`** — Print the virtual workspace directory path. Resolves and prints the path that the `.tt/workspace` symlink points to — the virtual project directory configured by `tt workspace init`. Exits with an error if the workspace has not been initialised (no `.tt/workspace` symlink present). See §5.0.

- **`tt workspace repo [--repo PATH]`** — Print the canonical repository root path. When run from a task worktree (a secondary jj workspace), resolves and prints the path to the primary (canonical) repository root rather than the worktree itself. Useful for locating shared repository resources from any worktree. See §5.0.

- **`tt worktree switch [<worktree-path>] [--force]`** — Update the virtual project's `HEAD` symlink to point to the given worktree path. If `<worktree-path>` is omitted, defaults to the worktree containing the current working directory; exits with an error if the CWD is not within a known jj workspace. Unlike `tt task checkout --switch`, this command does not create worktrees, switch VCS branches, or update task status; it only redirects `HEAD`. The path must be a valid jj workspace in the repository. Refuses if the workspace currently pointed to by `HEAD` has uncommitted changes, unless `--force` is provided. Runs `pre-checkout` and `post-checkout` hooks; hook env vars `TT_PREVIOUS_TASK_ID`/`TT_PREVIOUS_TASK_BRANCH` reflect the task that `HEAD` was pointing to before the switch. Output is the same confirmation as `tt task checkout`. See §6.2.

### 5.4 Task

- **`tt task create [--parent <parent-task-id> | --project [--target <commit-rev>]] [--slug <slug>] [--title <title>] [--label <label> ...] [--propagate [--rebase | --merge] [--shallow] [--force]] [--checkout [--worktree[=<path>]]] [--force]`** — Create a new task or project. With `--parent` (default: current branch): creates a commit on the parent's branch that both creates the new task stub directory (with a placeholder `title: ""`, `status: TODO`, `created`, and `updated` timestamps in `TASK.md`; the title is filled in by the subsequent edit step) and registers `subtask: [ ] <task-id>` in the parent's task file; the child branch is forked as an empty commit from this updated parent tip. The `TASK.md` symlink is created at first checkout. With `--project` (mutually exclusive with `--parent`): creates a parentless project using the project prefix; the project branch forks from `--target` if specified, else the current revision. Prompts for title if not provided. Reads the task body/description from stdin (via pipe or redirect) if stdin is not a terminal; otherwise opens an editor for body input. **`--slug` is required when stdin is not a terminal (non-interactive mode); in interactive mode the user is prompted with a suggested default derived from the title.** With `--propagate`, propagates the parent's new commit to its existing descendant branches after creation (equivalent to running `tt task propagate --from <parent>` with any given flags); supports `--rebase | --merge` (strategy; default rebase), `--shallow` (direct children only), and `--force` (proceed despite conflicts). With `--checkout`, runs `tt task checkout` on the newly created task before exiting; `--worktree[=<path>]` (only valid with `--checkout`) passes through to checkout to use or create a dedicated jj workspace. With `--force` (outside of `--propagate`), overwrites if the child branch already exists. See §6.1.

  **Examples:**
  ```bash
  # Interactive — prompts for title, slug, and opens editor for body
  tt task create

  # Interactive with title — prompts for slug and opens editor for body
  tt task create --title "Phase 0: Test harness"

  # Pipe from file
  cat ./description.md | tt task create --title "Phase 0: Test harness"

  # Redirect from file
  tt task create --title "Phase 0: Test harness" < ./description.md

  # With parent and labels
  tt task create --parent task/phase-0-abc123de --slug tt-task-list --label tdd < ./description.md

  # Create project
  tt task create --project --title "Main app" < ./description.md

  # Create from specific revision
  tt task create --project --title "Main app" --target abc123 < ./description.md

  # Create and immediately checkout with worktree
  tt task create --slug my-task --title "My task" --checkout --worktree

  # Create, checkout with worktree, and switch HEAD to it
  tt task create --slug my-task --title "My task" --checkout --worktree --switch
  ```

- **`tt task edit [<task-id>] [--title <title>] [--label <label> ...] [--delete-label <label> ...] [--worktree <path>] [--repo <path>]`** — Edit the title and/or labels of a task. Reads the task body from stdin (via pipe or redirect) if stdin is not a terminal; otherwise preserves the existing body. With no metadata flags and stdin is a terminal, opens an editor pre-populated with the current body text (interactive mode). `--label` appends; `--delete-label` removes (silent no-op if absent). Requires a clean working copy. Creates a `[tt:task:<task-id>:edit] <title>` commit and advances the task bookmark. See §6.1.1.

  **Examples:**
  ```bash
  # Interactive — opens editor pre-populated with current body
  tt task edit

  # Edit current task, preserve body
  tt task edit --title "New title"

  # Pipe new body to current task
  echo "New description" | tt task edit

  # Redirect body from file
  tt task edit < ./description.md

  # Edit specific task with piped body
  echo "New description" | tt task edit task/abc-123def

  # Edit with both stdin and explicit title
  cat ./description.md | tt task edit --title "Updated title"
  ```

- **`tt task checkout <task-id> [--worktree [=<path>] [--switch]] [--force]`** — Switch to the given task branch. With `--worktree`, uses or creates a dedicated jj workspace for that task; otherwise uses the closest ancestor task workspace or the current workspace. Refuses if the target workspace has local changes unless `--force`. Updates task status to IN-PROGRESS if TODO, runs `setup` hook when creating a new worktree. Without `--worktree`, always updates the virtual project's `HEAD` symlink; with `--worktree`, only updates `HEAD` if `--switch` is also provided (`--switch` is only valid with `--worktree`). See §6.2.

- **`tt task checkpoint [--message <msg>] [--squash]`** — Record the current state and advance the task bookmark. If the working copy is empty, moves the bookmark to the working copy's parent commit (and updates that commit's description if `--message` is given). If the working copy has pending changes, creates a new commit from those changes (`jj commit`, using `--message` as the description) and moves the bookmark to it. The target commit must be a strict descendant of the current bookmark tip, unless `--force` is specified. With `--squash`, squashes all commits between the last bookmark and the current working copy into a single checkpoint commit (see §6.3.2). Prints a short confirmation on success. See §6.3. Hooks: **pre-checkpoint**, **post-checkpoint**.

- **`tt task complete [<task-id>] [--worktree=<path>] [--force]`** — Mark the current task (or a given task) as done. Creates a `[tt:task:<task-id>:complete] <title>` commit on the task branch that sets `status` to `DONE` in the task file, and advances the task bookmark to this commit. Requires a clean working copy and all child tasks to be done (every `subtask:` entry marked `[x]`) unless `--force` is specified. `--worktree=<path>` is required when the task has multiple worktrees. See §6.4. Hooks: **pre-complete** (blocking), **post-complete** (optional).

- **`tt task checkin [<task-id>] [--context <markdown>] [--complete] [--rebase | --merge] [--force] [--delete] [--retain-worktree] [--worktree=<path>] [--propagate [--propagate-rebase | --propagate-merge] [--propagate-shallow] [--propagate-force] [--propagate-dry-run] [--propagate-to <child-id>]]`** — Merge the current task branch (or `<task-id>`) into its parent branch. Only valid on task branches (those with a parent); use `tt task publish` for project branches. Supports **partial checkins** (task status `IN-PROGRESS`; shares work-in-progress with the parent) and **complete checkins** (task status `DONE`; marks the task finished). Always creates a **handoff commit** (child bookmark does not advance) and merges it into the parent as `[tt:task:<task-id>:checkin] <title>`. The handoff always updates the corresponding `subtask:` entry in the parent's frontmatter to reflect the child's current status (`[x]` if `DONE`, `[-]` if `IN-PROGRESS`). The user is switched to the parent worktree after the merge only if the `HEAD` worktree symlink currently points to the child task being checked in; if `HEAD` points to a different task, it is left untouched. With `--complete`: first runs `tt task complete` if the task is not already `DONE`, then proceeds with checkin. With `--context <markdown>`, appends a summary section to the parent task file body. With `--delete` (requires task `status: DONE`): after the normal checkin completes, delegates to `tt task delete` to remove the child task file and `subtask:` entry from the parent branch (two separate commits on the parent branch). With `--retain-worktree`: skip the automatic worktree deletion after a complete checkin; the jj workspace remains registered and the files remain on disk. `--worktree=<path>` disambiguates when the child task has multiple worktrees. Runs validation (see §6.6); when called without an explicit `<task-id>`, also verifies that the task bookmark is up to date: if any commits exist between the bookmark and the working-copy parent (`@-`), the command fails with a prompt to run `tt task checkpoint` first (or to pass `<task-id>` explicitly to bypass the check). With `--rebase`/`--merge`, first propagates from parent and bails on conflict unless `--force`. With `--propagate`, after the checkin completes, runs `tt task propagate --from <parent>` to push the newly-merged parent tip down to the parent's remaining children. Accepts `--propagate-rebase | --propagate-merge` (strategy; default rebase), `--propagate-shallow` (direct children only), `--propagate-force` (proceed despite conflicts), `--propagate-dry-run` (show propagation plan without applying; the checkin itself still runs normally), and `--propagate-to <child-id>` (repeatable; limit propagation to specific children). See §6.5 and §6.6.

- **`tt task publish [<project-id>] --target <branch> [--rebase | --merge] [--force] [--repo PATH] [--workspace-dir PATH]`** — Publish a project branch's work to an external delivery branch (e.g. `main`). Only valid on project branches (parentless roots); use `tt task checkin` for task branches that have a parent. Creates a **publish commit** that removes the `TASK.md` root symlink and the entire `.tt/task/` directory from the working tree (task files are development-only scaffolding that must not land on the delivery branch; `.tt/config.toml` is kept), then merges the publish commit into `--target`. The target bookmark advances to the merge commit. The user **remains on the project branch** after publishing (no workspace switch). With `--rebase` or `--merge`, first propagates from the target branch into the project branch before publishing. With `--force`, proceeds even if merge conflicts arise. See §6.5.

- **`tt task context add [<task-id>] [--title <title>] [--slug <slug>] [--worktree=<path>]`** — Create a new context file associated with the current task (or `<task-id>`). Prompts for title and slug (like task creation) if not provided. Reads the context body from stdin (via pipe or redirect) if stdin is not a terminal; otherwise opens an editor for the body. Generates a context ID of the form `context/<ctx-slug>-<ctx-hex>` and writes the context file to `.tt/task/<task-slug>/context/<ctx-slug>-<ctx-hex>.md`. Adds a `context: context/<ctx-slug>-<ctx-hex>` entry to the task file's frontmatter and refreshes the task's `updated` timestamp. Creates a commit: `[tt:task:<task-id>:context:add] <context-title>` and advances the task bookmark. When `<task-id>` is given, the task must have a checked-out worktree; `--worktree=<path>` disambiguates when multiple worktrees exist.

  **Examples:**
  ```bash
  # Pipe a file directly
  cat ./plan.md | tt task context add --title "Implementation plan"

  # Redirect from file
  tt task context add --title "Implementation plan" < ./plan.md

  # Interactive (no redirect) — opens editor as before
  tt task context add --title "Implementation plan"
  ```

- **`tt task context get [<context-id>...] [--task <task-id>] [--repo PATH]`** — Print the raw contents of one or more context files for a task to stdout. If one or more `<context-id>` positional arguments are given, only those context files are printed (in the order specified); otherwise all context files for the task are printed in declaration order. Output is the raw file contents including frontmatter; multiple files are concatenated with no separator. `--task` specifies which task to read from (default: current task). Applies the "where to read" rule (§7.1 / Appendix A step 3). Exits non-zero if the task has no context files or a specified context ID is not registered on the task. No hooks.

- **`tt task context list [<task-id>] [--task <task-id>] [--repo PATH]`** — List the context IDs for a task to stdout. If `<task-id>` is provided, lists context for that task; otherwise lists context for the current task. The `--task` flag is an alternative way to specify the task (takes precedence over the positional argument). Context IDs are output one per line in declaration order (as they appear in the task file's frontmatter). Exits with code 0 even if the task has no context files (produces no output in that case). Exits with code 1 if the task is not found or is not a valid task/project branch. Applies the "where to read" rule (§7.1 / Appendix A step 3). No hooks.

- **`tt task context delete <context-id> [--task <task-id>] [--repo PATH]`** — Delete a context file from the specified task (default: current task). Removes the context file from the repository and removes the corresponding `context:` entry from the task's frontmatter. Creates a commit: `[tt:task:<task-id>:context:delete] <context-title>` and advances the task bookmark. Exits with code 1 if the context ID is not registered on the task. Applies the "where to read" rule (§7.1 / Appendix A step 3). No hooks.

- **`tt task tree [--project <project-id>]... [--detached] | [--all]`** — Generate and print the full project todo list to stdout. Tasks are grouped by project; orphaned tasks are excluded by default. Optional `--project`, `--detached` and `--all` filter which sections are shown. Output format is the markdown described in §4.1. See §7.1 and Appendix A.

- **`tt task tree --focus`** — Generate and print the focused todo list (current task and its direct ancestors only) in the same markdown format. See §7.2 and Appendix A.

- **`tt task current`** — Print the current task or project branch name to stdout. Exits with 1 if the working copy is not on a task or project branch. No hooks.

- **`tt task revset [--task <task-id>] [--git] [--repo PATH]`** — Print a revision range covering all unmerged commits on a task branch since it diverged from its parent branch. Without `--task`, uses the current task and includes any trailing commits beyond the task bookmark (up to `@` if working copy is non-empty, or `@-` if empty). With `--task`, the range covers only the task bookmark itself. Without `--git`, outputs a jj revset (`<parent-bookmark>..<upper-bound>`). With `--git`, outputs a git commit range (`<from>..<to>`) where `<from>` is the `commit_id` of the fork point between the parent bookmark and the upper bound, and `<to>` is the `commit_id` of the upper bound. Exits with an error if the task cannot be located or the bookmark does not exist. No hooks.

- **`tt task parent [<task-id>] [--project]`** — Print the parent task ID of the current task (default) or the given task to stdout. With `--project`, walks up the hierarchy to find the nearest ancestor project branch instead of the immediate parent. Exits with code 1 if no parent (or no ancestor project) is found; exits with code 2 if multiple parents are found at any step. No hooks.

- **`tt task show [<task-id>] [--expand-context]`** — Show the metadata and direct child tasks of the current task (default) or the given task. Reads from the correct branch per the "where to read" rule (§7.1 / Appendix A step 3): merged tasks are read from the parent branch that received the checkin; ongoing tasks are read from their own branch. Output format: lowercase header block (`task`, `status`, `title`; and `parent` if the task has a parent), followed by a subtasks section, a context section (listing context file titles and IDs), and a body section, all always present and separated by `---` dividers. With `--expand-context`, additionally prints the full content of context files after the body section, each preceded by `---` and a header indicating the context file title and ID. Output to stdout only. No hooks.

- **`tt task prompt [<task-id>] [--message <text>] [--repo PATH]`** — Emit a self-contained LLM implementation prompt for a task to stdout. Reads the task file from the task's branch (defaulting to the current task if no `<task-id>` is given) and outputs: a heading line (`Implement task: <title>`), a mini frontmatter block (`task:` and `title:`), the task body, a `---` separator, any associated context files (each with its own `context:` / `title:` / `---` block and body), and a closing section listing common `tt` introspection commands. With `--message <text>`, appends an additional `---` separator followed by the verbatim message text at the end of the output. `--repo PATH` overrides the repository root. No VCS writes; no hooks.

- **`tt task propagate [--from=<parent-id>] [--to=<descendant-id>]... [--rebase | --merge] [--shallow] [--force]`** — Update descendant task branches so their base is the parent's current tip. Default is to rebase all descendants of the current task; `--merge` merges instead; `--shallow` updates only direct children; `--force` proceeds despite rebase/merge conflicts. Preconditions: clean WC, no merge commits at tip, no untracked changes in affected worktrees. See §6.8.

- **`tt task reorder <task-id> <modifier>`** — Reorder a direct child task. Modifier is one of `--up`, `--down`, `--after <other-task-id>`, or `--before <other-task-id>` (mutually exclusive). Fails if the reorder is impossible (e.g. already first with `--up`, or `<other-task-id>` is not a sibling). See §6.7.

- **`tt task delete [<task-id>] [--force]`** — Remove a task and its entire descendant subtree from the parent branch. Collects the full subtree via union traversal (reads subtask lists from both each task's own branch and the parent branch's copy at every level). Creates a single `[tt:task:<task-id>:delete] <title>` commit on the parent branch that removes the top-level `subtask:` entry and all descendant task files present on that branch. After the commit, deletes all bookmarks in the subtree (`jj bookmark delete`). Dedicated workspaces are forgotten from jj; files left on disk with a warning. Defaults to the current branch if no `<task-id>` is given. Requires task `status: DONE` unless `--force` is specified (which also skips the clean working-copy check). Aborts if no parent is found. See §6.9.

- **`tt task rename --slug <new-slug> [--task <task-id>] [--repo PATH] [--workspace-dir PATH]`** — Rename a task's slug (the human-readable part of the task ID), preserving the hex suffix. For example: `task/old-name-abc123` → `task/new-name-abc123`. Renames the jj bookmark, the task directory, and updates the parent's subtask reference. Requires a clean working copy. If the task has no parent (e.g., a project), only the bookmark and directory are renamed. Silently succeeds if the new slug matches the current slug. Errors if the new ID would conflict with an existing bookmark. See §6.10.

- **`tt task move [--task <task-id>] --parent <parent-task-id> [--repo PATH] [--workspace-dir PATH]`** — Reparent a task by moving it to a different parent. Removes the task from its current parent's `subtask:` list and adds it to the new parent's `subtask:` list. Rebases the task's unmerged commit range (commits not yet in the old parent's ancestry) onto the new parent's bookmark tip. Defaults to the current task if `--task` is not given. Checks for a clean working copy before proceeding. Returns a non-zero exit code if the task or parent does not exist. If moving a task that is not currently checked out, captures and restores the current revision (via change ID) after the move. Aborts if the task has no current parent (parentless project), if the new parent is the same as the current parent, or if the move would create a cycle in the task tree. See §6.11.

### 5.5 Worktree

- **`tt worktree list [--task <task-id>] [--quiet] [--repo PATH]`** — List all jj workspaces for the current repository. For each workspace, shows: a `*` marker on the current workspace, the jj workspace name, the tt task or project ID (nearest ancestor tt bookmark in the working copy ancestry, or `(none)` if none), and the filesystem path (with `$HOME` abbreviated as `~`, or `(none)` if no path is recorded). Output is a columnar table with a header row. With `--task <task-id>`, filters to only workspaces whose resolved TASK ID matches the given task or project ID (exit 1 if the ID is not a valid task/project ID format). With `--quiet`, prints only the jj workspace names (one per line), with no header or table; compatible with `--task` for machine-readable lookups. Intended for quick overview of all active task workspaces and for scripting. See §5.5.

- **`tt worktree show --task <task-id> [--repo PATH]`** — Output the worktree path for the given task or project ID to stdout. Accepts a full task or project ID via the required `--task` flag. Falls back to the repository root if no dedicated worktree exists for the task. Exits with an error if the task ID is not found in the repository. Intended for use in shell command substitution.

- **`tt worktree delete <worktree-path> [--force] [--repo PATH]`** — Delete a jj worktree by its filesystem path. The path must be a valid jj workspace in the repository. If the path is the canonical (main) repository (i.e. not a dedicated jj workspace), the command exits with an error — this check is not bypassed by `--force`. The task bookmark is automatically resolved from the worktree's current bookmark for safety checks: the task must be DONE, the worktree must be clean, and no commits may exist after the bookmark — unless `--force` is specified. Forgets the jj workspace and removes all files from the worktree path. The task bookmark is NOT deleted. If the virtual project's `HEAD` symlink points to the deleted worktree, it is reset to the repository root.

---

## 6. Task and branch operations

### 6.0 Branch topology and commit conventions

Each task and project branch follows a structured lifecycle of named commits. The table below describes each commit type, the command that creates it, and its purpose:

| Commit description | Command | Purpose |
|--------------------|---------|---------|
| `[tt:workspace:init] Create workspace` | `tt workspace init` | Adds `.tt/config.toml` to the working copy |
| `[tt:task:<project-id>:create] <title>` | `tt task create --project` | Creates the project task file on the project branch |
| `[tt:task:<task-id>:checkout] <title>` | `tt task checkout` | First checkout: creates `TASK.md` symlink and sets status → `IN-PROGRESS`; advances task bookmark |
| `[tt:task:<task-id>:create] <title>` | `tt task create` | On the parent branch: creates child task file and registers `subtask: [ ] <task-id>` in the parent file; parent bookmark advances |
| `[tt:task:<task-id>:edit] <title>` | `tt task edit` (also invoked by `tt task create`) | Sets title, description, and labels in the task file frontmatter; task bookmark initialised here on the child branch |
| `[tt:task:<task-id>:checkpoint] <message>` | `tt task checkpoint` | Advances the task bookmark to the current working state |
| `[tt:task:<task-id>:complete] <title>` | `tt task complete` | Sets status → `DONE` in the task file; final task bookmark advance |
| `[tt:task:<task-id>:handoff] <title>` | `tt task checkin` | Off-mainline merge-source commit; child bookmark does **not** advance to this commit |
| `[tt:task:<project-id>:handoff] <title>` | `tt task publish` | Off-mainline merge-source commit for project branches; project bookmark does **not** advance to this commit |
| `[tt:task:<task-id>:checkin] <title>` | `tt task checkin` | Empty merge commit on the parent branch; parent bookmark advances |
| `[tt:task:<project-id>:publish] <title>` | `tt task publish` | Empty merge commit on the target branch; target bookmark advances |
| `[tt:task:<task-id>:delete] <title>` | `tt task delete` | On the parent branch: removes child task file and `subtask:` entry from parent frontmatter; parent bookmark advances |

**Branch lifecycle diagram.** The diagram below shows the commit graph for a project `project/P` containing one task `task/T`, from workspace initialisation through to task completion. Commits are shown newest-first (top) to oldest (bottom), matching `jj log` output. `↑` marks where the named bookmark sits after each commit; `├─╮` is a branch fork (task branches from parent); `○─╯` is a merge (handoff merges into parent).

```
(initial commit):
  ○  [tt:workspace:init] Create workspace

project/P:
  ○  [tt:task:task/T:checkpoint] ...                 (continued project work, optional)
  │  ↑ project/P
  ○  [tt:task:task/T:checkin] <T-title>              ← tt task checkin
  ├─╮
  │ ○  [tt:task:task/T:handoff] <T-title>            ← tt task checkin  (NOT on mainline)
  │ ○  [tt:task:task/T:complete] <T-title>           ← tt task complete  (status → DONE)
  │ │  ↑ task/T  (final bookmark position)
  │ ○  [tt:task:task/T:checkpoint] ...               ← tt task checkpoint
  │ │  ↑ task/T
  │ ○  [tt:task:task/T:checkout] <T-title>           ← tt task checkout
  │ │  ↑ task/T
  │ ○  [tt:task:task/T:edit] <T-title>               ← tt task edit  (child branch init)
  │    ↑ task/T  (initial bookmark position)
  ├─╯
  ○  [tt:task:task/T:create] <T-title>               ← tt task create  (on parent branch)
  │  ↑ project/P
  ○  [tt:task:task/T:checkpoint] ...                 (optional project work)
  │  ↑ project/P
  ○  [tt:task:project/P:checkout] <title>            ← tt task checkout
  │  ↑ project/P
  ○  [tt:task:project/P:create] <title>              ← tt task create --project
     ↑ project/P  (initial bookmark position)
```

**Partial checkin.** When `tt task checkin` is called while the task is still `IN-PROGRESS`, a handoff is created but the child bookmark does not advance and the task is not marked done. The parent absorbs the work-in-progress; the task continues from its current bookmark tip. A subsequent checkin (after more work, or after `tt task complete`) produces another handoff from the same task. The graph below shows one partial checkin followed by a complete checkin:

```
project/P:
  ○  [tt:task:task/T:checkin] <T-title>              ← tt task checkin  (complete)
  ├─╮
  │ ○  [tt:task:task/T:handoff] <T-title>            (NOT on mainline)
  │ ○  [tt:task:task/T:complete] <T-title>           ← tt task complete
  │ │  ↑ task/T  (final)
  │ ○  [tt:task:task/T:checkpoint] ... (more work)
  │ │  ↑ task/T
  ○─╯  [tt:task:task/T:checkin] <T-title>            ← tt task checkin  (partial)
  ├─╮
  │ ○  [tt:task:task/T:handoff] <T-title>            (NOT on mainline)
  │ ○  [tt:task:task/T:checkpoint] ...
  │    ↑ task/T  (bookmark stayed here during partial checkin)
  ├─╯
  ○  [tt:task:task/T:create] <T-title>               ← tt task create
  ...
```

Note that the `[tt:task:task/T:checkpoint]` at the bottom of the task/T arm in the partial diagram is the common ancestor of both the subsequent `[tt:task:task/T:checkpoint]` (more work) commits (task continues from this point) and the partial `[tt:task:task/T:handoff]` (which branches off from the same commit).

---

### 6.1 Task creation (`tt task create`)

**With `--parent`:** The tool creates a commit **on the parent task's branch** (regardless of which branch is currently checked out) that both creates a minimal task stub directory (`.tt/task/<slug>-<hex>/TASK.md` containing `status: TODO`, `created`, and `updated` timestamps) and adds `subtask: [ ] <task-id>` to the parent task file, described as `[tt:task:<task-id>:create] <title>`. The parent bookmark is advanced to this commit. The child task's branch is then initialised by invoking `tt task edit` to set the title, body, and labels; the task bookmark is initialised here with a `[tt:task:<task-id>:edit] <title>` commit. The `TASK.md` symlink is created when the task is first checked out (see §6.2). After task creation, if the working copy was already on the parent branch, it is left at the updated parent branch tip; otherwise it is restored to its original position.

**Preconditions** (checked before any VCS operation; any failure aborts the command):

- The parent task's `status` must not be `DONE`. Completed tasks are immutable; any new work related to a completed task must be created under a different parent. The tool aborts with an error if the resolved parent task file has `status: DONE`.

**Slug requirement:** In non-interactive mode (stdin is not a terminal), `--slug` must be provided explicitly; the command errors if it is omitted. In interactive mode the user is prompted with a suggested default derived from the title.

Because the parent task file is modified, sibling (and descendant) branches may need to be updated to avoid conflicts at checkin. The optional `--propagate` flag runs `tt task propagate --from <parent>` after creating the task; it accepts `--rebase | --merge` (propagation strategy; default rebase), `--shallow` (direct children of the parent only), and `--force` (proceed despite conflicts). The optional `--checkout` flag runs `tt task checkout` on the newly created task before exiting; the user is left on the new task branch (the usual restore-to-original-revision behavior is suppressed). With `--checkout`, `--worktree[=<path>]` may be passed and is forwarded to `tt task checkout` to use or create a dedicated jj workspace (see §6.2). If the named child branch already exists, the tool notifies the user and refuses unless `--force` is specified.

**With `--project`:** The tool creates a parentless project task using the project prefix. The project branch is created from `--target <commit-rev>` if specified, else the current revision (any branch). The tool refuses to proceed if the target revision already exists within a task tree. No parent task file is modified. The project task file is created on the project branch.

### 6.1.1 Task editing (`tt task edit`)

**Purpose:** Edit the title, description, and/or labels of any task at any point in its lifetime. Also invoked internally by `tt task create` to write initial metadata on the child branch.

**Options:**

```
[<task-id>]           Target task ID (default: current branch)
--title TITLE         New title (preserves existing if omitted)
--label LABEL         Append a label (repeatable)
--delete-label LABEL  Remove a label if present (repeatable, silent no-op if absent)
--worktree PATH       Specify worktree when multiple exist for the task
--repo PATH           Repository root (default: walk up to .jj)
```

**Body input:** The task body (description) is read from stdin (via pipe or redirect) if stdin is not a terminal; otherwise the existing body is preserved.

**Interactive mode** (no `--title`, `--label`, or `--delete-label` given and stdin is a terminal): opens an editor pre-populated with the current body text. Comment lines (`#`-prefixed) are stripped and the result is trimmed; an empty result clears the body.

**Partial updates:** fields not supplied on the CLI retain their current values.

**Label semantics:** `--label` appends; `--delete-label` removes (no error if absent).

**Preconditions:** must be on a task or project branch; working copy must be clean.

**Commit:** `[tt:task:<task-id>:edit] <title>`. The task bookmark is advanced to this commit. The `updated` timestamp is refreshed.

**Output:** prints `<task-id>` on success.

### 6.2 Checkout behavior (`tt task checkout`)

The `TASK.md` symlink in the repository root points to the task file within its directory: `TASK.md -> .tt/task/<slug>-<hex>/TASK.md`.

With **`--worktree`**: the tool ensures the task is checked out in its own jj workspace (creating it if necessary). Without `--worktree`: the tool checks out the task branch in the closest ancestor task workspace (if any), or the current workspace if no ancestors have their own workspace.

If the target workspace's working copy is an ancestor task's workspace (not the task's own) and contains changes, the tool alerts and refuses unless `--force` is provided. For subsequent checkouts of the same task, the default is to use an existing workspace for that task if present. If multiple workspaces exist for a task branch, the user must specify `--worktree=<path-to-workspace>`; this form can always be specified if the user wants to control the path of the workspace. The `HEAD` symlink in the virtual project folder is updated to the task's workspace whenever a task is checked out, **except** when `--worktree` is used without `--switch`: in that case the worktree is created or updated but `HEAD` is not changed. Pass `--switch` (only valid with `--worktree`) to also update `HEAD` to the new worktree.

**Multiple worktree prevention.** Each task can have at most one dedicated jj workspace. If `--worktree=<path>` is provided and a workspace for this task already exists at a different filesystem path (compared via `realpath`), the command exits with an error showing the existing workspace path. If the provided path matches the existing workspace, the command succeeds silently and reuses it. The bare `--worktree` flag (no `=<path>`) always reuses the existing workspace if one is found, or derives a conventional path if none exists.

**`.tt/workspace` symlink** — a machine-local symlink at `<repo>/.tt/workspace` pointing to the virtual project directory (e.g. `/Users/tim/Sites/task-tree`). It is created by `tt workspace init` and listed in `.tt/.gitignore` (alongside `/history`), so it is never tracked by jj. Commands that need the virtual project directory (e.g. for updating `HEAD` or running hooks) resolve it via `readlink "$repo/.tt/workspace"`. Because each jj worktree has its own working copy of `.tt/`, the symlink must be planted separately in each worktree; `tt task checkout --worktree` does this automatically when creating a new worktree by copying the target from the main repo's `.tt/workspace`. When creating a new jj workspace with `jj workspace add`, the workspace name is set to the full task ID (e.g. `task/my-task-abc12345`) via `--name`.

### 6.3 Checkpoint (`tt task checkpoint`)

`tt task checkpoint` records the current state of work and advances the task bookmark. It always creates a new commit, even if the working copy is empty.

**Commit message:** `[tt:task:<task-id>:checkpoint] <message>`. The `<message>` part comes from `--message` if provided; otherwise the user is prompted to enter it in an editor (see §6.3.1 below).

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

#### 6.3.2 Squashing intermediate commits (`--squash`)

When `--squash` is passed, `tt task checkpoint` collapses all commits between the most recent bookmark state and the current working copy into a single checkpoint commit stacked directly after the bookmark. Intermediate commits are automatically abandoned by jj.

**Commit flow with `--squash`:**

1. Count commits in the range `<bookmark>::@- ~ <bookmark>` (commits strictly between the bookmark and the working copy's parent). If none exist, fall back to the normal commit flow.
2. Run `jj squash --from "<bookmark>::@- ~ <bookmark>" --into @ -m "<full-message>"` to merge all intermediate commits into `@` and set its description.
3. Run `jj new` to close `@` and open a fresh working copy.
4. Advance the bookmark to `@-` as normal.

**When there is nothing to squash** (the working copy parent is already the bookmark), `--squash` behaves identically to a normal checkpoint: a single `jj commit -m "<full-message>"` is issued.

**Before `--squash`:**

```
bookmark → A → B → C → @ (open WC, may have pending changes)
```

**After `--squash`:**

```
bookmark → Checkpoint → @ (new open WC)
                ↑
           bookmark now here
           (A, B, C abandoned automatically by jj)
```

### 6.4 Complete (`tt task complete`)

`tt task complete` marks a task as done. It creates a `[tt:task:<task-id>:complete] <title>` commit on the task branch that updates `status` from `IN-PROGRESS` to `DONE` in the task file, and advances the task bookmark to this commit.

An optional `<task-id>` positional argument may be provided. If given, the command completes that task regardless of which branch is currently checked out. If omitted, the command completes the current task (the task whose branch is currently checked out). The target task must have a checked-out worktree; `--worktree=<path>` is required when the task has multiple worktrees.

**Restore behavior:** When completing a task that is not currently checked out (i.e. `<task-id>` was given and differs from the current branch, or the task has a dedicated worktree other than the caller's worktree), `@` in the target worktree is restored to its pre-command state after the bookmark is advanced. When completing the current task in the current worktree, `@` remains as a clean descendant of the completed bookmark.

**Preconditions** (all checked before any VCS operation; any failure aborts the command):

- Target is a task or project branch.
- Working copy of the target worktree is clean.
- All child tasks are done: every `subtask:` entry in the target task file is marked `[x]`. `--force` bypasses this check.

**Behavior:** Updates `status: DONE` in the task file frontmatter, describes the commit as `[tt:task:<task-id>:complete] <title>`, advances the task bookmark, and leaves a clean working copy on top. Once a task is marked `DONE`, `tt task checkin` will automatically mark the corresponding `subtask:` entry in the parent's frontmatter as `[x]` when the handoff is created (see §6.5).

**Hooks:** Runs **pre-complete** (blocking) before any VCS operation, and **post-complete** (optional) after success. Both run in the target task worktree.

### 6.5 Checkin and publishing

Two separate commands handle merging work into a target branch, depending on whether the source is a task branch (which has a parent task) or a project branch (a parentless root):

- **`tt task checkin`** — for task branches only. Merges into the auto-detected parent branch. Rejects project branches with a clear error.
- **`tt task publish`** — for project branches only. Merges into an externally specified `--target` branch (e.g. `main`). Rejects task branches with a clear error.

#### `tt task checkin` (task branches)

`tt task checkin` merges the current task branch's work (or the task given by `<task-id>`) into its parent branch. An optional `<task-id>` positional argument may be provided to check in a task from any workspace; if omitted, the current branch is used. `--worktree=<path>` disambiguates when the child task has multiple worktrees. If the parent branch has multiple worktrees, checkin must be run from within the task's own worktree (the parent workspace is not disambiguated by `--worktree`).

The command supports two modes based on the task's current `status`:

- **Partial checkin** (task status `IN-PROGRESS`): Shares work-in-progress with the parent so it can be propagated to siblings, without marking the task as done. The user is switched to the parent worktree, the same as a complete checkin.
- **Complete checkin** (task status `DONE`): Marks the `subtask:` entry as done in the parent frontmatter and switches the user to the parent worktree. Use `tt task complete` (or pass `--complete`) to transition to `DONE` first.

With `--complete`: if the task is not already `DONE`, first runs `tt task complete` (subject to its preconditions, including the incomplete-children check), then proceeds with checkin.

In both modes, with `--rebase` or `--merge`, the tool first propagates from the parent into the current (child) branch; if propagation cannot complete without conflicts, the command bails unless `--force` is used.

**Handoff commit.** `tt task checkin` always creates a **handoff commit** as a child of the current task bookmark commit. The child branch bookmark does **not** advance to the handoff commit; it remains at the current bookmark. The handoff commit is used as the merge source for merging into the parent. Handoff commits are not on the mainline child branch and are ignored during propagation (see §6.8).

The handoff commit contains:

1. `TASK.md` rewritten to point to the parent task's task file (`rm TASK.md && ln -s .tt/task/<parent-slug>/TASK.md TASK.md`), resolving the TASK.md conflict with the parent branch.
2. If `--context <markdown>` is provided: a new context file is created in the parent task directory (`.tt/task/<parent-slug>/context/<ctx-slug>-<ctx-hex>.md`) with title derived from the child task title, and a corresponding `context: context/<ctx-slug>-<ctx-hex>` entry is added to the parent task file's frontmatter.
3. The corresponding `subtask:` entry in the parent task file's frontmatter is updated to reflect the child's current status: `subtask: [x] <task-id>` if `DONE`, or `subtask: [-] <task-id>` if `IN-PROGRESS`.

The handoff commit is described as `[tt:task:<task-id>:handoff] <task-title>`.

**Merging into the parent.** After the handoff commit is created, the tool locates the parent task worktree (creating and initializing it if necessary) and merges the handoff commit into the parent branch. The resulting merge commit is described as `[tt:task:<task-id>:checkin] <task-title>`. The parent branch bookmark advances to this merge commit.

**After checkin:**
- **Partial checkin (task status `IN-PROGRESS`):** The tool switches the worktree to the parent (updates `HEAD` symlink). The child bookmark has not moved. The parent now contains the merged handoff commit and sibling branches can be propagated.
- **Complete checkin (task status `DONE`):** The tool switches the worktree to the parent (updates `HEAD` symlink, deletes the child worktree if it was dedicated and `--retain-worktree` was not passed).

Merge conflicts in the working copy or other `.tt/` files must be resolved manually; for `TASK.md`, the intended resolution is to keep the parent's version.

#### `tt task publish` (project branches)

`tt task publish` merges a project branch's work into an external delivery branch (e.g. `main`). The `--target <branch>` argument is required. The project branch bookmark does **not** advance; only the target bookmark moves. The user **remains on the project branch** after publishing (no workspace switch).

**Publish commit.** Like `tt task checkin`'s handoff, `tt task publish` creates an off-mainline merge-source commit as a child of the project bookmark (the project bookmark does not advance to it). It removes the `TASK.md` root symlink and the entire `.tt/task/` directory from the working tree. Task files are development-only scaffolding; they must not land on the delivery branch. The `.tt/config.toml` workspace configuration file is not removed. The `--context` option is not supported (there is no parent task file to attach context to). The task-file diff validation (see §6.6) does not apply to `tt task publish`.

The publish commit is described as `[tt:task:<project-id>:handoff] <project-title>`.

**Merging into the target.** After the handoff commit is created, the tool merges it into the target branch. The resulting merge commit is described as `[tt:task:<project-id>:publish] <project-title>`. The target branch bookmark advances to this merge commit.

With `--rebase` or `--merge`, the tool first propagates from the target into the project branch before publishing; if propagation cannot complete without conflicts, the command bails unless `--force` is used.

### 6.6 Checkin validation

Before attempting any merge, `tt task checkin` performs validation and refuses if any check fails. The **unmerged range** is the set of commits on the child branch that are not yet in the parent's ancestry (commits since the last handoff commit, if any, or all commits on the child branch if no prior checkin has occurred). Checks include:

- Bookmark is up to date (implicit branch only): no commits exist between the task bookmark tip and the working-copy parent (`@-`). Only enforced when `tt task checkin` is called without an explicit `<task-id>` argument; bypassed by passing `<task-id>` explicitly.
- Working copy is clean
- Current branch is a task branch (not a project branch — use `tt task publish` for project branches)
- Current task has exactly one parent
- No conflicts with parent once the handoff commit has been applied (unless `--force`), or after the optional pre-checkin propagate step when using `--rebase`/`--merge`
- No modifications to non-editable task files in the unmerged range: only the current task file may be modified by the user. Any changes to any other `.tt/task` file in the unmerged range cause checkin to abort. (The parent task file is updated by the tool itself via the `[tt:task:<id>:handoff]` and `[tt:task:<id>:checkin]` commits, which are on the parent branch and are not part of the child's unmerged range.)
- The only change to `TASK.md` in the unmerged range from the child is the symlink pointing to the child's task file, then reverted by the handoff commit

On failure, `tt task checkin` aborts with an error and leaves the repository unchanged. Implementations may add further checks via hooks.

`tt task publish` does not perform task-file diff validation (project branches legitimately accumulate child task files from prior child checkins).

### 6.7 Task reorder

Child tasks are ordered via the current task file's `subtask:` frontmatter. **`tt task reorder <task-id> <modifier>`** reorders a direct child; modifier is `--up`, `--down`, `--after <other-task-id>`, or `--before <other-task-id>` (mutually exclusive).

### 6.9 Delete (`tt task delete`)

`tt task delete` removes a task and its entire descendant subtree from the parent branch. It is the canonical mechanism for purging a task from the project: after this command, the task is no longer discoverable via `tt task tree` because its `subtask:` entry is gone from the parent task file.

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
7. Remove the top-level task directory and all descendant task directories present on the parent branch (best-effort via `rm -rf`).
8. Commit: `[tt:task:<task-id>:delete] <title>`. Advance the parent bookmark to this commit.
9. Leave a clean open WC in the target workspace (`jj new '@'`).
10. Bulk delete bookmarks: run `jj bookmark delete` for every task in the subtree (root + all descendants). Log a warning for any that cannot be deleted.
11. For each task in the subtree: if a dedicated workspace exists at `<workspace-dir>/<task-id>/`, run `jj workspace forget <name>` to deregister it from jj, but **do not delete the files**. Alert the user that the workspace directory still exists and must be cleaned up manually.
12. Run **post-delete** hook (non-blocking).

**Delegation from `tt task checkin --delete`:** When `tt task checkin` is run with `--delete`, it first performs the normal checkin (handoff + merge commits on the parent branch), then invokes `tt task delete` on the same task. This produces two commits on the parent branch: the `[tt:task:<id>:checkin]` commit from checkin, followed by the `[tt:task:<id>:delete]` commit from delete. All subtree bookmarks are deleted after the `[tt:task:<id>:delete]` commit.

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

### 6.10 Task rename (`tt task rename`)

`tt task rename` changes the human-readable slug portion of a task or project ID while preserving the hex suffix. For example, `task/old-name-abc123` becomes `task/new-name-abc123`.

**Options:**

```
--slug <new-slug>      New slug (required)
--task <task-id>      Task to rename (default: current task)
--repo PATH           Repository root (default: walk up from CWD to find .jj)
--workspace-dir PATH  Virtual project dir
```

**Rename operations (summary):**

1. **Parent branch update (if parent exists):** Edits the parent branch tip in place — renames `.tt/task/<old-slug>-<hex>/` → `.tt/task/<new-slug>-<hex>/` and updates the `subtask:` reference from the old ID to the new ID, then commits. This triggers jj's auto-rebase of all descendant commits. The parent bookmark is advanced.
2. **Bookmark rename:** Uses `jj bookmark rename <old-id> <new-id>` to rename the bookmark in jj.
3. **Conflict sweep:** Iterates the task's unmerged range oldest-to-newest. For each commit, writes the pre-saved content back to the new directory path and removes the old directory (which may carry jj conflict markers after the auto-rebase). Symlink `TASK.md` is updated if it points to the old path.

The four-phase VCS algorithm is described in detail in §6.10.1.

**Preconditions:**

- Working copy must be clean.
- New slug must pass slug validation (lowercase alphanumeric and hyphens, no leading/trailing/consecutive hyphens).
- New task ID must not conflict with an existing bookmark.

**Parentless tasks:** If the task has no parent (e.g., a project or orphaned task), the command proceeds with bookmark and directory rename only; no parent update is performed.

**Idempotency:** If the new slug is identical to the current slug, the command succeeds silently with no changes.

**Output:** "Task renamed: <old-id> > <new-id>" on success.

#### 6.10.1 VCS mechanics of rename

Renaming a task is more involved than it first appears because the task directory `.tt/task/<old-slug>-<hex>/` exists verbatim on **both** the parent branch tip and the task branch tip (and on every unmerged commit in the task's own range). This section explains why, and describes the algorithm the implementation uses to rename correctly across the entire commit graph.

**Why the directory appears on both branches.** When `tt task create` creates a child task, it does the following (in order):

1. Creates a commit on the **parent branch** that both creates `.tt/task/<old-slug>-<hex>/TASK.md` and registers the child in the parent's `subtask:` frontmatter. The parent bookmark advances to this commit.
2. Forks the **child branch** from that same parent commit, so the child inherits the stub directory from the start.

The stub directory therefore exists unchanged on both branch tips and on every commit in the child's unmerged range (commits that are ancestors of the child bookmark but not yet in the parent's ancestry). The rename must be consistent across all of these commits simultaneously.

**Why a naive rename fails.** A naïve approach — rename the directory in the working copy, then rename the bookmark — fails in two ways:

1. The parent branch's copy of the directory is never updated, so the parent tip still has `.tt/task/<old-slug>-<hex>/TASK.md`. Any subsequent rebase or merge between the task branch and the parent will produce path conflicts.
2. jj manages the working copy. After performing the `mv` in the working copy, calling `jj new <task-branch>` causes jj to reset the working copy to the task branch's tree, silently discarding the rename.

**Why rebasing the task branch onto the renamed parent produces conflicts.** Even if the parent branch is correctly updated first, jj's 3-way rebase produces conflicts on every commit in the task's unmerged range that modified any file under `.tt/task/<old-slug>-<hex>/`:

- **base** (merge base — the parent commit before the rename): has `.tt/task/<old-slug>-<hex>/`
- **ours** (the task branch commit): modified files under the old path
- **theirs** (the updated parent): has `.tt/task/<new-slug>-<hex>/`, no `.tt/task/<old-slug>-<hex>/`

Because "theirs" deleted the old directory relative to the base, and "ours" modified it, jj produces a `2-sided conflict including 1 deletion` on every affected file. Iterating newest-to-oldest compounds the problem: each edit triggers another auto-rebase of all descendants.

**The correct algorithm.** The implementation uses the following four-phase approach:

**Phase 0 — Pre-save.** Before any jj operation, capture the full content of every file under `.tt/task/<old-slug>-<hex>/` for every commit in the task's unmerged range (`::task-branch ~ ::parent-branch`), storing them keyed by change ID in a temporary directory. The `--at-operation` jj flag (pointing at the operation ID captured before any edits) is used to read file content from the pre-rename state. This is essential: once the parent rename fires and jj auto-rebases all descendants, conflict markers are injected into the affected files and `jj file show` can no longer return clean content.

**Phase 1 — Edit the parent branch in place.** Use `jj edit <parent-branch>` to check out the parent branch tip directly, then:

1. `mv .tt/task/<old-slug>-<hex>/ .tt/task/<new-slug>-<hex>/` — rename the entire directory tree on disk.
2. Update the `subtask:` reference in the parent's own TASK.md from the old ID to the new ID.
3. `jj commit` — jj auto-snapshots the `mv` before committing. Advance the parent bookmark to `@-` (the new commit).

After the commit, jj's auto-rebase fires immediately: all descendant commits — including every commit in the task's unmerged range — are rebased onto the updated parent. Because "theirs" (the new parent) renamed the directory and the task-range commits modified files under the old path, every task-range commit that touched the directory acquires a conflict.

**Phase 2 — Rename the bookmark.** `jj bookmark rename <old-id> <new-id>`. Change IDs are stable across rebases, so the bookmark can be renamed at any point; doing it here (before the sweep) allows Phase 3 to derive the range via `::new-id ~ ::parent`.

**Phase 3 — Sweep oldest-to-newest.** Re-derive the unmerged range (using the new bookmark name; change IDs are stable). Iterate **oldest-to-newest**:

1. `jj edit <change-id>` — check out this commit. (jj auto-snapshots and auto-rebases as we move through the range.)
2. Write the pre-saved file content back to `.tt/task/<new-slug>-<hex>/` (creating directories as needed). This places the correct final content into the new path.
3. `rm -rf .tt/task/<old-slug>-<hex>/` — remove the old directory, which may be present either as a plain directory (for commits that didn't touch the task directory) or as a conflict-marker directory (for commits that did).
4. If a `TASK.md` root symlink exists and points into the old path, update it to point to the new path.

The key insight is that the pre-saved content is the correct desired content for each commit: it is the file's state as it existed in that commit before the rename, which is exactly what the renamed commit should contain (just at the new path). Writing it back resolves the conflict without needing to parse conflict markers.

The oldest-to-newest ordering is critical. When commit `C` is edited and its conflicts resolved, jj immediately auto-rebases all of `C`'s descendants. By the time we call `jj edit` on the next commit `D`, jj has already rebased `D` onto the fixed `C`. Processing in the reverse order would cause each fix to be immediately rebased away by the subsequent edit.

**Why sub-task branches auto-resolve.** Sub-task branches (branches whose base is within the task's unmerged range) do not need a separate sweep. After Phase 3 fixes commit `C`, jj auto-rebases all of `C`'s descendants, including any sub-task commits. Those sub-task commits never directly modified files under `.tt/task/<old-slug>-<hex>/`, so their 3-way merge sees:

- **base**: old `C` (has the old path)
- **ours**: sub-task diff (did not touch the task directory)
- **theirs**: new `C` (has the new path, no old path)

Because "ours == base" (the sub-task commit left the task directory unchanged), jj cleanly takes "theirs" — the rename propagates to sub-task branches automatically.

### 6.11 Task move (`tt task move`)

`tt task move` reparents a task by changing its parent in the task hierarchy.

**Options:**

```
[--task <task-id>]              Task to move (default: current task)
--parent <parent-task-id>       New parent (required)
--repo PATH                     Repository root (default: walk up to .jj)
--workspace-dir PATH            Virtual project dir
```

**Move operations (in order):**

1. **Remove from old parent:** Creates a `Move task: <title> (<task-id>)` commit on the old parent branch that removes the `subtask:` entry for the task **and** deletes the task's stub directory (`.tt/task/<slug>-<hex>/`). Old parent bookmark advances.
2. **Add to new parent:** Creates a `Move task: <title> (<task-id>)` commit on the new parent branch that adds `subtask: [ ] <task-id>` to the new parent's frontmatter **and** copies the task's stub TASK.md (read from the old parent's pre-Step-1 commit ID) into `.tt/task/<slug>-<hex>/TASK.md` on the new parent. New parent bookmark advances.
3. **Rebase task branch:** Rebases the task's unmerged range (`roots(::task ~ ::old_parent)`) onto the new parent's bookmark tip. If there are no unmerged commits (e.g., the task branch has no commits beyond the old parent's ancestry), this step is skipped.

**Stub file handling.** `tt task create` always places the task's stub TASK.md on the parent branch. `tt task move` mirrors this invariant: the stub is removed from the old parent (Step 1) and placed on the new parent (Step 2). This is also essential for conflict-free rebasing in Step 3: jj performs a 3-way merge when rebasing, using the old parent tip as the base. If the new parent lacks the stub, jj sees a delete-vs-modify conflict in the task's TASK.md. By placing a byte-identical copy of the stub on the new parent, jj sees "theirs == base" and cleanly takes the task branch's own TASK.md without conflict. The stub is read from the old parent's commit ID (captured before Step 1 advances the bookmark), ensuring the content is byte-identical to what the rebase will use as its merge base.

**Preconditions:**

- Working copy (current worktree) must be clean.
- `--parent` is required.
- Both the task and the new parent must exist as valid task/project bookmarks.
- The task must have exactly one current parent (found via `subtask:` traversal). Parentless tasks (projects) cannot be moved.
- The new parent must not be the same as the current parent.
- Moving the task must not create a cycle (the new parent must not be a descendant of the task).

**Restore behavior:** When moving a task that is not currently checked out (`@` is not a descendant of the task's branch), the working copy's change ID is captured before the move and restored after the rebase completes. Because jj tracks change IDs across rebases, the restored revision always reflects the post-rebase state if it was affected.

**Output:** Confirmation lines to stderr: `Moved: <task-id>`, `  Old parent: <old-parent>`, `  New parent: <new-parent>`.

### 6.12 Transaction history and undo

Every mutating `tt` command records a **transaction** in `.tt/history` so that `tt history undo` can restore the jj repository to the state it was in before that command ran.

#### 6.12.1 History log file

**Location:** `.tt/history` in the repository root.

**Format:** One line per completed transaction:

```
<before-op-id>:<after-op-id>
```

- `<before-op-id>` — the jj operation ID captured immediately before the command began making changes.
- `<after-op-id>` — the jj operation ID captured immediately after all changes completed successfully.
- An **in-progress transaction** has an empty `<after-op-id>` (the line ends with `:`): `<before-op-id>:`

**Tracking:** `.tt/.gitignore` (containing `/history` and `/workspace`) is committed by `tt workspace init` so that the history log and workspace symlink are never tracked by jj. The log accumulates indefinitely (unlimited retention).

#### 6.12.2 Transaction lifecycle

The transaction API is implemented in `scripts/cli/lib/common.sh` as three functions:

- **`tt_begin_transaction REPO`** — Called at the start of a mutating command, before the first jj operation. Captures the current jj operation ID as `<before-op-id>`, appends `<before-op-id>:` (in-progress) to `.tt/history`, exports `TT_TRANSACTION_ID=<before-op-id>`, marks this process as the owner via the non-exported `_TT_TRANSACTION_OWNER=true`, and sets an `ERR` trap to call `tt_rollback_transaction` on failure.

  **Nested sub-commands:** When a top-level command delegates to a sub-command (e.g. `tt task create --checkout` calling `tt task checkout` internally), the sub-command inherits `TT_TRANSACTION_ID` via the environment. `tt_begin_transaction` detects this and returns immediately (no-op). Because `_TT_TRANSACTION_OWNER` is not exported, the sub-command's `tt_commit_transaction` and `tt_rollback_transaction` calls are also no-ops — only the top-level command owns the transaction.

- **`tt_commit_transaction REPO`** — Called at the successful end of a command, after all operations (including follow-on actions like `--propagate` and `--checkout`) complete. Captures the current jj operation ID as `<after-op-id>`, replaces the last line of `.tt/history` (`<before-op-id>:`) with `<before-op-id>:<after-op-id>`, and clears the `ERR` trap. No-op if not the transaction owner.

- **`tt_rollback_transaction REPO`** — Called automatically by the `ERR` trap if any command in the script exits non-zero. Runs `jj op restore <before-op-id>` to restore the repository to its pre-command state, removes the in-progress line from `.tt/history`, and clears the `ERR` trap. No-op if not the transaction owner.

**Failure semantics:** A failed command (including follow-on actions such as `--propagate` or `--checkout`) triggers `tt_rollback_transaction`, which restores the repository atomically. The entire command's effect — including any successful intermediate steps — is undone.

**Stale transactions:** If a `tt` command is killed mid-execution (crash, `Ctrl-C`, etc.) and the `ERR` trap did not fire, the history log may be left with an in-progress entry (`<before-op-id>:`). Subsequent `tt` commands will detect this and refuse to start a new transaction, printing:

```
Error: Another tt command is in progress (incomplete transaction).
  To revert a crashed process, run: tt history undo --force
  Or to keep the current state: tt history unlock --force
```

Running `tt history undo --force` reverts the stale in-progress transaction. Alternatively, `tt history unlock --force` clears the lock without reverting the repository state — use this when the jj repository is already in an acceptable state and you simply want to unblock future `tt` commands.

#### 6.12.3 `tt history undo` command

`tt history undo [--force] [--repo PATH]` (aliased to `tt undo`) reverts the jj repository to the state before the most recently recorded `tt` command.

**Behavior:**

1. Read the last line of `.tt/history`.
2. Run safety checks (all bypassed by `--force`):
   - Last line has a non-empty `<after-op-id>` (no in-progress transaction).
   - Current jj operation ID equals `<after-op-id>` (no out-of-band modifications).
   - Working copy is clean.
3. Log the outgoing operation ID to stderr so the user can manually redo: `jj op restore <after-op-id>`.
4. Set an `ERR` trap to restore back to the current state if `jj op restore` itself fails.
5. Run `jj op restore <before-op-id>`.
6. Remove the last line from `.tt/history`.
7. Patch the now-last history entry's `<after-op-id>` to the current (post-restore) jj operation ID. This is necessary because `jj op restore` creates a **new** jj operation — the repository state is identical to the target, but the operation ID differs. Without this patch, the history chain would break and consecutive `tt undo` invocations would fail the safety check in step 2.

**Multiple undos:** Each invocation pops one entry from the history and patches the previous entry's after-op, so repeated calls go progressively further back with no safety-check failures.

**No redo:** There is no `tt history redo` command. The outgoing operation ID (logged in step 3) allows manual redo via `jj op restore`.

**`tt history undo` is not itself transactional:** The undo command does not write to `.tt/history`. This means you cannot "undo the undo" via `tt history undo`; use `jj op restore <after-op-id>` from the logged output instead.

#### 6.12.4 `tt history unlock` command

`tt history unlock [--force] [--repo PATH]` clears a stale in-progress transaction from `.tt/history` without reverting the jj repository state.

**Behavior:**

1. If the history file does not exist: exit 1 with an error message.
2. If the history file is empty or the last entry has a non-empty `<after-op-id>`: exit 0 silently (no-op).
3. If the last entry has an empty `<after-op-id>` (in-progress) and `--force` is not given: exit 1 with a message directing the user to use `--force` or `tt history undo --force`.
4. With `--force` and an in-progress entry: capture the current jj operation ID and replace the last line `<before-op-id>:` with `<before-op-id>:<current-op-id>`. The jj repository state is **not** modified.

**Result:** The transaction entry's `<after-op-id>` reflects the actual current jj operation, accurately representing the state of the repository at the time the lock was cleared. Future `tt_begin_transaction` calls will no longer see an in-progress entry and will start normally.

**`tt history unlock` is not itself transactional:** The unlock command does not write a new transaction entry to `.tt/history`. It only modifies the existing in-progress entry.

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

1. **Initialize** — `tt workspace init <path-to-repo> <path-to-virtual-project-folder> [--task-prefix <prefix>] [--project-prefix <prefix>] [--force]`. The tool checks that the repo working directory is clean and that `.tt` does not exist as a non-directory entry in the repo root. It creates the virtual project directory, `.tt/config.toml` (task prefix default `task/`, project prefix default `project/`), a `.tt/workspace` symlink pointing to the virtual project directory, a `.tt/.gitignore` (containing `/history` and `/workspace`), and a `HEAD` symlink in the virtual directory that initially points to the repo and is updated on each checkout. It creates a `[tt:workspace:init] Create workspace` commit in the jj repository (`.tt/config.toml` and `.tt/.gitignore` are tracked; `.tt/history` and `.tt/workspace` are gitignored). No named bookmark is created by this command. See §5.1 and §6.2.

2. **Create a project** — `tt task create --project [--target <commit-rev>] [--slug <slug>] [--title <title>] [--label <label> ...]`. The tool prompts for title (and autosuggested branch name) if needed, reads the task body from stdin (via pipe or redirect) if stdin is not a terminal; otherwise opens an editor for body input. Creates the project branch from the `--target` VCS revision if specified, defaulting to the current revision, and creates the project task file. If the target revision itself exists within a task tree, the tool notifies the user and refuses to proceed. See §6.1.

3. **Create a task** — `tt task create [--parent <parent-task-id>] [--slug <slug>] [--title <title>] [--label <label> ...] [--propagate [--rebase | --merge] [--shallow] [--force]] [--checkout [--worktree[=<path>] [--switch]]]`. The tool checks the parent's workspace is clean, prompts for title (and autosuggested branch name) if needed, reads the task body from stdin (via pipe or redirect) if stdin is not a terminal; otherwise opens an editor for body input. Locates the parent branch (default current branch; parent can be a project or task branch). Creates a single commit on the parent's branch that both creates the new task file (with `status: TODO`) and adds `subtask: [ ] <task-id>` to the parent's task file; advances the parent bookmark to this commit. Forks the child task branch as an empty commit from the updated parent tip. The `TASK.md` symlink is created at first checkout. With `--propagate`, it runs `tt task propagate --from <parent>` with any given flags to bring sibling branches up to date with the parent's new commit. With `--checkout`, it runs `tt task checkout` on the newly created task before exiting; `--worktree[=<path>]` passes through to checkout. See §6.1.

4. **Begin a task** — `tt task checkout <task-id> [--worktree [=<path>] [--switch]] [--force]`. The tool checks the target workspace is clean (or clobbers changes if `--force` is specified), verifies the task or project branch exists, uses or creates the appropriate workspace per §6.2, sets task status to IN-PROGRESS in a new commit if the task status is currently TODO, runs `setup` when initializing a new worktree, and updates the `HEAD` symlink (unless `--worktree` is used without `--switch`). See §6.2.

5. **Work on the task** — User commits changes on the branch and accumulates context in `./TASK.md`.
   - **Add context** — Run `tt task context add [--title <title>]` and provide context body via stdin (e.g., `cat ./notes.md | tt task context add --title "Research notes"`). If stdin is a terminal, an editor is opened for body input. Creates a commit. See §5.2.
   - **Read context** — Run `tt task context get [<context-id>...]` to print the raw contents of one or more context files for the current task to stdout. See §5.2.
   - **Checkpoint** — Run `tt task checkpoint [--message <message>]` to create a `[tt:task:<task-id>:checkpoint] <message>` commit and advance the task bookmark. See §6.3.

6. **Complete the task** — `tt task complete [<task-id>] [--worktree=<path>] [--force]`. When work is done, marks the task `DONE` with a `[tt:task:<task-id>:complete] <title>` commit and advances the task bookmark. Requires all child tasks to be done unless `--force`. Can be invoked from any workspace by passing `<task-id>`. See §6.4.

7. **Finish the task** — For task branches (those with a parent): `tt task checkin [<task-id>] [--rebase | --merge] [--force] [--delete] [--worktree=<path>] [--propagate [...]]`. The tool runs checkin validation (§6.6); if using `--rebase`/`--merge`, first propagates from parent and bails on conflict unless `--force`. It creates the handoff commit, merges into the parent, then switches to the parent worktree and cleans up the child worktree. Can be invoked from any workspace by passing `<task-id>`. If merge conflicts occur (e.g. in other `.tt/` files), the user resolves manually; for `TASK.md`, keep the parent's version. With `--propagate`, also runs `tt task propagate --from <parent>` after the merge completes. For project branches (parentless roots): `tt task publish [<project-id>] --target <branch> [--rebase | --merge] [--force]`. Creates a handoff commit that strips task scaffolding files, merges into `--target`, and leaves the user on the project branch (no workspace switch). See §6.5 and §6.6.

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

   - **Merged (done):** Some task or project branch **B** has an owner task file whose frontmatter contains `subtask: [x] <T>`. That branch B is the parent task's branch (the one that received the checkin). → The **canonical branch** for T is **B**.
   - **Not merged (ongoing):** No branch's owner task file contains `subtask: [x] <T>`. → The **canonical branch** for T is **T's own branch**.
   - **Deleted:** Task was removed via `tt task delete`; no branch contains a `subtask:` entry for T. → T is not discovered and does not appear in the todo list.
   - Implementation: for each task T, scan all task and project branches B; on B, read the owner task file. If any such file contains `subtask: [x] <T>`, then T is merged and the canonical branch for T is B; otherwise the canonical branch for T is T's own branch.

   Once the canonical branch is determined, the task file path is derived from T's ID: strip the task or project prefix from the ID to get `<slug>-<hex>`, then read `.tt/task/<slug>-<hex>/TASK.md` on the canonical branch. Task metadata (title, status, subtask list) is read exclusively from this file. Task titles are never stored inline in `subtask:` entries; they are always looked up from the task file on the canonical branch.

4. **Orphan detection (when `--detached` is present)**

   - Enumerate all task branches (names matching `<task_prefix><slug>-<hex>`).
   - Compute the set of task IDs reachable from any project's subtree (from step 2).
   - Orphaned tasks = task branches whose ID is not in that set. These are added as a flat list to the "Tasks with no project (detached)" section.

5. **Filter sections and build output**

   - Filtering: If the user specified `--project <project-id>` (one or more), only emit sections for those projects. If the user specified `--detached`, include the detached section (if it has any orphaned tasks). If `--all` is specified, show all projects and the detached section. If no filter is specified, emit all project sections, but not the detached section.
   - Order projects within output by branch name (lexicographical). Order tasks within each project section by the order of `subtask:` entries in the project's task file.

6. **Emit the markdown**

   - For each project section to be output, emit the project task as an unindented bullet entry, then recurse into each child's children. Under the detached section, each orphaned task is a top-level bullet nested under the detached section header (they have no parent in the discovered tree). Sibling order is always the order of `subtask:` entries in the parent task file.
   - For each task line, output: checkbox from status (`[ ]` / `[-]` / `[x]`); link `[<prefix><slug>-<hex>](.tt/task/<slug>-<hex>/TASK.md)`; title (read from `title:` in the task file on the canonical branch, as determined in step 3). Indentation reflects hierarchy.

**End-to-end summary:** Enumerate project branches → for each project traverse subtree via `subtask:` entries → for each discovered task T find where to read T's file (merged vs ongoing) → if `--detached`, find orphaned task branches and add to detached section → filter sections by `--project`/`--detached` → for each section emit header and walk tree depth-first (checkbox + link + title per task) → output markdown.

### A.2 Generating the focused todo list for the current task

**Input:** The current branch (or current task ID). Resolve to a task or project branch **T**; if the current branch is not a task or project branch, show a message explaining this.

1. **Resolve current task:** From the current branch, determine the task or project branch **T** (e.g. current branch is a task branch or project branch, or the branch name identifies the entity).
2. **Walk to project:** From **T**, walk backwards via the frontmatter-defined parent chain (the task or project that lists this one in `subtask:`) to the top-level task. If **T** is already a project, the path is just **T**. Otherwise collect the path: **T**, its parent task, and so on up to the project.
3. **Load task files:** For each task on this path, choose where to read its task file using the same rule as the full algorithm (merged = some branch's owner task file has `subtask: [x] <T>` → read from that branch; else read from task branch). Load child order from each task's `subtask:` list.
4. **Order and emit:** Order and emit markdown in the same format as the full list, but only for this subset of tasks. Indentation and hierarchy are preserved for the focused slice.

**Output:** Same markdown format as the full todo list. Useful for establishing context without pulling in the entire project tree.

---

## 10. Testing

### 10.1 Test harness

The test harness (`scripts/harness/harness.sh`) is a sourceable bash library providing:

- **Workspace setup:** `setup_workspace` creates a fresh jj repository with `tt workspace init` in a temporary directory, providing an isolated environment for each test. The workspace includes a `.tt/workspace` symlink pointing to the virtual project directory (created automatically by `workspace init`) for worktree-related tests.
- **Workflow helpers:** `create_project`, `create_task`, `create_task_under`, `checkout_task`, `checkpoint_task`, `complete_task`, `checkin_task`, `edit_file`, `append_file` — convenience wrappers for common workflow steps.
- **VCS introspection:** `get_jj_op`, `get_wc_commit`, `get_bookmark_commit`, `get_commit_message`, `get_modified_files`, `is_wc_clean`, `bookmark_exists`, `is_vcs_ancestor`, `file_exists_at_rev`, and more.
- **Generic assertions:** `assert_eq`, `assert_neq`, `assert_contains`, `assert_not_contains`, `assert_matches`, `assert_file_exists`, `assert_success`, `assert_failure`, `assert_output_empty`, `assert_line_count`, and more.
- **VCS assertions:** `assert_bookmark_exists`, `assert_wc_clean`, `assert_commit_message`, `assert_file_on_branch`, `assert_no_conflicts`, `assert_is_ancestor`, and more.
- **tt-specific assertions:** `assert_task_status`, `assert_task_title`, `assert_task_label`, `assert_subtask_entry`, `assert_context_entry`, `assert_current_task`, and more.
- **Transaction assertions:** `assert_history_count`, `assert_history_integrity`, `assert_no_pending_transaction`.
- **Integrity:** `assert_tt_workspace_integrity` — comprehensive structural check of all task files, subtask references, context references, and transaction state.
- **Summary:** `suite_summary` prints pass/fail/skip counts and exits non-zero on failures.

### 10.2 Test structure

Test suites are co-located with their command implementations as `*.test.sh` files:

```
scripts/
├── harness/
│   └── harness.sh                    # Reusable test harness (sourced by each test file)
├── test                              # Top-level runner
└── cli/                              # Test suites for individual tt commands
    └── task/
        └── **/
            └── *.test.sh
```

Each test file is a standalone bash script that sources the harness, defines `test_*` functions, and calls `run_tests "SUITE TITLE"` at the end to run them.

When invoked via the top-level runner, test declarations are first collected by the runner and then invoked individually.

### 10.3 Running tests

```bash
scripts/test                                         # run all test suites serially
scripts/test    --parallel                           # run all suites and tests in parallel
scripts/test    checkpoint                           # suite filter: suites matching "checkpoint"
scripts/test    "context/"                           # suite filter: all context command suites
scripts/test    --filter basic                       # test filter: tests whose label matches "basic"
scripts/test    --filter 'partial|complete'          # test filter: ERE — matches either word
scripts/test    --filter basic --filter force        # test filter: OR across multiple patterns
scripts/test    task/checkout --filter non.existent  # combine suite and test filters
bash scripts/cli/task/checkpoint.test.sh             # run a single suite directly
```

**Suite filters** (positional arguments) are substring-matched against the suite file path relative to `scripts/cli/`.

**Test filters** (`--filter`) are ERE patterns matched against the full test label `"SUITE TITLE: test_function_name"`. Multiple `--filter` flags are OR-ed. Filtered-out tests are excluded from `[n/N]` numbering and summary totals.

### 10.4 Test coverage

Every command in the CLI has a dedicated test suite. Edge cases requiring interactive input (editor prompts) cannot be tested non-interactively but all commands accept `--message`/`--title`/`--slug` flags or stdin pipes as alternatives.
