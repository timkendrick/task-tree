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

### Worktrees and the canonical repository

The **canonical repository** is the original repository directory. `tt workspace repo` prints its path. A **worktree** is any other jj workspace of the same repository. Each worktree has its own working copy. `tt task checkout --worktree` creates a worktree for a task, and names its jj workspace after the task.

tt supports two ways of working:

- **Without worktrees.** All work happens in the canonical repository. Each `tt task checkout` switches it to another task.
- **With worktrees.** Each task has its own worktree. The canonical repository stays wherever the user left it.

tt therefore acts on the canonical repository only when a command runs from it, or when a command names it explicitly. A command run from a worktree does not select the canonical repository by itself:

- `tt task checkout --worktree` never reuses the canonical repository, even when it has the task checked out.
- `tt task checkin` uses the parent task's worktree. It falls back to the canonical repository only when no worktree has the parent checked out.
- `tt worktree sync --all` brings the canonical repository forward only when it runs from the canonical repository.
- Out-of-sync warnings never name the canonical repository.
- `tt worktree list` does not list the canonical repository.

Some `tt worktree` commands accept the canonical repository explicitly. `tt worktree switch <path>` and `tt worktree sync <path>` accept its path. `tt worktree refresh --root` targets it. `tt worktree active` prints it when `HEAD` points to it. `tt worktree show` and `tt worktree delete` reject it.

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

- A GFM checkbox: To-do `[ ]`, In progress `[-]`, Done `[x]`, Unknown `[?]`. An 'unknown' status denotes a task whose task file either cannot be retrieved on any candidate branch, or whose task file has no parseable `status:` field.
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

**Frontmatter block delimitation.** The frontmatter is strictly the *leading* delimited block: the file must begin with a `---` line, and the block ends at the next `---` line. A file that does not begin with `---` has no frontmatter at all. Any `---` lines appearing after the closing delimiter belong to the body — for example a fenced code block documenting frontmatter layout — and are never interpreted as reopening the block. Consequently `title:`, `status:`, `label:`, `context:` and `subtask:` lines in the body are inert: they are neither read as metadata nor rewritten by commands that update frontmatter. If a key that should appear at most once is duplicated within the block, the first occurrence wins.

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

All tool commands that read task file frontmatter apply the delimitation rules above uniformly, and all tool commands that mutate it maintain this field ordering automatically.

**Quoted values.** `title` is written as a double-quoted string using JSON's basic escapes: a backslash and a double quote are backslash-escaped, and a newline, carriage return, tab, backspace or form feed in the title is written as `\n`, `\r`, `\t`, `\b` or `\f`, so the value occupies one line and reads back unchanged. Readers decode those escapes (and `\/`); any other escape, `\uXXXX` included, is kept as written.

At merge time, the parent task's frontmatter is updated with the completed child (e.g. `subtask: [x] <task-id>`). The user may request full removal of the child task from the parent branch using `tt task delete` (or `tt task checkin --delete`, which runs the normal checkin and then delegates to `tt task delete`). This removes the child task directory and its `subtask:` entry from the parent's frontmatter entirely, making the task invisible in the todo list. If `--delete` is not used, the task directory remains in the repository and the `subtask: [x]` entry is preserved.

### 4.3 Metadata storage and TASK.md

Task files for ongoing tasks exist only on their respective branches; when generating the overall todo list, the task file contents must be retrieved from all the respective branches. Within a task's own branch, the task file is referenced via a `TASK.md` symbolic link in the repository root (e.g. `./TASK.md -> .tt/task/add-oauth-flow-8cf8d966/TASK.md`). When retrieving task metadata from frontmatter, only the most recent state of the task file is considered; all former revisions are ignored. Change history for a task's metadata can be tracked via the revision history of the task file.

**Invariant.** Every commit on a task's own line has `TASK.md` pointing at that task's task file. The symlink changes only at the two ends of a task branch:

- Entering the branch: the first commit of the branch points `TASK.md` at the task. For a child task this is the fork commit (`[tt:task:<task-id>:fork]`). For a parentless branch it is the `[tt:task:<id>:new]` commit (see §6.1).
- Leaving the branch: the check-in handoff commit points `TASK.md` back at the parent (see §6.5).

```
P line:  ... -- [C:create] (stub + subtask; TASK.md -> P) ------------- [C:checkin] (TASK.md -> P)
                    \                                                   /
         C line:     [C:fork] (TASK.md -> C) -- [C:edit] -- work -- [C:handoff] (TASK.md -> P)
```

Checkout never changes the symlink. A branch therefore records its own task from its first commit, whether or not it was ever checked out. Propagate preserves the invariant when it moves a child onto its parent's tip (§6.8).

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
| `tt sync` | `tt worktree sync` |
| `tt refresh` | `tt worktree refresh` |
| `tt create` | `tt task create` |
| `tt checkout` | `tt task checkout` |
| `tt checkin` | `tt task checkin` |
| `tt publish` | `tt task publish` |
| `tt show` | `tt task show` |
| `tt parent` | `tt task parent` |
| `tt find` | `tt task find` |
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
| `tt diff` | `tt task diff` |
| `tt changelog` | `tt task changelog` |
| `tt select` | `tt task select` |
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
3. **CWD walk** — walk up from the current working directory until a repository root is found.

The command exits with an error if none of these resolves to a valid repository. `tt workspace init` is exempt — it always takes the repository path as a required positional argument.

Commands that write files into commits additionally require the repository's storage backend to be Git-backed, and exit with `Unsupported repository backend: <type>` otherwise. Read-only commands are unaffected.

### 5.0.1 Diagnostic output

By default `tt` reports only its own results, and the version-control commands it runs underneath are invisible. The `TT_LOG` environment variable narrates them:

| Value | Effect |
|-------|--------|
| unset | No narration. |
| `info` | Each mutation `tt` performs on the repository is echoed as the command line that was run, followed by that command's own output. |
| `verbose` | As `info`, plus every read and every internal step of a mutation. Intended for diagnosing `tt` itself. |

Any other value — including `INFO` or `VERBOSE` — leaves narration off.

`TT_LOG` affects diagnostics only. All narration is written to stderr, and a command's stdout and exit status are identical at every level, so it is safe to enable for a command whose output is being piped or captured.

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

- **`tt workspace init <path-to-repo> <path-to-virtual-project-folder> [--task-prefix <prefix>] [--project-prefix <prefix>] [--force]`** — Initialize a task-tree project. Creates the virtual workspace directory, `.tt/config.toml` (with optional task prefix and project prefix), `.tt/.gitignore` (containing `/history` and `/workspace`), an empty `.tt/history` transaction log, a `.tt/workspace` symlink pointing to the virtual project directory, and a `HEAD` symlink in the virtual directory that initially points to the repo and is later updated to the most recently checked-out task workspace (serving as a quick link to the current development context). Creates a `[tt:workspace:init] Create workspace` commit in the jj repository (`.tt/config.toml` and `.tt/.gitignore` are committed; `.tt/history` and `.tt/workspace` are gitignored). Requires a clean working directory; aborts if `.tt` exists in the repo root as a non-directory entry (use `--force` to remove it). Unlike the branch-writing commands it does **not** refuse when the working-copy commit carries a bookmark: it advances no bookmark, and the clean-working-copy requirement means the commit holds precisely the workspace files it just wrote — while a freshly created repository commonly leaves its default bookmark sitting on the working-copy commit. With `--force`, also allows overwriting files in an already-populated virtual folder. See §9 step 1, §6.2 (HEAD symlink and `.tt/workspace`), and §6.12 (transaction history).

- **`tt workspace root [--repo PATH]`** — Print the virtual workspace directory path. Resolves and prints the path that the `.tt/workspace` symlink points to — the virtual project directory configured by `tt workspace init`. Exits with an error if the workspace has not been initialised (no `.tt/workspace` symlink present). See §5.0.

- **`tt workspace repo [--repo PATH]`** — Print the canonical repository root path. When run from a worktree (see "Worktrees and the canonical repository" in §2), prints the canonical repository root rather than the worktree root. Useful for locating shared repository resources from any worktree. See §5.0.

- **`tt worktree switch [<worktree-path>]`** — Update the virtual project's `HEAD` symlink to point to the given worktree path. If `<worktree-path>` is omitted, defaults to the worktree containing the current working directory; exits with an error if the CWD is not within a known jj workspace. Unlike `tt task checkout --switch`, this command does not create worktrees, switch VCS branches, or update task status; it only redirects `HEAD`. The path must be a worktree or the canonical repository. Runs `pre-checkout` and `post-checkout` hooks; hook env vars `TT_PREVIOUS_TASK_ID`/`TT_PREVIOUS_TASK_BRANCH` reflect the task that `HEAD` was pointing to before the switch. Output is the same confirmation as `tt task checkout`. See §6.2.

### 5.4 Task

- **`tt task create [--parent <parent-task-id> | --project [--target <commit-rev>]] [--slug <slug>] [--title <title>] [--label <label> ...] [--propagate [--rebase | --merge] [--shallow] [--force]] [--checkout [--worktree[=<path>]]] [--force]`** — Create a new task or project. With `--parent` (default: the task this worktree has checked out, per §6.2; the command fails when it holds none, since a task needs a parent): creates a commit on the parent's branch that both creates the new task stub directory (with a placeholder `title: ""`, `status: TODO`, `created`, and `updated` timestamps in `TASK.md`; the title is filled in by the subsequent edit step) and registers `subtask: [ ] <task-id>` in the parent's task file; the child branch starts from this updated parent tip on a fork commit that points the `TASK.md` symlink at the child. With `--project` (mutually exclusive with `--parent`): creates a parentless project using the project prefix; the project branch forks from `--target` if specified, else the current revision, and its first commit writes the stub task file and points `TASK.md` at it. Prompts for title if not provided. Reads the task body/description from stdin (via pipe or redirect) if stdin is not a terminal; otherwise opens an editor for body input. **`--slug` is required when stdin is not a terminal (non-interactive mode); in interactive mode the user is prompted with a suggested default derived from the title.** With `--propagate`, propagates the parent's new commit to its existing descendant branches after creation (equivalent to running `tt task propagate --from <parent>` with any given flags); supports `--rebase | --merge` (strategy; default rebase), `--shallow` (direct children only), and `--force` (proceed despite conflicts). With `--checkout`, runs `tt task checkout` on the newly created task before exiting; `--worktree[=<path>]` (only valid with `--checkout`) passes through to checkout to use or create a worktree. If the resolved parent task's status is `DONE`, the parent is first reopened by running `tt task checkout <parent-id>` (see §6.2), and the child is then created on the updated parent tip. With `--force` (outside of `--propagate`), overwrites if the child branch already exists. On success, prints the generated task ID to stdout (all other output is on stderr), allowing it to be captured or piped, e.g. `tt task checkout "$(tt task create --slug foo --title 'Foo' < ./desc.md)"`. See §6.1.

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

- **`tt task edit [<task-id>] [--title <title>] [--label <label> ...] [--delete-label <label> ...] [--repo <path>]`** — Edit the title and/or labels of a task. Reads the task body from stdin (via pipe or redirect) if stdin is not a terminal; otherwise preserves the existing body. With no metadata flags and stdin is a terminal, opens an editor pre-populated with the current body text (interactive mode). `--label` appends; `--delete-label` removes (silent no-op if absent). Refuses if the working-copy commit carries a bookmark; the working copy may otherwise hold uncommitted changes, which are never absorbed. Creates a `[tt:task:<task-id>:edit] <title>` commit directly on the task branch and advances the task bookmark. See §6.1.1.

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

- **`tt task checkout <task-id> [--worktree [=<path>] [--switch]] [--rebase | --merge] [--force]`** — Switch to the given task branch. With `--worktree`, uses or creates a worktree for that task (never the canonical repository); otherwise uses the closest ancestor task workspace or the current workspace. With `--rebase` or `--merge` (mutually exclusive), first pulls any changes from the parent task into this task by running `tt task propagate --from <parent> --to <task-id>` with the chosen strategy, before switching the working copy; only valid for task branches, since project branches have no parent. Refuses if the target workspace has local changes unless `--force`, and refuses if the invoking worktree's working-copy commit carries a bookmark. Updates task status to `IN-PROGRESS` if the task is `TODO` (first checkout) or `DONE` (reopening a completed task), creating a `[tt:task:<task-id>:checkout] <title>` commit on the task branch that changes only the status, and advancing the task bookmark; runs `setup` hook when creating a new worktree. Without `--worktree`, always updates the virtual project's `HEAD` symlink; with `--worktree`, only updates `HEAD` if `--switch` is also provided (`--switch` is only valid with `--worktree`). On success, prints the worktree path to stdout (all other output is on stderr). See §6.2.

- **`tt task checkpoint [--message <msg>] [--squash]`** — Record the current state and advance the task bookmark. Always records the working copy as a new commit described by `--message` (or by an interactively composed message; `--message` is required when stdin is not a terminal, and an empty message cancels the checkpoint), even when the working copy is empty, and advances the bookmark to it, leaving the worktree on a clean open working copy above it. With `--squash`, squashes all commits between the last bookmark and the current working copy into a single checkpoint commit (see §6.3.2). Refuses if the working-copy commit carries a bookmark, since a checkpoint records the working copy as a new commit above the branch tip rather than amending it. Prints a short confirmation on success. See §6.3. Hooks: **pre-checkpoint**, **post-checkpoint**.

- **`tt task complete [<task-id>] [--force]`** — Mark the current task (or a given task) as done. Creates a `[tt:task:<task-id>:complete] <title>` commit directly on the task branch that sets `status` to `DONE` in the task file, and advances the task bookmark to this commit. Refuses if the working-copy commit carries a bookmark; the working copy may otherwise hold uncommitted changes, which are never absorbed. Requires all child tasks to be done (every `subtask:` entry marked `[x]`) unless `--force` is specified. See §6.4. Hooks: **pre-complete** (blocking), **post-complete** (optional).

- **`tt task checkin [<task-id>] [--context <markdown>|-] [--complete] [--rebase | --merge] [--force] [--delete] [--switch] [--retain-worktree] [--worktree=<path>] [--propagate [--propagate-rebase | --propagate-merge] [--propagate-shallow] [--propagate-force] [--propagate-dry-run] [--propagate-to <child-id>]]`** — Merge the current task branch (or `<task-id>`) into its parent branch. Only valid on task branches (those with a parent); use `tt task publish` for project branches. Supports **partial checkins** (task status `IN-PROGRESS`; shares work-in-progress with the parent) and **complete checkins** (task status `DONE`; marks the task finished). Always creates a **handoff commit** (child bookmark does not advance) and merges it into the parent as `[tt:task:<task-id>:checkin] <title>`. The handoff always updates the corresponding `subtask:` entry in the parent's frontmatter to reflect the child's current status (`[x]` if `DONE`, `[-]` if `IN-PROGRESS`). The `HEAD` worktree symlink is left untouched unless `--switch` is passed, in which case it is repointed at the parent task's worktree after the merge (or at the canonical repository root reported by `tt workspace repo` if the parent task is not checked out in any worktree, so that `HEAD` is never left dangling). With `--complete`: first runs `tt task complete` if the task is not already `DONE`, then re-reads the task file so the rest of the checkin (subtask checkbox, `--delete` precondition) sees the updated `DONE` status, and proceeds with checkin. With `--context <markdown>`, creates a handoff context file on the parent task with the given text. With `--context -`, reads context from stdin. When no `--context` is given and stdin is a TTY, opens an editor for context input (empty input = no context file created). With `--delete` (requires task `status: DONE`; when combined with `--complete` the requirement is evaluated after the complete step, so `--complete --delete` works on an `IN-PROGRESS` task): after the normal checkin completes, delegates to `tt task delete` to remove the child task file and `subtask:` entry from the parent branch (two separate commits on the parent branch), and finally removes the task's dedicated worktree if it has one. Removing a worktree deletes files from disk, so checkin first holds it to the same standard as `tt worktree delete` holds its target: it refuses if the worktree has uncommitted changes, commits after the task bookmark, or files in use by another process, before making any change to the repository. `--force` proceeds instead, capturing the uncommitted work into the worktree's own working-copy commit and printing the operation ID that holds it. With `--retain-worktree`: modifies `--delete` so that the dedicated worktree is kept; the jj workspace remains registered and the files remain on disk, and the worktree checks are skipped since nothing is removed. It has no effect without `--delete`, since a checkin that is not deleting the task never removes a worktree. `--worktree=<path>` disambiguates when the child task has multiple worktrees. Runs validation (see §6.6); when called without an explicit `<task-id>`, also verifies that the task bookmark is up to date: if any commits exist between the bookmark and the working-copy parent (`@-`), the command fails with a prompt to run `tt task checkpoint` first (or to pass `<task-id>` explicitly to bypass the check). With `--rebase`/`--merge`, first propagates from parent and bails on conflict unless `--force`. With `--propagate`, after the checkin completes, runs `tt task propagate --from <parent>` to push the newly-merged parent tip down to the parent's remaining children. Accepts `--propagate-rebase | --propagate-merge` (strategy; default rebase), `--propagate-shallow` (direct children only), `--propagate-force` (proceed despite conflicts), `--propagate-dry-run` (show propagation plan without applying; the checkin itself still runs normally), and `--propagate-to <child-id>` (repeatable; limit propagation to specific children). See §6.5 and §6.6.

- **`tt task publish [<project-id>] --target <branch> [--message <msg>] [--changelog [--changelog-depth <n>]] [--force] [--repo PATH] [--workspace-dir PATH]`** — Publish a project branch's work to an external delivery branch (e.g. `main`). Only valid on project branches (parentless roots); use `tt task checkin` for task branches that have a parent. Creates a **publish commit** that removes the `TASK.md` root symlink and the entire `.tt/task/` directory from the working tree (task files are development-only scaffolding that must not land on the delivery branch; `.tt/config.toml` is kept), then merges the publish commit into `--target`. The target bookmark advances to the merge commit. With `--message <msg>` (`-m`), the given text becomes the free-text portion of the publish commit message; otherwise an editor is opened to compose it (`--message` is required when stdin is not a terminal), and an empty message cancels the publish. With `--changelog`, a change summary of the work on the project branch since it last diverged from the target is appended to the message (`--changelog-depth <n>` limits the subtask levels reported, as `tt task changelog --depth` does, and is only valid alongside `--changelog`). The user **remains on the project branch** after publishing (no workspace switch). If merging into the target conflicts, the command refuses and leaves the target bookmark in place; with `--force`, it publishes the conflicted merge anyway. See §6.5.

- **`tt task context add [<task-id>] [--title <title>] [--slug <slug>]`** — Create a new context file associated with the current task (or `<task-id>`). Prompts for title and slug (like task creation) if not provided. Reads the context body from stdin (via pipe or redirect) if stdin is not a terminal; otherwise opens an editor for the body. Generates a context ID of the form `context/<ctx-slug>-<ctx-hex>` and writes the context file to `.tt/task/<task-slug>/context/<ctx-slug>-<ctx-hex>.md`. Adds a `context: context/<ctx-slug>-<ctx-hex>` entry to the task file's frontmatter and refreshes the task's `updated` timestamp. Creates a commit: `[tt:task:<task-id>:context:add] <context-title>` and advances the task bookmark. The target task need not be checked out: the commit is made directly on the task branch and the caller's working copy is left unchanged (see §6.1.2).

  **Examples:**
  ```bash
  # Pipe a file directly
  cat ./plan.md | tt task context add --title "Implementation plan"

  # Redirect from file
  tt task context add --title "Implementation plan" < ./plan.md

  # Interactive (no redirect) — opens editor as before
  tt task context add --title "Implementation plan"
  ```

- **`tt task context get [<context-id>...] [--task <task-id>] [--repo PATH]`** — Print one or more context files for a task to stdout. If one or more `<context-id>` positional arguments are given, only those context files are printed (in the order specified); otherwise all context files for the task are printed in declaration order. Each context file is rendered as `tt task show --expand-context` renders it: a frontmatter block naming the context ID (`context:`) followed by its `title:` (quoted), `created:` and `updated:` fields, then the body with surrounding blank lines trimmed, then a blank line. `--task` specifies which task to read from (default: current task). Applies the "where to read" rule (§7.1 / Appendix A step 3). Exits non-zero if the task has no context files or a specified context ID is not registered on the task. No hooks.

- **`tt task context list [<task-id>] [--task <task-id>] [--repo PATH]`** — List the context IDs for a task to stdout. If `<task-id>` is provided, lists context for that task; otherwise lists context for the current task. The `--task` flag is an alternative way to specify the task (takes precedence over the positional argument). Context IDs are output one per line in declaration order (as they appear in the task file's frontmatter). Exits with code 0 even if the task has no context files (produces no output in that case). Exits with code 1 if the task is not found or is not a valid task/project branch. Applies the "where to read" rule (§7.1 / Appendix A step 3). No hooks.

- **`tt task context delete <context-id> [--task <task-id>] [--repo PATH]`** — Delete a context file from the specified task (default: current task). Removes the context file from the repository and removes the corresponding `context:` entry from the task's frontmatter. Creates a commit: `[tt:task:<task-id>:context:delete] <context-title>` and advances the task bookmark. The target task need not be checked out: the commit is made directly on the task branch and the caller's working copy is left unchanged (see §6.1.2). Exits with code 1 if the context ID is not registered on the task. Applies the "where to read" rule (§7.1 / Appendix A step 3). No hooks.

- **`tt task tree [--project <project-id>]... [--detached] | [--all]`** — Generate and print the full project todo list to stdout. Tasks are grouped by project; orphaned tasks are excluded by default. Optional `--project`, `--detached` and `--all` filter which sections are shown. Output format is the markdown described in §4.1. See §7.1 and Appendix A.

- **`tt task tree --focus`** — Generate and print the focused todo list (current task and its direct ancestors only) in the same markdown format. See §7.2 and Appendix A.

- **`tt task current`** — Print the current task or project branch name to stdout. Exits with 1 if the working copy is not on a task or project branch. No hooks.

- **`tt task revset [--task <task-id>] [--all] [--git] [--repo PATH]`** — Print a revision range covering all unmerged commits on a task branch since it diverged from its parent branch. Without `--task`, uses the current task and includes any trailing commits beyond the task bookmark (up to `@` if working copy is non-empty, or `@-` if empty). With `--task`, the range covers only the task bookmark itself. Without `--git`, outputs a jj revset (`<parent-bookmark>..<upper-bound>`). With `--git`, outputs a git commit range (`<from>..<to>`) where `<from>` is the `commit_id` of the fork point between the parent bookmark and the upper bound, and `<to>` is the `commit_id` of the upper bound. With `--all`, prints the task's complete range instead (see §6.15): a parenthesized jj union of every connected component, or with `--git`, one immutable `<base>..<tip>` range per line. `--all` is not supported for project branches. Exits with an error if the task cannot be located or the bookmark does not exist. No hooks.

- **`tt task diff [--task <task-id>] [--all] [--include-metadata] [--repo PATH]`** — Show the diff of all unmerged commits on a task branch since it diverged from its parent branch. Resolves the same range as `tt task revset` (without `--task`: the current task, with an upper bound of `@` if the working copy is non-empty or `@-` if empty; with `--task`: the task bookmark itself), then emits the diff between the fork point of the parent bookmark and the upper bound. The command emits standard Git-format diff output suitable for programmatic consumption by external tools. Changes to tt metadata — the `.tt/` directory and the repo-root `TASK.md` symlink — are excluded by default, so the diff shows only project content; `--include-metadata` disables this filtering. With `--all`, diffs the task's complete range (see §6.15) instead: one Git-format patch per connected component, oldest first, concatenated without headings or separators; the same path can appear in more than one section if it changed in more than one component. `--all` is not supported for project branches. Exits with an error if the task cannot be located, the bookmark does not exist, or the fork point cannot be resolved. No hooks.

- **`tt task changelog [--task <task-id>] [--all] [--since <revision>] [--depth <n>] [--repo PATH]`** — Summarize the work checked into a task branch since a reference commit: the tasks checked into it, as a tree, followed by the checkpoints recorded directly on it, as a flat list. `--task` defaults to the current task; the branch is always reported up to its bookmark, never beyond. The reference commit is the most recent common ancestor of the branch and `--since`, which defaults to the branch's parent branch. `--depth` limits how many levels of subtask are reported (`0` reports checkpoints only, `1` adds the tasks checked into the branch, `2` also adds the tasks checked into those, and so on); without it every level is reported. With `--all`, gathers first-parent records from every connected component of the task's complete range (see §6.15) instead of walking from a single reference commit, deduplicates them by immutable commit ID, then applies the same tree/checkpoint rendering, grouping and depth limit; `--since`, when given, excludes records already reachable from that revision rather than changing the starting point. `--all` is not supported for project branches. Exits with an error if the task cannot be located, the branch is not a task or project branch, the revision cannot be resolved, there is no common ancestor, no parent branch exists and no `--since` was given, or `--depth` is not a non-negative integer. Writes nothing to stdout when no work was checked in since the reference commit. See §6.14. No hooks.

- **`tt task parent [<task-id>] [--project]`** — Print the parent task ID of the current task (default) or the given task to stdout. With `--project`, walks up the hierarchy to find the nearest ancestor project branch instead of the immediate parent. Exits with code 1 if no parent (or no ancestor project) is found; exits with code 2 if multiple parents are found at any step. No hooks.

- **`tt task find --revision <revision> [--repo PATH]`** — Print the task or project branch that a revision belongs to. `<revision>` is any revision expression the version-control system accepts, and must resolve to exactly one commit. The answer is read from the `TASK.md` symlink that commit records (see §6.2), mapped to the task or project branch it names — the same lookup that makes a task current in a worktree. Every commit on a task's own line, from its fork commit onward, resolves to that task (§4.3). The `[tt:task:<task-id>:create]` commit on the parent branch resolves to the parent. Exits with code 1, printing an error message to stderr, if the revision does not resolve, resolves to no commits or several, records no task symlink, or records a task whose branch no longer exists. No hooks.

- **`tt task select`** — Interactively select an active (non-completed) task or project. Lists all task and project bookmarks, excludes DONE tasks, sorts alphabetically, and pipes the list to a picker (see §6.13). The selected task ID is printed to stdout. Exits with code 1 if no active tasks are found, if the picker fails, or if the picker's output is not one of the offered options. No hooks.

- **`tt task show [<task-id>] [--expand-context]`** — Show the metadata and direct child tasks of the current task (default) or the given task. Reads from the correct branch per the "where to read" rule (§7.1 / Appendix A step 3): merged tasks are read from the parent branch that received the checkin; ongoing tasks are read from their own branch. Output format: lowercase header block (`task`, `status`, `title`; and `parent` if the task has a parent), followed by a subtasks section, a context section (listing context file titles and IDs), and a body section, all always present and separated by `---` dividers. With `--expand-context`, additionally prints each context file after the body section, in the form `tt task context get` prints it. Output to stdout only. No hooks.

- **`tt task prompt [<task-id>] [--message <text>] [--repo PATH]`** — Emit a self-contained LLM implementation prompt for a task to stdout. Reads the task file from the task's branch (defaulting to the current task if no `<task-id>` is given) and outputs: a mini frontmatter block (`task:` and a quoted `title:`), the task body, a `---` separator, any associated context files (each with its own `context:` / quoted `title:` / `---` block and body), and a section listing common `tt` introspection commands, followed by a closing `---` separator. With `--message <text>`, the verbatim message text is appended after the closing separator. `--repo PATH` overrides the repository root. No VCS writes; no hooks.

- **`tt task propagate [--from=<parent-id>] [--to=<descendant-id>]... [--rebase | --merge] [--shallow] [--force]`** — Update descendant task branches so their base is the parent's current tip. Default is to rebase all descendants of the current task; `--merge` merges instead; `--shallow` updates only direct children; `--force` proceeds despite rebase/merge conflicts. Precondition: the working-copy commit must not carry a bookmark. See §6.8.

- **`tt task reorder <task-id> <modifier>`** — Reorder a direct child task. Modifier is one of `--up`, `--down`, `--after <other-task-id>`, or `--before <other-task-id>` (mutually exclusive). Fails if the reorder is impossible (e.g. already first with `--up`, or `<other-task-id>` is not a sibling). See §6.7.

- **`tt task delete [<task-id>] [--force]`** — Remove a task and its entire descendant subtree from the parent branch. Collects the full subtree via union traversal (reads subtask lists from both each task's own branch and the parent branch's copy at every level). Creates a single `[tt:task:<task-id>:delete] <title>` commit on the parent branch that removes the top-level `subtask:` entry and all descendant task files present on that branch. After the commit, deletes all bookmarks in the subtree. Dedicated worktrees are unregistered from the repository model; files left on disk with a warning. Defaults to the current branch if no `<task-id>` is given. Requires task `status: DONE` unless `--force` is specified. Aborts if no parent is found. See §6.9.

- **`tt task rename --slug <new-slug> [--task <task-id>] [--repo PATH]`** — Rename a task's slug (the human-readable part of the task ID), preserving the hex suffix. For example: `task/old-name-abc123` → `task/new-name-abc123`. Rewrites every commit that carries the task directory so the directory moves to its new path, retargets the repo-root `TASK.md` symlink where it points into the old directory, repoints the parent's `subtask:` reference, and renames the bookmark. Requires a clean working copy. If the task has no parent (e.g., a project), only the bookmark and directory are renamed. Silently succeeds if the new slug matches the current slug. Errors if the new ID would conflict with an existing bookmark, and refuses when another worktree is parked inside the range of commits to be rewritten. See §6.10.

- **`tt task move [--task <task-id>] --parent <parent-task-id> [--repo PATH] [--workspace-dir PATH]`** — Reparent a task by moving it to a different parent. Removes the task from its current parent's `subtask:` list and adds it to the new parent's `subtask:` list. Rebases the task's unmerged commit range (commits not yet in the old parent's ancestry) onto the new parent's bookmark tip. Defaults to the current task if `--task` is not given. Checks for a clean working copy before proceeding. Returns a non-zero exit code if the task or parent does not exist. Aborts if the task has no current parent (parentless project), if the new parent is the same as the current parent, or if the move would create a cycle in the task tree. See §6.11.

### 5.5 Worktree

- **`tt worktree list [--task <task-id>] [--quiet] [--repo PATH]`** — List the worktrees of the current repository. The canonical repository is not a worktree and is not listed. For each worktree, shows: a `*` marker on the current worktree, the worktree's jj workspace name, the tt task or project ID it has checked out (read from the `TASK.md` symlink its working copy records, per §6.2, or `(none)` if it holds no task), and the filesystem path (with `$HOME` abbreviated as `~`, or `(none)` if no path is recorded). Output is a columnar table with a header row. With `--task <task-id>`, filters to only worktrees whose resolved TASK ID matches the given task or project ID (exit 1 if the ID is not a valid task/project ID format). With `--quiet`, prints only the worktree names (one per line), with no header or table; compatible with `--task` for machine-readable lookups. Prints only the header (or nothing, with `--quiet`) when the repository has no worktrees. Intended for quick overview of all task worktrees and for scripting. See §5.5.

- **`tt worktree show --name <worktree-name> [--repo PATH]`** — Output the path of the *dedicated* worktree with the given jj workspace name to stdout. The name must match exactly and is the one listed in the `NAME` column of `tt worktree list`. Dedicated worktrees are named after the task they were created for (§6.2), but the name is fixed at creation and does not track subsequent checkouts, so it identifies the workspace rather than whatever task is currently checked out in it; it is not required to be a task or project ID. Exits with an error if no workspace bears that name, if the workspace's recorded path is missing or is not a directory, or if the name resolves to the canonical repository, which is never a valid result. Intended for use in shell command substitution.

- **`tt worktree sync [<worktree-path>] [--all] [--repo PATH]`** — Bring a worktree forward onto the head of the branch it is checked out on, updating its working copy to match. A branch write advances the bookmark without touching any working copy but the invoking one (§6.1.2), so other worktrees on that branch are left sitting on an older tip; this is the command that brings them back. The target worktree is snapshotted first, so uncommitted work — including files the repository has never seen — is preserved across the move. With no argument, targets the worktree containing the current working directory and exits with an error if the CWD is not within a known worktree. With `--all`, synchronizes every out-of-sync worktree in the repository, continuing past any that fail and exiting non-zero if any did; `--all` cannot be combined with `<worktree-path>`. `--all` includes the canonical repository only when run from it (§2). Exits with an error if the given path is neither a worktree nor the canonical repository. Every target is screened for staleness before the transaction opens, and a single stale target refuses the whole run — nothing is synchronized, including under `--all` (§6.16).  Reports the files the move added, modified and removed, or that the worktree was already up to date, and warns when the move left conflicts in the working copy. Runs within a transaction, so `tt history undo` reverts it. **Fires no hooks:** the worktree stays on the branch it was already on and the checked-out task does not change, so no checkout hook is warranted.

- **`tt worktree refresh [<path>] [--root] [--force] [--repo PATH]`** — Recover a **stale** workspace: one whose on-disk files belong to a commit that has since been rewritten, which the VCS backend refuses to load until the files are brought back into agreement with it (§6.16). With no argument, targets the worktree containing the current working directory and exits with an error if the CWD is not within a known worktree. `<path>` targets that worktree; `--root` targets the canonical workspace; the two cannot be combined. There is no `--all` — the command acts on exactly one workspace. Exits 0 with no output when the target is not stale. When the target is stale, refuses unless `--force` is given, naming the workspace and stating that uncommitted changes in it will be lost. With `--force`, performs the recovery and reports the workspace it recovered; `--force` skips detection entirely, so it is also the way out of a workspace state tt cannot classify. **Uncommitted work in the recovered workspace is lost:** a stale working copy cannot be captured before it is reset, so the files are replaced by the recorded tree. This is why recovery is a separate command from `tt worktree sync`, which moves a worktree forward along its branch and *does* preserve uncommitted work. Opens **no transaction**: like `tt workspace init` it is a recovery operation, and it must stay usable while a stale transaction lock is present (§6.12), so `tt history undo` does not revert it.

- **`tt worktree delete <worktree-path> [--force] [--repo PATH]`** — Delete a worktree by its filesystem path. The path must be a worktree of the repository. If the path is the canonical repository, the command exits with an error — this check is not bypassed by `--force`. The task bookmark is automatically resolved from the worktree's current bookmark for safety checks: the task must be DONE, the worktree must be clean, no commits may exist after the bookmark, and no other process may be using the worktree's files — unless `--force` is specified. The in-use check uses `lsof` to find processes whose current directory or any open file lies inside the worktree, and lists each by PID and command name; the command's own process, its ancestors (such as the shell that launched it) and its descendants are not counted. Removing files that a process such as a web server is using can fail partway, leaving the workspace deregistered with some of its files still on disk. If `lsof` is not installed or fails, the command refuses, since the worktree cannot be shown to be unused. Forgets the jj workspace and removes all files from the worktree path. The task bookmark is NOT deleted. If the virtual project's `HEAD` symlink points to the deleted worktree, it is reset to the canonical repository.

---

## 6. Task and branch operations

### 6.0 Branch topology and commit conventions

Each task and project branch follows a structured lifecycle of named commits. The table below describes each commit type, the command that creates it, and its purpose:

| Commit description | Command | Purpose |
|--------------------|---------|---------|
| `[tt:workspace:init] Create workspace` | `tt workspace init` | Adds `.tt/config.toml` to the working copy |
| `[tt:task:<id>:new] <title>` | `tt task create --project` (and a child task without a parent task file) | First commit of a parentless branch: creates the stub task file and points `TASK.md` at it; the branch bookmark starts here |
| `[tt:task:<task-id>:checkout] <title>` | `tt task checkout` | Sets status → `IN-PROGRESS` on first checkout of a `TODO` task, or when reopening a `DONE` task; changes nothing else; advances task bookmark |
| `[tt:task:<task-id>:create] <title>` | `tt task create` | On the parent branch: creates child task file and registers `subtask: [ ] <task-id>` in the parent file; parent bookmark advances |
| `[tt:task:<task-id>:fork] <title>` | `tt task create`, `tt task propagate` | First commit of the child branch: points `TASK.md` at the child task file (the stub it also writes is identical to the parent's copy); the child bookmark starts here. Propagate also creates one on the parent's tip when a partially checked-in child continues there (§6.8) |
| `[tt:task:<task-id>:edit] <title>` | `tt task edit` (also invoked by `tt task create`) | Sets title, description, and labels in the task file frontmatter; task bookmark advances |
| `[tt:task:<task-id>:context:add] <context-title>` | `tt task context add` | Adds a context file and its `context:` frontmatter entry; task bookmark advances |
| `[tt:task:<task-id>:context:delete] <context-title>` | `tt task context delete` | Removes a context file and its `context:` entry; task bookmark advances |
| `[tt:task:<id>:reorder] <title>` | `tt task reorder` | Rewrites the `subtask:` ordering in a task file; `<id>` is the task whose file was rewritten, and its bookmark advances |
| `[tt:task:<task-id>:remove] <title>` | `tt task move` | On the old parent branch: removes the `subtask:` entry and the task stub directory; old parent bookmark advances |
| `[tt:task:<task-id>:move] <title>` | `tt task move` | On the new parent branch: adds the `subtask:` entry and the task stub directory; new parent bookmark advances |
| `[tt:task:<task-id>:checkpoint] <message>` | `tt task checkpoint` | Advances the task bookmark to the current working state |
| `[tt:task:<task-id>:complete] <title>` | `tt task complete` | Sets status → `DONE` in the task file; final task bookmark advance |
| `[tt:task:<task-id>:handoff] <title>` | `tt task checkin` | Off-mainline merge-source commit; child bookmark does **not** advance to this commit |
| `[tt:task:<project-id>:handoff] <title>` | `tt task publish` | Off-mainline merge-source commit for project branches; project bookmark does **not** advance to this commit |
| `[tt:task:<task-id>:checkin] <title>` | `tt task checkin` | Empty merge commit on the parent branch; parent bookmark advances |
| `[tt:task:<parent-id>:propagate] <parent-title>` | `tt task propagate --merge` | Merge commit on the child branch: the child's old tip is the first parent and the parent's tip the second; `TASK.md` keeps the child's target; child bookmark advances |
| `[tt:task:<project-id>:publish] <message>` | `tt task publish` | Empty merge commit on the target branch; target bookmark advances |
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
  │ ○  [tt:task:task/T:checkout] <T-title>           ← tt task checkout  (status → IN-PROGRESS)
  │ │  ↑ task/T
  │ ○  [tt:task:task/T:edit] <T-title>               ← tt task edit  (child branch init)
  │ │  ↑ task/T
  │ ○  [tt:task:task/T:fork] <T-title>               ← tt task create  (TASK.md → T)
  │    ↑ task/T  (initial bookmark position)
  ├─╯
  ○  [tt:task:task/T:create] <T-title>               ← tt task create  (on parent branch)
  │  ↑ project/P
  ○  [tt:task:task/T:checkpoint] ...                 (optional project work)
  │  ↑ project/P
  ○  [tt:task:project/P:checkout] <title>            ← tt task checkout  (status → IN-PROGRESS)
  │  ↑ project/P
  ○  [tt:task:project/P:edit] <title>                ← tt task edit  (project branch init)
  │  ↑ project/P
  ○  [tt:task:project/P:new] <title>                 ← tt task create --project  (TASK.md → P)
     ↑ project/P  (initial bookmark position)
```

Every commit on the `task/T` arm from the fork commit up to `complete` records `TASK.md → T`. The handoff points it back at `project/P` (§4.3).

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
  │ │  ↑ task/T  (bookmark stayed here during partial checkin)
  │ ○  [tt:task:task/T:fork] <T-title>               ← tt task create
  │    ...
  ├─╯
  ○  [tt:task:task/T:create] <T-title>               ← tt task create
  ...
```

Note that the `[tt:task:task/T:checkpoint]` just above the fork commit in the partial diagram is the common ancestor of both the subsequent `[tt:task:task/T:checkpoint]` (more work) commits (task continues from this point) and the partial `[tt:task:task/T:handoff]` (which branches off from the same commit).

---

### 6.1 Task creation (`tt task create`)

**With `--parent`:** The tool creates a **bare commit on the parent task's branch** (regardless of which branch is currently checked out, and without touching any working copy) that both creates a minimal task stub directory (`.tt/task/<slug>-<hex>/TASK.md` containing `status: TODO`, `created`, and `updated` timestamps) and adds `subtask: [ ] <task-id>` to the parent task file, described as `[tt:task:<task-id>:create] <title>`. The parent bookmark is advanced to this commit. The child task's branch then starts on a **fork commit** built on the updated parent tip, described as `[tt:task:<task-id>:fork] <title>`:

- It points the root `TASK.md` symlink at the child task file. From here on, every commit on the child's line records the child as its task (§4.3).
- It also writes the stub. The stub content is byte-identical to the parent's copy, so the stub adds no tree change.
- The child bookmark starts on it.

The branch is then initialised by invoking `tt task edit` to set the title, body, and labels with a `[tt:task:<task-id>:edit] <title>` commit that advances the task bookmark. The `[tt:task:<task-id>:create]` commit on the parent branch leaves `TASK.md` pointing at the parent. The working copy never moves: as with every bare branch write (§6.1.2), a working copy sitting on the parent tip is carried forward onto the updated tip, any other position is left entirely untouched, and uncommitted changes are never absorbed. The command refuses to run while the working-copy commit carries a bookmark.

**Preconditions** (checked before any VCS operation; any failure aborts the command):

- If the resolved parent task file has `status: DONE`, the parent is **reopened** before the child is created: the tool runs `tt task checkout <parent-id>`, which creates a `[tt:task:<parent-id>:checkout] <title>` commit setting the parent's status back to `IN-PROGRESS`, advances the parent bookmark, and checks the parent out (see §6.2). The child is then created on the reopened parent's tip via the normal flow.

**Slug requirement:** In non-interactive mode (stdin is not a terminal), `--slug` must be provided explicitly; the command errors if it is omitted. In interactive mode the user is prompted with a suggested default derived from the title.

Because the parent task file is modified, sibling (and descendant) branches may need to be updated to avoid conflicts at checkin. The optional `--propagate` flag runs `tt task propagate --from <parent>` after creating the task; it accepts `--rebase | --merge` (propagation strategy; default rebase), `--shallow` (direct children of the parent only), and `--force` (proceed despite conflicts). The optional `--checkout` flag runs `tt task checkout` on the newly created task before exiting; the user is left on the new task branch. With `--checkout`, `--worktree[=<path>]` may be passed and is forwarded to `tt task checkout` to use or create a worktree (see §6.2). If the named child branch already exists, the tool notifies the user and refuses unless `--force` is specified.

**With `--project`:** The tool creates a parentless project task using the project prefix. The project branch is created from `--target <commit-rev>` if specified, else the current revision (any branch). The tool refuses to proceed if the target revision already exists within a task tree. No parent task file is modified. The project branch starts on a `[tt:task:<project-id>:new] <title>` commit, which creates the stub task file and points `TASK.md` at it. A `[tt:task:<project-id>:edit] <title>` commit follows, as for a child task.

**Without a parent task file:** A child task whose `--parent` names a bookmark that is not a task or project branch has no parent task file to register in. Its branch starts like a project's, on a `[tt:task:<task-id>:new] <title>` commit that writes the stub and the symlink. No parent branch is modified.

### 6.1.1 Task editing (`tt task edit`)

**Purpose:** Edit the title, description, and/or labels of any task at any point in its lifetime. Also invoked internally by `tt task create` to write initial metadata on the child branch.

**Options:**

```
[<task-id>]           Target task ID (default: current branch)
--title TITLE         New title (preserves existing if omitted)
--label LABEL         Append a label (repeatable)
--delete-label LABEL  Remove a label if present (repeatable, silent no-op if absent)
--repo PATH           Repository root (default: walk up to .jj)
```

**Body input:** The task body (description) is read from stdin (via pipe or redirect) if stdin is not a terminal; otherwise the existing body is preserved.

**Interactive mode** (no `--title`, `--label`, or `--delete-label` given and stdin is a terminal): opens an editor pre-populated with the current body text. Comment lines (`#`-prefixed) are stripped, trailing whitespace is trimmed from each line, and leading and trailing blank lines are removed; indentation within a line is preserved, so nested lists and indented blocks in the body survive editing. An empty result clears the body.

**Partial updates:** fields not supplied on the CLI retain their current values.

**Label semantics:** `--label` appends; `--delete-label` removes (no error if absent).

**Preconditions:** must be on a task or project branch; the working-copy commit must not carry a bookmark. The working copy itself may hold uncommitted changes — the commit is built directly on the task branch and never absorbs them.

**Commit:** `[tt:task:<task-id>:edit] <title>`. The task bookmark is advanced to this commit. The `updated` timestamp is refreshed.

**Output:** prints `<task-id>` on success.

### 6.1.2 Editing tasks that are not checked out

Task metadata is version-controlled on the task's own branch, so mutating it does not require that branch to be checked out. Commands that write to a task file or its context files — `tt task edit`, `tt task context add` and `tt task context delete` — therefore accept any existing task ID, whether or not the task has a worktree.

The write is performed as a **bare commit** on the target branch: the command stages the file changes off to the side, commits them directly on top of the branch tip without touching any working copy, and advances the task bookmark to the new commit. The working copy never moves and its uncommitted changes are never absorbed into the commit; when the caller's worktree is checked out on the written branch, its working-copy commit is carried forward onto the new tip. Other worktrees checked out on the branch are left untouched and reported as out of sync (bring them forward with `tt worktree sync`).

The command refuses to run while the working-copy commit itself carries a bookmark, since capturing the working copy there could absorb unrelated changes into that branch (move off it by starting a new working-copy commit on top of it first). It also refuses while the **canonical workspace is stale**; that condition and its recovery are described in §6.16. Both refusals are checked before the transaction opens, so a refused command leaves the repository untouched and creates no history entry. The same commit message is produced whether or not the task is checked out. This mirrors the way task files can be created and edited from a parent task before the child is ever visited.

### 6.2 Checkout behavior (`tt task checkout`)

The `TASK.md` symlink in the repository root points to the task file within its directory: `TASK.md -> .tt/task/<slug>-<hex>/TASK.md`. The first commit of the task branch sets it (§4.3, §6.1). Checkout never creates or changes it.

**The symlink is what makes a task "current".** Every command that operates on the current task — `tt task current`, `tt task show`, `tt task tree`, `tt task checkpoint`, `tt worktree list` and the rest — reads the symlink recorded in the worktree's working-copy commit and maps the task directory it names to that task's branch. Branch names are task IDs, so the symlink names the branch outright. Because the answer is read rather than derived from the shape of the commit graph, it does not change when a branch write moves a bookmark off the worktree's line (§6.1.2): a worktree left behind by such a write is still on the task it checked out, merely behind its tip. A worktree parked on a task branch that was never checked out is on that task, because the branch's fork commit already records it. A worktree whose working copy records no task — one where nothing has been checked out — is on no task at all, and commands that need one say so rather than adopting a nearby branch. In particular, `tt task create` without `--parent` or `--project` has no parent to create the task under and fails.

With **`--worktree`**: the tool ensures the task is checked out in its own worktree (creating it if necessary). The canonical repository never counts as the task's worktree, even when it has the task checked out. Without `--worktree`: the tool checks out the task branch in the closest ancestor task workspace (if any), or the current workspace if no ancestors have their own workspace.

If the target workspace's working copy is an ancestor task's workspace (not the task's own) and contains changes, the tool alerts and refuses unless `--force` is provided. For subsequent checkouts of the same task, the default is to use an existing workspace for that task if present. If multiple workspaces exist for a task branch, the user must specify `--worktree=<path-to-workspace>`; this form can always be specified if the user wants to control the path of the workspace. The `HEAD` symlink in the virtual project folder is updated to the task's workspace whenever a task is checked out, **except** when `--worktree` is used without `--switch`: in that case the worktree is created or updated but `HEAD` is not changed. Pass `--switch` (only valid with `--worktree`) to also update `HEAD` to the new worktree.

**Checkout commit.** Checking out a `TODO` task (first checkout) or a `DONE` task (reopening) creates a `[tt:task:<task-id>:checkout] <title>` commit. The commit changes only `status: IN-PROGRESS` in the task file. The tool builds it as a bare commit on the task branch and advances the task bookmark to it. Only then does it create the worktree, or start the working copy on top of the new tip. Under `--force`, uncommitted edits stay in the old working-copy commit when the working copy moves, so the checkout commit never contains them. Checking out an `IN-PROGRESS` task creates no commit.

**Reopening completed tasks.** Checking out a task whose `status` is `DONE` reopens it: the tool creates a `[tt:task:<task-id>:checkout] <title>` commit on the task's existing branch that sets `status` back to `IN-PROGRESS`, advances the task bookmark, and leaves a clean working copy on top — the same flow as the first checkout of a `TODO` task. Reopening never pulls changes from the parent branch: the commit is appended to the branch as it stands. Pass `--rebase` or `--merge` to bring the parent's tip in as well (recommended if the task was previously checked in, since the parent has moved on and the next checkin would otherwise conflict). The parent branch is not modified, so its `subtask:` entry for the task remains `[x]` until the next `tt task checkin`, which rewrites it to `[-]` for an `IN-PROGRESS` child (see §6.5). Checking out a task that is already `IN-PROGRESS` remains a no-op with respect to history.

**Preconditions.** The target workspace must not be stale (§6.16) — checked before its cleanliness, since a stale workspace cannot be read — must have no local changes unless `--force` is given, and the working-copy commit of the worktree the command is invoked from must not carry a bookmark: the checkout transaction snapshots that working copy, and a bookmark sitting on it would follow the snapshot, absorbing unrelated uncommitted changes into the branch it names (move off it by starting a new working-copy commit on top of it first). Checkout is one of the three working-copy-bound commands (with `tt task checkpoint` and `tt workspace init`): unlike a bare branch write it exists to create worktrees and move working copies.

**Multiple worktree prevention.** Each task can have at most one worktree. If `--worktree=<path>` is provided and a worktree for this task already exists at a different filesystem path (compared via `realpath`), the command exits with an error showing the existing worktree path. If the provided path matches the existing worktree, the command succeeds silently and reuses it. The bare `--worktree` flag (no `=<path>`) always reuses the existing worktree if one is found, or derives a conventional path if none exists.

**Pulling parent changes (`--rebase` / `--merge`).** By default, checking out a task does not bring in commits that have landed on its parent branch since the task was forked. The mutually-exclusive `--rebase` and `--merge` flags change this: before switching the working copy, the tool locates the task's parent branch (the branch whose task file registers a `subtask:` entry for this task) and runs `tt task propagate --from <parent> --to <task-id>` with the chosen strategy, so the working copy is created on top of the updated tip. Both flags are only valid for task branches; passing either with a project branch is an error, since projects are parentless. If no parent branch can be found for the task, the command fails. Propagation runs inside the command's transaction, so a rebase or merge conflict aborts the whole checkout and rolls the repository back to its prior state. `--force` is **not** forwarded to the propagation step: it only governs the dirty-working-copy check, and conflicts always abort. To check out a task despite propagation conflicts, run `tt task propagate --force` explicitly first. Passing `--rebase` or `--merge` when the task is already up to date with its parent is a no-op.

**Output:** On success, `tt task checkout` prints the worktree path to stdout (one line, no label). All other output (progress messages, jj command output) is written to stderr. This allows the path to be captured or piped, e.g. `cd "$(tt task checkout task/foo-12345678)"`. The `--help` output is also written to stdout per standard convention.

**`.tt/workspace` symlink** — a machine-local symlink at `<repo>/.tt/workspace` pointing to the virtual project directory (e.g. `/Users/tim/Sites/task-tree`). It is created by `tt workspace init` and listed in `.tt/.gitignore` (alongside `/history`), so it is never tracked by jj. Commands that need the virtual project directory (e.g. for updating `HEAD` or running hooks) resolve it via `readlink "$repo/.tt/workspace"`. Because each jj worktree has its own working copy of `.tt/`, the symlink must be planted separately in each worktree; `tt task checkout --worktree` does this automatically when creating a new worktree by copying the target from the canonical repository's `.tt/workspace`. When creating a new jj workspace with `jj workspace add`, the workspace name is set to the full task ID (e.g. `task/my-task-abc12345`) via `--name`.

### 6.3 Checkpoint (`tt task checkpoint`)

`tt task checkpoint` records the current state of work and advances the task bookmark. It always creates a new commit, even if the working copy is empty.

**Commit message:** `[tt:task:<task-id>:checkpoint] <message>`. The `<message>` part comes from `--message` if provided; otherwise the user is prompted to enter it in an editor (see §6.3.1 below). If `--message` is omitted and stdin is not a terminal (e.g. the command is run from a script), no editor is opened: the command prints `Error: cannot open an editor for the checkpoint message: stdin is not a terminal. Pass --message <msg>.` to stderr and exits 1, before resolving the repository or performing any VCS operation. An empty message, whether passed as `--message ''` or left by the editor, prints `Checkpoint canceled: no message provided.` to stderr and exits 1 without performing any VCS operation.

**Commit flow:** The working copy is always recorded as a commit described by the full message, regardless of whether it has pending changes, and the worktree is left on a clean open working copy on top of it. The bookmark is then advanced to the recorded commit.

**Preconditions:** must be on a task or project branch whose bookmark resolves; the working-copy commit must not carry a bookmark. A checkpoint records the working copy as a new commit *above* the branch tip, so a working copy that is itself a branch tip has nothing above it to record and the capture would amend that branch instead — there is no exemption. Checkpoint is one of the three working-copy-bound commands (with `tt task checkout` and `tt workspace init`): capturing the user's uncommitted work is the whole point of the command. Worktrees other than the invoking one that the advanced bookmark leaves behind are reported as out of sync (bring them forward with `tt worktree sync`).

#### 6.3.1 Interactive message editing

When `--message` is not provided and stdin is a terminal, `tt task checkpoint` opens an editor for the user to enter the `<message>` portion of the commit message. This mirrors `git commit` behaviour, using an ephemeral temporary file to store the in-progress prompt.

**Editor selection:** `$TT_EDITOR` → `$GIT_EDITOR` → `$VISUAL` → `$EDITOR` → `"vi"` (first non-empty value wins). The editor executable receives the temporary file path as its only argument.

**Message editor template (written to temporary file):**

```
<prefilled-message>

# Task: <task-title> (<task-id>)
# An empty message cancels the checkpoint.
```

**Prefilled message:** normally the task title. However, when the commit range since the task bookmark contains exactly one commit, the template is prefilled with the first line of that commit's description instead, so a single-commit checkpoint reuses the message the user already wrote. If that commit has no description, the task title is used. This applies regardless of the `--squash` flag, and does not affect `--message` (which skips the editor entirely). It is never used as the message without the editor: when stdin is not a terminal, `--message` is required.

The file is opened in the resolved editor. Once the editor exits:

- **Editor exits non-zero:** Print an error to stderr and exit 1. No VCS operation is performed.
- **Editor exits zero:** Strip all lines beginning with `#`, then trim trailing whitespace from each line along with any leading and trailing blank lines. Indentation within a line is preserved, so a template that prefills indented content (see §6.5) survives the round trip. If nothing remains, print `Checkpoint canceled: no message provided.` to stderr and exit 1. Otherwise use the stripped text as `<message>`.

**Preconditions** (all checked before any VCS operation; any failure aborts the command):

- Current branch is a task or project branch.

**Behavior:** After the operation, print a short confirmation, e.g.:

```
Checkpoint: task/foo-abc12345 → <commit-id>
```

**Hooks:** Runs **pre-checkpoint** (blocking) before any VCS operation, and **post-checkpoint** (optional) after success. Both run in the current task worktree. See §8.

#### 6.3.2 Squashing intermediate commits (`--squash`)

When `--squash` is passed, `tt task checkpoint` collapses all commits between the most recent bookmark state and the current working copy into a single checkpoint commit stacked directly after the bookmark. Intermediate commits are automatically abandoned by jj.

**Commit flow with `--squash`:**

1. List the commits that descend from the bookmark and are ancestors of the working copy's parent, the bookmark itself excluded. If none exist, fall back to the normal commit flow.
2. Snapshot the working copy, then fold each listed commit into the working-copy commit in turn (addressed by change ID, which survives the rewrites each fold performs). The emptied sources are abandoned, so the working-copy commit ends up sitting directly on the bookmark with all of their content.
3. Record the working copy as the checkpoint commit and advance the bookmark to it, exactly as for a normal checkpoint.

**When there is nothing to squash** (the working copy parent is already the bookmark), `--squash` behaves identically to a normal checkpoint.

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

An optional `<task-id>` positional argument may be provided. If given, the command completes that task regardless of which branch is currently checked out — the task need not be checked out anywhere. If omitted, the command completes the current task (the task whose branch is currently checked out).

**Working-copy behavior:** The commit is built directly on the task branch (see §6.1.2), so `@` never moves; when the caller's worktree is checked out on the completed branch, its working-copy commit is carried forward onto the new tip. Uncommitted changes in the working copy are preserved and never absorbed into the complete commit.

**Preconditions** (all checked before any VCS operation; any failure aborts the command):

- Target is a task or project branch.
- The working-copy commit does not carry a bookmark.
- All child tasks are done: every `subtask:` entry in the target task file is marked `[x]`. `--force` bypasses this check.

**Behavior:** Updates `status: DONE` in the task file frontmatter, describes the commit as `[tt:task:<task-id>:complete] <title>`, and advances the task bookmark. Once a task is marked `DONE`, `tt task checkin` will automatically mark the corresponding `subtask:` entry in the parent's frontmatter as `[x]` when the handoff is created (see §6.5).

**Hooks:** Runs **pre-complete** (blocking) before any VCS operation, and **post-complete** (optional) after success. Both run in the target task worktree.

### 6.5 Checkin and publishing

Two separate commands handle merging work into a target branch, depending on whether the source is a task branch (which has a parent task) or a project branch (a parentless root):

- **`tt task checkin`** — for task branches only. Merges into the auto-detected parent branch. Rejects project branches with a clear error.
- **`tt task publish`** — for project branches only. Merges into an externally specified `--target` branch (e.g. `main`). Rejects task branches with a clear error.

#### `tt task checkin` (task branches)

`tt task checkin` merges the current task branch's work (or the task given by `<task-id>`) into its parent branch. An optional `<task-id>` positional argument may be provided to check in a task from any workspace; if omitted, the current branch is used. `--worktree=<path>` disambiguates when the child task has multiple worktrees. If the parent branch has multiple worktrees, checkin must be run from within the task's own worktree (the parent workspace is not disambiguated by `--worktree`).

The command supports two modes based on the task's current `status`:

- **Partial checkin** (task status `IN-PROGRESS`): Shares work-in-progress with the parent so it can be propagated to siblings, without marking the task as done.
- **Complete checkin** (task status `DONE`): Marks the `subtask:` entry as done in the parent frontmatter. Use `tt task complete` (or pass `--complete`) to transition to `DONE` first.

With `--complete`: if the task is not already `DONE`, first runs `tt task complete` (subject to its preconditions, including the incomplete-children check), then proceeds with checkin.

In both modes, with `--rebase` or `--merge`, the tool first propagates from the parent into the current (child) branch; if propagation cannot complete without conflicts, the command bails unless `--force` is used.

**Handoff commit.** `tt task checkin` always creates a **handoff commit** as a child of the current task bookmark commit. The child branch bookmark does **not** advance to the handoff commit; it remains at the current bookmark. The handoff commit is used as the merge source for merging into the parent. Handoff commits are not on the mainline child branch and are ignored during propagation (see §6.8).

The handoff commit contains:

1. `TASK.md` rewritten to point to the parent task's task file (`rm TASK.md && ln -s .tt/task/<parent-slug>/TASK.md TASK.md`), resolving the TASK.md conflict with the parent branch.
2. If `--context <markdown>` is provided: a new context file is created in the parent task directory (`.tt/task/<parent-slug>/context/<ctx-slug>-<ctx-hex>.md`) with title derived from the child task title, and a corresponding `context: context/<ctx-slug>-<ctx-hex>` entry is added to the parent task file's frontmatter.
3. The corresponding `subtask:` entry in the parent task file's frontmatter is updated to reflect the child's current status: `subtask: [x] <task-id>` if `DONE`, or `subtask: [-] <task-id>` if `IN-PROGRESS`. The rewrite applies whatever the entry's current state is, so a previously completed (`[x]`) child that has been reopened (see §6.2) is downgraded back to `[-]`.

The handoff commit is described as `[tt:task:<task-id>:handoff] <task-title>`.

**Merging into the parent.** After the handoff commit is created, the tool merges it into the parent branch. The merge commit is described as `[tt:task:<task-id>:checkin] <task-title>` and the parent branch bookmark advances to it. The merge is made directly on the branch, so no worktree is created for the parent and no working copy is moved; the parent's worktree is looked up only to supply the hook environment and to satisfy `--switch`, and neither requires one to exist.

**After checkin:**
- **Partial checkin (task status `IN-PROGRESS`):** The child bookmark has not moved. The parent now contains the merged handoff commit and sibling branches can be propagated.
- **Complete checkin (task status `DONE`):** The `subtask:` entry on the parent is marked `[x]`. The child's worktree, bookmark and task file all survive; removing them is an explicit step (`--delete`, or `tt task delete` / `tt worktree delete`).

**Task cleanup.** Passing `--delete` removes the task from the repository entirely, and unless `--retain-worktree` is also passed, the dedicated worktree goes with it (the jj workspace is forgotten and the directory removed from disk). To remove a worktree *without* deleting the task, use `tt worktree delete`.

A worktree `--delete` would remove must also not be stale (§6.16): both the cleanliness check and the `--force` path that records its uncommitted work first need to load that working copy, which a stale worktree refuses, so neither `--force` nor anything else overrides it. Because that removal deletes files from disk, a worktree `--delete` would remove is held to the same standard as the target of `tt worktree delete`: checkin refuses if the worktree has uncommitted changes, commits after the task bookmark, or files in use by another process (detected as for `tt worktree delete`, and listed by PID and command name), naming the worktree and the cause. The user can commit or discard the work, stop the processes, pass `--retain-worktree` to keep the worktree, or pass `--force`. Uncommitted work in such a worktree is otherwise unrecoverable: it exists only on disk, and by the time the removal runs the workspace has already been deregistered, so `tt history undo` cannot restore it either. With `--force`, checkin therefore captures that work into the worktree's own working-copy commit before deleting anything and prints the operation ID holding it, so it remains reachable in the operation log afterwards. The checks run before the checkin makes any change, so a refusal leaves the repository untouched, and they are skipped entirely under `--retain-worktree`, which removes nothing.

**Switching worktrees (`--switch`).** Checkin does not move the `HEAD` worktree symlink by default; the working context is left exactly where it was. Passing `--switch` makes the move explicit: after the merge, `HEAD` is repointed at the parent task's worktree, and the `pre-checkout` and `post-checkout` hooks fire as they would for `tt task checkout`. If the parent task is not checked out in any worktree, `HEAD` is pointed at the canonical repository root (the path reported by `tt workspace repo`) instead. This fallback matters for a `--delete` checkin run from inside the child's own dedicated worktree: that worktree is removed at the end of the command, so pointing `HEAD` at it would leave a dangling symlink and break every subsequent `tt` command. `--switch` applies regardless of where `HEAD` currently points, so it can also be used to move to the parent when checking in a task by `<task-id>` from an unrelated workspace. Without `--switch`, use `tt worktree switch` (or `tt task checkout`) to change the working context afterwards.

Merge conflicts in the working copy or other `.tt/` files must be resolved manually; for `TASK.md`, the intended resolution is to keep the parent's version.

#### `tt task publish` (project branches)

`tt task publish` merges a project branch's work into an external delivery branch (e.g. `main`). The `--target <branch>` argument is required. The project branch bookmark does **not** advance; only the target bookmark moves. The user **remains on the project branch** after publishing (no workspace switch).

**Publish commit.** Like `tt task checkin`'s handoff, `tt task publish` creates an off-mainline merge-source commit as a child of the project bookmark (the project bookmark does not advance to it). It removes the `TASK.md` root symlink and the entire `.tt/task/` directory from the working tree. Task files are development-only scaffolding; they must not land on the delivery branch. The `.tt/config.toml` workspace configuration file is not removed. The `--context` option is not supported (there is no parent task file to attach context to). The task-file diff validation (see §6.6) does not apply to `tt task publish`.

The publish commit is described as `[tt:task:<project-id>:handoff] <project-title>`.

**Merging into the target.** After the handoff commit is created, the tool merges it into the target branch. The resulting merge commit is described as `[tt:task:<project-id>:publish] <message>`. The target branch bookmark advances to this merge commit.

**Commit message.** Unlike the handoff commit, which carries the project title, the publish commit is described by the user. With `--message <msg>` (`-m`) the given text is used directly; otherwise an editor is opened on an empty message template, using the same mechanics as `tt task checkpoint` (see §6.3.1). If `--message` is omitted and stdin is not a terminal, no editor is opened: the tool prints `Error: cannot open an editor for the publish message: stdin is not a terminal. Pass --message <msg>.` to stderr and exits 1, before resolving the repository or performing any VCS operation. If the resulting message is empty, whether passed as `--message ''` or left by the editor, the tool prints `Publish canceled: no message provided.` to stderr and exits non-zero, having performed no VCS operation.

**Change summary.** With `--changelog`, the message template carries a `Change summary:` section listing the work on the project branch since it last diverged from the target branch, taken verbatim from `tt task changelog --since <target>` (see §6.14). The section is appended below the message, so the user can edit or delete it before saving; with `--message` it is appended to the given text instead and no editor is opened. `--changelog-depth <n>` limits the subtask levels reported (as `tt task changelog --depth` does) and is rejected unless `--changelog` is also given. When the changelog reports nothing, the section reads `No code changes`. Because the reference commit is the fork point rather than the target tip, a project's first publish summarises its history all the way back to where it diverged from the target (the root commit, if the two share no other ancestor).

The message is resolved before any commit is created, so cancelling leaves the repository untouched.

If the merge into the target conflicts, the command refuses, rolling back the handoff and merge commits and leaving the target bookmark where it was, unless `--force` is used.

### 6.6 Checkin validation

Before attempting any merge, `tt task checkin` performs validation and refuses if any check fails. The **unmerged range** is the set of commits on the child branch that are not yet in the parent's ancestry (commits since the last handoff commit, if any, or all commits on the child branch if no prior checkin has occurred). Checks include:

- Bookmark is up to date (implicit branch only): no commits exist between the task bookmark tip and the working-copy parent (`@-`). Only enforced when `tt task checkin` is called without an explicit `<task-id>` argument; bypassed by passing `<task-id>` explicitly.
- Working copy is clean (implicit branch only): enforced only when `tt task checkin` is called without an explicit `<task-id>` argument
- Every worktree that `--delete` would remove is clean, has no commits after the task bookmark, and has no files in use by another process (`--delete` without `--retain-worktree` only; bypassed by `--force`, which records the uncommitted work first). See the task cleanup notes in §6.5.
- Current branch is a task branch (not a project branch — use `tt task publish` for project branches)
- Current task has exactly one parent
- No conflicts with parent once the handoff commit has been applied (unless `--force`), or after the optional pre-checkin propagate step when using `--rebase`/`--merge`
- No conflicted commit anywhere in the unmerged range (unless `--force`). The merge carries the whole range into the parent's history rather than the child's tip alone, so a conflict that a later commit resolves would still land there. The check runs after the optional pre-checkin propagate step, so it also catches conflicts that step has just introduced.
- No modifications to non-editable task files in the unmerged range: only the current task file may be modified by the user. Any changes to any other `.tt/task` file in the unmerged range cause checkin to abort. (The parent task file is updated by the tool itself via the `[tt:task:<id>:handoff]` and `[tt:task:<id>:checkin]` commits, which are on the parent branch and are not part of the child's unmerged range.)
- The only change to `TASK.md` in the unmerged range from the child is the symlink pointing to the child's task file, then reverted by the handoff commit

On failure, `tt task checkin` aborts with an error and leaves the repository unchanged. Implementations may add further checks via hooks.

`tt task publish` does not perform task-file diff validation (project branches legitimately accumulate child task files from prior child checkins).

### 6.7 Task reorder

Child tasks are ordered via the current task file's `subtask:` frontmatter. **`tt task reorder <task-id> <modifier>`** reorders a direct child; modifier is `--up`, `--down`, `--after <other-task-id>`, or `--before <other-task-id>` (mutually exclusive).

Without a modifier, **`tt task reorder [<task-id>]`** tidies the task's `subtask:` list instead: its entries are grouped by checkbox status (`[-]` IN-PROGRESS first, then `[ ]` TODO, then `[x]` DONE, stable within each group). Only the `subtask:` entries and the `updated:` timestamp are rewritten; an already-grouped list is a no-op (no commit).

In both modes the rewritten task file is committed as a **bare commit** directly onto the branch that owns it (the parent branch when reordering a child; the task's canonical branch when tidying), so that branch need not be checked out anywhere. The working copy never moves and its uncommitted changes are never absorbed; the same refusal and out-of-sync reporting rules as §6.1.2 apply.

### 6.9 Delete (`tt task delete`)

`tt task delete` removes a task and its entire descendant subtree from the parent branch. It is the canonical mechanism for purging a task from the project: after this command, the task is no longer discoverable via `tt task tree` because its `subtask:` entry is gone from the parent task file.

**Usage:** `tt task delete [<task-id>] [--force] [--repo PATH] [--workspace-dir PATH]`

If no `<task-id>` is given, the command operates on the current branch.

**Preconditions** (all checked before any VCS operation; any failure aborts unless noted):

- Current branch is a task or project branch (when no explicit `<task-id>` is given).
- Top-level task `status` is `DONE`. Skipped with `--force`. (Descendants' status is not checked.)
- Exactly one parent branch is found. Parentless tasks (top-level projects with no parent) cannot be deleted this way; the command aborts.
- The working-copy commit must not carry a bookmark (as for all bare branch writes; see §6.1.2). The working copy may otherwise hold uncommitted changes, which are never absorbed.

**Behavior:**

1. Locate the parent branch (same logic as `tt task checkin`).
2. Collect the full descendant subtree via union traversal: for each discovered task, read subtask lists from both (a) the task's own branch and (b) the parent branch's copy of the task file. Union of both is used at every level, recursively, until no new IDs are found.
3. Run **pre-delete** hook (blocking) in the current worktree.
4. Create a single **bare commit** on the parent branch — no working copy is involved, so the parent branch need not be checked out anywhere — that removes the `subtask:` entry for the top-level task from the parent task file's frontmatter and deletes the top-level task directory plus all descendant task directories present on the parent branch. Message: `[tt:task:<task-id>:delete] <title>`. The parent bookmark advances to this commit; a working copy sitting on the old parent tip is carried forward, and other worktrees on the parent branch are reported as out of sync (see §6.1.2).
5. Bulk delete bookmarks for every task in the subtree (root + all descendants). Log a warning for any that cannot be deleted.
6. For each task in the subtree: if a worktree exists at `<workspace-dir>/<task-id>/`, deregister the jj workspace, but **do not delete the files**. Alert the user that the workspace directory still exists and must be cleaned up manually.
7. Run **post-delete** hook (non-blocking).

**Delegation from `tt task checkin --delete`:** When `tt task checkin` is run with `--delete`, it first performs the normal checkin (handoff + merge commits on the parent branch), then invokes `tt task delete` on the same task. This produces two commits on the parent branch: the `[tt:task:<id>:checkin]` commit from checkin, followed by the `[tt:task:<id>:delete]` commit from delete. All subtree bookmarks are deleted after the `[tt:task:<id>:delete]` commit. Finally, checkin removes the checked-in task's own dedicated worktree from disk (step 6 above has already deregistered it from jj); pass `--retain-worktree` to keep it. That worktree's cleanliness was validated up front, before any commit was made, because the deregistration in step 6 means uncommitted work there could no longer be captured by the time the files are removed. Worktrees belonging to *descendant* tasks in the deleted subtree are deregistered by step 6 but their files are left in place for manual cleanup, as they are for a standalone `tt task delete`.

**Hooks:** Runs **pre-delete** (blocking) before any VCS operation, and **post-delete** (non-blocking) after success.

### 6.8 Propagate

When the current task branch gains new commits (e.g. after merging a child with checkin or after direct work on the parent), descendant task branches still have the old parent revision as their base. **`tt task propagate`** updates the given descendant branch(es) (by default, recursively) so each is based on the parent's current tip. `--from` defaults to the current task ID; `--to` defaults to all immediate children of the parent. Strategy defaults to **`--rebase`**; **`--merge`** merges the parent into each child instead. **`--shallow`** updates only direct children. **`--force`** proceeds even if propagation produces conflicts.

**Scope:** The parent must be a task branch or a project branch with task-branch children. By default all descendant task branches in the subtree are updated; with `--shallow`, only direct children. Branches are processed in a deterministic order (parent before children) so each branch is rebased or merged onto its parent's already-updated tip.

**Preconditions (checked before any updates; any failure causes the command to error):** The working-copy commit must not carry a bookmark. The working copy itself may hold uncommitted changes; they are never absorbed into a propagated branch. When `--rebase` is used (default), the rebase must apply cleanly for every branch to be updated unless `--force` is specified; with `--force`, the implementation may leave conflict state for the user to resolve. Under jj, conflicts are allowed in the model; no special conflict-failure handling is required beyond this.

**Worktrees:** Only the invoking worktree follows the branches it is sitting on; no other worktree is written to or rewritten. Worktrees on branches whose tips moved are left on the previous tip — fully usable, but **behind** — and are reported as out of sync, to be brought forward with `tt worktree sync`. Propagate does not perform checkin-style merge-range validation (task-file rules for checkin do not apply when updating a child's base).

**Handling partially-checked-in children.** When a child task has been partially checked in (i.e., a handoff commit from the child has already been merged into the parent), the child's earlier commits are already part of the parent's ancestry. Attempting to naively rebase the child bookmark onto the parent would cause a cycle, since the child bookmark's tip would be a descendant of commits already inside the parent's history.

Instead, propagate identifies only the **unmerged range** of the child branch — the commits that are ancestors of the child bookmark but are **not** yet in the parent's ancestry — and rebases only those. Handoff commits are not on the mainline child branch (the child bookmark does not advance to them), so they are not included in this range and do not interfere with the calculation.

Concretely, for a child branch `C` and parent branch `P`:

- **Moved commits:** `P..C`, the commits in `C`'s history that are not in `P`'s history.
- **Rebase roots:** `roots(P..C)`, the moved commits whose parents are all in `P`'s history.
- **Attachment commits:** `parents(roots(P..C))`, the commits the moved commits hang off. They are always in `P`'s history.
- `C` is **up to date** when it has no moved commits, or when every rebase root already sits directly on `P`'s tip.
- Otherwise, the rebase roots and all their descendants are rebased onto `P`'s tip (or onto a fork commit there, see below): `jj rebase -s "roots(P..C)" -d <destination>`.

**Keeping `TASK.md` on the child.** Every commit on `C`'s own line points `TASK.md` at `C` (§4.3), and propagate preserves this. A partial check-in breaks the plain rebase and merge: the handoff points `TASK.md` back at `P`, and `C`'s later commits do not touch it. Propagate therefore adds commits in three cases. It never creates an empty commit.

- **Up to date, behind:** `C` is a strict ancestor of `P` and its status is not `DONE`. This is the shape a partial check-in leaves once `P` moves on. `C` advances onto a new fork commit, `[tt:task:<C-id>:fork] <C title>`, on `P`'s tip. The fork commit points `TASK.md` at `C` and changes nothing else. This applies under both strategies, so the result is linear under `--merge` too. A `DONE` child is left where it is.
- **Rebase, attached to the child's own line:** some attachment commit points `TASK.md` at `C`. Such a commit is a `C` commit that an earlier check-in brought into `P`. The moved commits do not include `C`'s fork commit, so on `P`'s tip they would inherit `TASK.md -> P`. Propagate first builds a fork commit on `P`'s tip, then rebases the moved commits onto it. The status does not matter: a `DONE` child gets the fork commit too.
- **Merge:** the merge commit lists `C`'s old tip first and `P`'s tip second (§6.14), and is described as `[tt:task:<P-id>:propagate] <P title>`. jj resolves `TASK.md` in the merge from the merge base. After a partial check-in, the base points at `C` and `P`'s side changed it to `P`, so the merge points at `P`. When both sides changed it, the merge is conflicted. Propagate always restores `TASK.md` in the merge from `C`'s old tip. This rewrites nothing when `TASK.md` already matches, and it clears a conflict confined to `TASK.md`. The conflict check runs after the restore.

When the attachment commits point at `P`, the moved commits include `C`'s own fork commit, and a plain rebase keeps `TASK.md -> C`.

Never checked in. The attachment commit points at `P`, so no fork commit is needed:

```
o  W1                  <- C    TASK.md -> C
o  F1 [C:fork]                 TASK.md -> C
| o  Pwork             <- P    TASK.md -> P
|/
o  P1 [C:create]               TASK.md -> P   (attachment commit)
```

Result: `Pwork -- F1 -- W1`, a plain rebase.

Partially checked in, then more work. The attachment commit points at `C`, so a fork commit goes underneath:

```
o  W2                  <- C    TASK.md -> C
| o  Pwork             <- P    TASK.md -> P
| o    Pci1 [C:checkin]        TASK.md -> P
| |\
| | o  Hc1 [C:handoff]         TASK.md -> P
|/ /
o |  W1                        TASK.md -> C   (attachment commit, already in P)
o |  F1 [C:fork]               TASK.md -> C
|/
o  P0
```

Result: `Pwork -- F2 [C:fork] -- W2`.

Nested. A grandchild `G` was checked into `C` after `C`'s partial check-in. The attachment commit is `W1`, which points at `C`, so a fork commit goes underneath. Without it, `G`'s fork commit would conflict on `TASK.md` once moved onto `Pwork`, because it changes `TASK.md` from `C` to `G` on a base that points at `P`.

Repeated propagation. Once `F2` exists, `P` can advance again without a new check-in. The only rebase root is then `F2`, and its attachment commit is `P`'s old tip, which points at `P`. No second fork commit is created.

**Conflicts.** The rebase replays every moved commit, and a later commit can cancel a conflict an earlier one introduced. Without `--force`, propagate therefore refuses when any moved commit, or any commit above `C`'s tip, carries a conflict. For `--merge`, it refuses when the merge commit carries a conflict.

### 6.10 Task rename (`tt task rename`)

`tt task rename` changes the human-readable slug portion of a task or project ID while preserving the hex suffix. For example, `task/old-name-abc123` becomes `task/new-name-abc123`.

**Options:**

```
--slug <new-slug>     New slug (required)
--task <task-id>      Task to rename (default: current task)
--repo PATH           Repository root (default: walk up from CWD to find .jj)
```

**What a rename changes:**

1. **Task directory:** `.tt/task/<old-slug>-<hex>/` becomes `.tt/task/<new-slug>-<hex>/` in every commit that carries it, with all of its contents (the task file and any context files).
2. **Root task pointer:** the repo-root `TASK.md` symlink is retargeted wherever it points into the old directory.
3. **Parent reference:** the parent's `subtask:` entry is repointed at the new task ID — in the parent's own task file and in every copy of it that a child or sibling branch inherited.
4. **Bookmark:** the branch bookmark is renamed from the old ID to the new ID.

No new commit is created: a rename records a correction to what history says, not a further step in it. Every commit keeps its change ID, description, author and position in the graph; only the tree it records changes. The VCS algorithm is described in §6.10.1.

**Preconditions:**

- Working copy must be clean.
- New slug must pass slug validation (lowercase alphanumeric and hyphens, no leading/trailing/consecutive hyphens).
- New task ID must not conflict with an existing bookmark.
- The working-copy commit must not carry a bookmark (the invariant every branch write relies on).
- No worktree other than the invoking one may be positioned inside the rewrite range.

**Parentless tasks:** If the task has no parent (e.g., a project or orphaned task), the command proceeds with bookmark and directory rename only; no parent update is performed.

**Idempotency:** If the new slug is identical to the current slug, the command succeeds silently with no changes.

**Output:** "Task renamed: <old-id> > <new-id>" on success.

#### 6.10.1 VCS mechanics of rename

Renaming a task is more involved than it first appears because the task directory `.tt/task/<old-slug>-<hex>/` is not recorded in one place. It exists verbatim on the parent branch tip, on the task branch tip, on every commit in between, on any sibling branch that forked from the parent after the task was created, and in the invoking worktree's own working-copy commit. All of those copies have to move together.

**Why the directory appears on more than one branch.** When `tt task create` creates a child task, it does the following (in order):

1. Creates a commit on the **parent branch** that both creates `.tt/task/<old-slug>-<hex>/TASK.md` and registers the child in the parent's `subtask:` frontmatter. The parent bookmark advances to this commit.
2. Starts the **child branch** on a fork commit built on that same parent commit, so the child inherits the stub directory from the start. The fork commit also points the root `TASK.md` symlink into the task directory, so the rename retargets it there too.

Every commit made on either line afterwards therefore carries the directory, and so does every branch later forked from either line.

**The rewrite range.** The rename rewrites the commit that *introduced* the task directory together with every visible commit descended from it. That anchor is what makes the set complete and self-evidently so: the directory is recorded in exactly those commits and nowhere else, and the set is closed under descent, so it necessarily contains the parent's current tip (even when the parent advanced well past the fork point), the task's own range, any commits made past the task bookmark, sibling branches that inherited the stub, and the working-copy commit.

Narrower sets are wrong in ways that are easy to miss. Descending from the parent bookmark's tip misses the task branch entirely once the parent has advanced past the fork point. Rewriting only the task's unmerged range leaves trailing commits behind, and — worse — leaves the working-copy commit recording a diff that puts the old paths straight back, so the next checkpoint silently undoes the rename.

**The algorithm.** Two phases, with all reading in the first and all writing in the second:

**Phase 1 — plan.** For each commit in the rewrite range, read its tree as it currently stands, apply the rename to it (relocate everything under the old directory, retarget the root `TASK.md` symlink if it points there, repoint the parent's `subtask:` entry), and park the result in the repository as a detached commit. Record each such staging commit against the change ID of the commit it belongs to.

**Phase 2 — rewrite.** Walk the range oldest first and replace each commit's tree wholesale with the tree computed for it, addressing commits by change ID. Then rename the bookmark, abandon the staging commits, and refresh the invoking worktree's files.

**Why two phases.** Computing every target tree up front, from the original objects, means no step of the rewrite ever reads state that the rewrite itself has already disturbed. Nothing has to be recovered from an earlier operation, and nothing has to be reconstructed out of conflict markers — the plan was made before there was anything to be confused by.

**Why nothing conflicts.** Replacing a tree wholesale is not a merge: no diff is replayed, so there is no three-way merge to produce a conflict. Descendants are rebased with their *content* preserved rather than their diffs replayed, which means a commit the walk has not reached yet keeps exactly the tree it had — the tree the plan was computed from — until its own replacement lands.

**Why change IDs.** Replacing one commit's tree rebases everything above it, so the commit IDs of the rest of the range (and of their staging commits) go stale as soon as the walk starts. Change IDs survive rewrites, so the plan is keyed by change ID throughout.

**Foreign worktrees.** A rename is the one task operation that must rewrite commits it does not own, so it cannot honour the rule every other branch write follows — only rewrite your own worktree's line. It carries its own worktree across the rewrite, but another worktree's uncommitted work exists only on that worktree's disk, and rewriting the commit underneath it would destroy that work. The command therefore refuses when any worktree other than the invoking one has its working-copy commit inside the rewrite range, naming each blocking worktree and pointing at `tt worktree sync` and `tt worktree delete`. There is deliberately no flag to override the refusal. The check runs before the transaction opens and reads other worktrees without snapshotting them, so a refusal leaves the repository and every other worktree exactly as they were.

**Refreshing the working copy.** The rewrite is a bare graph mutation: it never touches a working copy, so once it is done the invoking worktree's files still match the pre-rename trees and the backend refuses any command that loads the working copy. The command therefore refreshes that worktree from inside itself as its last act on the repository. This is also why the clean-working-copy precondition is kept: the refresh does not snapshot, so any pending on-disk edit must already have been recorded.

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

1. **Remove from old parent:** Creates a `[tt:task:<task-id>:remove] <title>` commit on the old parent branch that removes the `subtask:` entry for the task **and** deletes the task's stub directory (`.tt/task/<slug>-<hex>/`). Old parent bookmark advances.
2. **Add to new parent:** Creates a `[tt:task:<task-id>:move] <title>` commit on the new parent branch that adds `subtask: [ ] <task-id>` to the new parent's frontmatter **and** copies the task's stub TASK.md (read from the old parent's pre-Step-1 commit ID) into `.tt/task/<slug>-<hex>/TASK.md` on the new parent. New parent bookmark advances.
3. **Rebase task branch:** Rebases the task's unmerged range (`roots(::task ~ ::old_parent)`) onto the new parent's bookmark tip. If there are no unmerged commits (e.g., the task branch has no commits beyond the old parent's ancestry), this step is skipped.
4. **Restore the task symlink:** Sets `TASK.md` in each moved root to its state in that root's pre-move commit, where it points at the moved task. Commits above each root inherit it. The invoking worktree is then refreshed, because the restore is a bare rewrite.

**Task symlink handling.** On the new parent's line `TASK.md` points at the new parent, while every commit on the task's own line points it at the task (§4.3). The rebase in Step 3 cannot reconcile the two. A root that changes the symlink, such as the fork commit, ends up conflicted on `TASK.md`. A root that inherits it, such as the first commit after a partial check-in, ends up pointing at the new parent. Step 4 resolves both cases by restoring the symlink from the root's own pre-move commit.

**Stub file handling.** `tt task create` always places the task's stub TASK.md on the parent branch. `tt task move` mirrors this invariant: the stub is removed from the old parent (Step 1) and placed on the new parent (Step 2). This is also essential for conflict-free rebasing in Step 3: jj performs a 3-way merge when rebasing, using the old parent tip as the base. If the new parent lacks the stub, jj sees a delete-vs-modify conflict in the task's TASK.md. By placing a byte-identical copy of the stub on the new parent, jj sees "theirs == base" and cleanly takes the task branch's own TASK.md without conflict. The stub is read from the old parent's commit ID (captured before Step 1 advances the bookmark), ensuring the content is byte-identical to what the rebase will use as its merge base.

**Preconditions:**

- Working copy (current worktree) must be clean.
- `--parent` is required.
- Both the task and the new parent must exist as valid task/project bookmarks.
- The task must have exactly one current parent (found via `subtask:` traversal). Parentless tasks (projects) cannot be moved.
- The new parent must not be the same as the current parent.
- Moving the task must not create a cycle (the new parent must not be a descendant of the task).

**Worktrees:** The move does not relocate the working copy. The invoking worktree follows a parent branch it is actually sitting on, so its work stays attached to the branch it was on; a worktree on some other branch is left where it is. Worktrees left behind on either parent branch are reported as out of sync, to be brought forward with `tt worktree sync`.

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

The transaction API is implemented in `scripts/cli/lib/history.sh` as three operations:

- **Begin** — Called at the start of a mutating command, before the first VCS operation. Captures the current VCS operation ID as `<before-op-id>`, appends `<before-op-id>:` (in-progress) to `.tt/history`, exports `TT_TRANSACTION_ID=<before-op-id>`, marks this process as the transaction owner, and sets an `ERR` trap to roll back on failure. It then **snapshots the invoking worktree**, capturing any pending on-disk changes into that worktree's own working-copy commit. The snapshot deliberately runs *after* the before-op ID is recorded, so undoing the transaction also reverts the snapshot and the user's uncommitted work is restored as it was.

  **Nested sub-commands:** When a top-level command delegates to a sub-command (e.g. `tt task create --checkout` calling `tt task checkout` internally), the sub-command inherits `TT_TRANSACTION_ID` via the environment and its begin call returns immediately (no-op). Ownership is recorded in a variable that is *not* exported, so the sub-command's commit and rollback calls are also no-ops — only the top-level command owns the transaction.

- **Commit** — Called at the successful end of a command, after all operations (including follow-on actions like `--propagate` and `--checkout`) complete. Captures the current VCS operation ID as `<after-op-id>`, replaces the last line of `.tt/history` (`<before-op-id>:`) with `<before-op-id>:<after-op-id>`, and clears the `ERR` trap. No-op if not the transaction owner.

- **Rollback** — Called automatically by the `ERR` trap if any command in the script exits non-zero. Restores the repository to the `<before-op-id>` operation, removes the in-progress line from `.tt/history`, and clears the `ERR` trap. No-op if not the transaction owner.

  **When the restore itself fails:** the in-progress line is **kept** rather than removed, and the failure is reported as an error naming the operation the repository should be restored to. The kept line is a lock: it makes the next `tt` command refuse with the stale-transaction error below, instead of running against a repository left half-written. The report gives both ways out — `tt history undo --force` to retry the revert, or `tt history unlock --force` once the repository has been recovered by hand. The working-copy copies taken for preservation are discarded without being re-applied, since a restore that did not happen never disturbed the files. The command's own exit status is unchanged either way. The usual cause is a stale canonical workspace (§6.16), which the up-front preconditions exist to prevent reaching this point; `tt history undo --force` restores from whichever worktree it is invoked in, so it is the route out when the canonical workspace is the stale one.

  **Uncommitted work across a rollback:** the restore rewinds the repository, including the working-copy commit the transaction snapshotted. Before restoring, rollback copies the working copy's changed files aside — recording deletions as deletions — and re-applies them afterwards if the restore landed the worktree back on the same working-copy commit. Work in progress therefore survives a failed command. This is best-effort: if a file cannot be preserved, a warning names it and points at the VCS operation log, from which it remains recoverable.

**Failure semantics:** A failed command (including follow-on actions such as `--propagate` or `--checkout`) triggers a rollback, which restores the repository atomically. The entire command's effect — including any successful intermediate steps — is undone.

**Stale transactions:** If a `tt` command is killed mid-execution (crash, `Ctrl-C`, etc.) and the `ERR` trap did not fire, the history log may be left with an in-progress entry (`<before-op-id>:`). Subsequent `tt` commands will detect this and refuse to start a new transaction, printing:

```
Error: Another tt command is in progress (incomplete transaction).
  To revert a crashed process, run: tt history undo --force
  Or to keep the current state: tt history unlock --force
```

Running `tt history undo --force` reverts the stale in-progress transaction. Alternatively, `tt history unlock --force` clears the lock without reverting the repository state — use this when the jj repository is already in an acceptable state and you simply want to unblock future `tt` commands.

#### 6.12.3 Reverting a transaction

`tt history undo [--force] [--repo PATH]` reverts the jj repository to the state before the most recently recorded `tt` command.

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

**Result:** The transaction entry's `<after-op-id>` reflects the actual current jj operation, accurately representing the state of the repository at the time the lock was cleared. Subsequent `tt` commands will no longer see an in-progress entry and will start normally.

**`tt history unlock` is not itself transactional:** The unlock command does not write a new transaction entry to `.tt/history`. It only modifies the existing in-progress entry.

---

### 6.13 Interactive selection (`tt task select`)

`tt task select` does not implement a picker UI itself. It builds the candidate list, then delegates the choice to a **picker command** via a shared `select_value` helper.

**Picker contract.** A picker reads newline-separated options from **stdin**, presents them to the user however it likes (using **stderr** for any UI output), and writes **exactly one** of the offered options to **stdout**. This is the same contract for the built-in picker and for user-supplied ones.

**Picker selection.** If `$TT_SELECT` is set and non-empty, its value is run as a shell command line via `sh -c "$TT_SELECT"` (so pipes, arguments and quoting all work, e.g. `TT_SELECT='fzf --height 40%'`). Otherwise the built-in picker is used.

**Built-in picker.** Deliberately minimal, built from POSIX tools. It renders the option list to stderr and reads a single line from `/dev/tty`:

```
Select an option:

task/foo
task/bar
task/baz

> 
```

The user types the desired option in full. The built-in picker requires an openable `/dev/tty`; if there is no controlling terminal it prints an error naming `TT_SELECT` and exits 1. Note that only the built-in picker requires a terminal — a custom `TT_SELECT` command may run headlessly.

**Validation.** Whichever picker is used, its stdout must match one of the offered options **exactly**. Anything else — a prefix, a decorated line, empty output — is an error (`Error: invalid selection: <value>`, exit 1). A picker command that itself exits non-zero is also an error. Selection with no options provided is an error (`Error: no options provided`).

### 6.14 Changelog (`tt task changelog`)

`tt task changelog` reports what landed on a task branch, using the commit conventions of §6.0 to distinguish work checked in from subtasks from work recorded directly on the branch.

**Reference commit.** The report covers the branch tip back to a reference commit: the most recent common ancestor (fork point) of the branch and the revision given by `--since`, which defaults to the branch's parent branch. Because it is a common ancestor rather than the revision itself, `--since` may name any revision, including one on an unrelated branch.

**Mainline walk.** Starting at the branch tip and following **first parents only**, the command visits every commit down to the reference commit. Following first parents is what separates the branch's own history from history merged into it: a checkin merge records the branch it landed on as its first parent and the incoming handoff commit as its second, and `tt task propagate --merge` likewise records the child's own tip first. Work merged in from elsewhere is therefore never mistaken for the branch's own.

Commits on that walk are classified by their description:

- `[tt:task:<task-id>:checkpoint] <message>` — where `<task-id>` is the branch being reported on — becomes a checkpoint entry.
- `[tt:task:<subtask-id>:checkin] <title>` becomes a task entry.

Other commits are not reported. This includes fork commits and propagate merges (`[tt:task:<parent-id>:propagate]`), which propagate adds to a child branch (§6.8).

**Recursion.** A checkin merge brings in everything its task had accumulated. For a checkin with mainline parent `m` and handoff parent `h`, the work it merged is the mainline of `h` excluding everything already reachable from `m`; walking that range the same way yields the tasks checked into that subtask, which are rendered as its children, and so on recursively. Excluding `m`'s ancestors is what keeps an earlier partial checkin from being reported twice.

**Depth limiting.** `--depth <n>` caps how many levels of the tree are reported: `0` suppresses the tree entirely, leaving only the checkpoint section; `1` reports the tasks checked into the branch but not what was checked into them; each further level adds one more generation. Omitting `--depth` reports every level. Suppressed levels are simply absent from the output — nothing marks the truncation — and the levels that are omitted are never queried, so a shallow report costs proportionally fewer VCS operations.

**Grouping.** A task checked in more than once — a partial checkin followed by a later one — appears once per parent entry: the entry holds the position of its first checkin, lists the commit IDs of all its checkins, its title and status are resolved from its most recent checkin, and its children combine the work merged by all of them.

**Title and status resolution.** These come from the task file as it exists **at the checkin commit** — the state that was checked in — rather than from the task's own branch, which may have moved on, or from the reported branch's tip, where the file may since have been deleted. A task whose file cannot be read at that revision is listed by its task and checkin IDs alone.

**Output.** One line per entry, in two consecutive sections — the task tree, then the checkpoints — each omitted when it has no entries. Task IDs and commit IDs are written in backticks and separated from their description by ` - `; commit IDs are the first eight characters of the immutable Git commit ID; each task entry follows its task ID with the IDs of its checkin merge commits in parentheses (oldest first, separated by `, ` when the task was checked in more than once); tasks still `IN-PROGRESS` when they were checked in are flagged; each tree level is indented by two spaces; checkpoints are identified by their commit ID:

```
- `task/foo-abc12345` (`9f3e21ab`) - Foo task
  - `task/foo-subtask-1-abc12345` (`1c2d3e4f`) - Foo subtask 1
  - `task/foo-subtask-2-abc12345` (`77aa88bb`) [IN-PROGRESS] - Foo subtask 2
- `task/bar-abc12345` (`2468ace0`, `13579bdf`) - Bar task
- `abcd1234` - Regenerate types
- `cdef5678` - Fix deployment issues
```

When neither section has content the command writes nothing at all and exits successfully. The command is read-only: it runs no hooks, opens no transaction, and never snapshots the working copy.

### 6.15 Complete task range (`--all`)

`tt task revset`, `tt task diff` and `tt task changelog` each normally report only a task's **unmerged range**: the commits reachable from the task's upper bound (its bookmark, or trailing commits beyond it) that are not yet reachable from its current parent branch. Passing `--all` to any of the three expands this to the task's **complete range**: the union of that unmerged range with every range the task previously delivered to its parent, plus the ranges delivered to it by its own direct children. `--all` supports task branches only; project branches are rejected, since publish ranges are out of scope for this discovery.

#### Canonical references

Complete-range discovery is bounded by three references, all resolved to immutable commit IDs before any range is computed:

- the **task bookmark**, the current explicit-task upper bound;
- the **current parent bookmark**, read from the parent task file's `subtask:` frontmatter (the same lookup `tt task checkin` uses to find where a task lands);
- the **creation boundary**, the single commit that created the task's own `.tt/task/<suffix>/TASK.md` within the combined ancestry of the task and parent bookmarks. This commit establishes where attribution starts; it is a boundary only and never appears in the discovered range.

Task move, task rename, and deleted-task recovery are unsupported: the task's file path is assumed stable across the discovery window, and the target task must still be resolvable through its own or its parent's retained bookmark.

#### Components of the complete range

Within the ancestry bounded by the creation boundary and the task/parent bookmarks, discovery classifies every commit that changes the task's own task file or the repo-root `TASK.md` symlink, then assembles four kinds of connected component:

- **historical** — a prior check-in of the task into its current parent. Identified from a two-parent merge candidate (a merge with a parent that changes root `TASK.md`) whose second parent is a single-parent commit (the handoff) that rewrites root `TASK.md` from the task's own file to the parent's file. The component spans from the merge's first parent to the handoff's parent, excluding both the handoff and the merge itself — the wrapper commits that `tt task checkin` creates around every check-in (§6.5).
- **child** — a direct child of the task checked into it. Identified the same way, but with the handoff's root `TASK.md` transition running from some *other* task's file to this task's file. The component spans from the merge's first parent through the merge itself, since the merge commit is the delivered check-in on the task's own branch.
- **path** — a single commit, other than the creation boundary, that changes the task's own task file directly without being part of a check-in merge: a task-management operation (edit, context add/remove/edit, checkpoint, reorder, rename) or a direct child's creation or deletion, whichever branch currently carries the task's retained files.
- **current** — the task's ordinary unmerged range, computed exactly as it is without `--all` (its parent bookmark to its upper bound), always last.

A handoff whose root `TASK.md` transition does not unambiguously match one of these two shapes, including one whose symlink is unchanged, is not classified, and the underlying work is only picked up by whatever narrower `path` or `current` components happen to cover it. Complete-range discovery never falls back to a commit's structured description to resolve this ambiguity.

A propagate merge (`[tt:task:<parent-id>:propagate]`) is a two-parent merge, but its second parent is the parent's bookmark tip, which is never a handoff. It is therefore never classified as `historical` or `child`.

Fork commits change root `TASK.md` but are never classified. A fork commit is a single-parent commit, so it is never a merge candidate. It does not change the task file (its stub copy is identical to the parent's), so it is never a `path` component either. A task's own fork commit belongs to its `current` component, or to a `historical` component once checked in.

Components that are empty, or whose commits are already contained in a broader `historical`, `child`, or `current` component, are dropped. The surviving `historical`, `child` and `path` components are ordered by ancestry (ties break on committer timestamp and commit ID); the `current` component, if non-empty, is appended last.

#### Consumers

Each connected component's range is expressed as `<base>..<tip>`, using immutable commit IDs for every component except `current`, which keeps the same bookmark/`@`/`@-` endpoints as the plain unmerged range.

- **`tt task revset --all`** joins the components as one parenthesized jj union, `(<base1>..<tip1>) | (<base2>..<tip2>) | ...`. With `--git`, it instead resolves each component's endpoints to immutable commit IDs and prints one `<base>..<tip>` range per line, since Git has no single expression for a discontiguous union.
- **`tt task diff --all`** runs `jj diff --git --from <base> --to <tip>` once per component, oldest first, and concatenates the resulting patches with no headings or separators — jj cannot diff a revset with gaps in one call. The same metadata exclusion filtering applies to every component.
- **`tt task changelog --all`** collects first-parent records (§6.14) from every component, deduplicates them by immutable commit ID, then renders them with the same tree/checkpoint/depth logic used without `--all`. `--since` filters the combined selection by excluding records already reachable from the given revision, rather than changing where collection starts.

### 6.16 Stale workspaces and recovery

A workspace is **stale** when its on-disk files belong to a commit whose content has since been rewritten. Every workspace records the commit its files were last updated to; a **bare** mutation — one that rewrites the commit graph without touching any working copy, which is how tt performs almost every branch write (§6.1.2) — can change the tree of a commit some workspace is sitting on. The files are then left holding content that matches no current commit, and the VCS backend refuses every command in that workspace that loads its working copy until the mismatch is resolved.

**Stale is not the same as behind.** The two conditions are easy to confuse and have different remedies:

| | Behind | Stale |
|---|---|---|
| Cause | A write advanced the branch bookmark past the worktree | A rewrite changed the tree of the worktree's own working-copy commit |
| State of the files | Valid, just older than the branch head | Matching no current commit |
| Backend | Works normally | Refuses every working-copy command there |
| Remedy | `tt worktree sync` | `tt worktree refresh --force` |
| Uncommitted work | Preserved — sync snapshots before moving | **Lost** — a stale working copy cannot be snapshotted |

The asymmetry in that last row is the reason the two are separate commands rather than one command with a flag. Recovery resets the files to the recorded tree, and the backend cannot capture what was there first, so authorizing a sync must never implicitly authorize a recovery.

#### Refusing on staleness

tt refuses to act on a stale workspace rather than recovering it silently, because recovery destroys work. Two preconditions enforce this.

**The canonical workspace.** Every command that writes to a branch first checks that the **canonical** workspace — the original repository directory, as opposed to the worktrees tasks are checked out into — is not stale. The canonical workspace is where a failed command's transaction rollback restores the repository from (§6.12), and it is the one workspace guaranteed to still exist even when the invoking worktree has just been deleted. In a repository driven from task worktrees it is rarely the one being worked in, so it can sit stale unnoticed; a rollback that then needed it would fail. Checking up front means the command refuses before writing anything, rather than discovering the problem while already failing.

The check inspects the canonical workspace only. The invoking worktree is deliberately left to fail on its own terms: if it is stale, the transaction's begin-time snapshot refuses immediately and rolls back cleanly. It is also skipped when the canonical workspace *is* the invoking worktree, and inside a nested sub-command, where the outermost command has already checked.

A residual gap is accepted rather than closed: a command that itself rewrites the canonical workspace's working-copy commit makes it stale during its own run, and a rollback after that point still cannot restore. This is survivable because such a rollback keeps the transaction entry (§6.12), and the recovery it names — `tt history undo --force` — restores from whichever worktree it is invoked in, which in that situation is not the stale one.

**Foreign worktrees.** Three commands load a working copy other than the invoking one, and each verifies its target is not stale before any write: `tt worktree sync`, `tt task checkout --worktree`, and `tt task checkin --delete`. Each names the offending path and points at `tt worktree refresh`.

`tt worktree sync` screens every target before opening its transaction, and a single stale target refuses the whole run — including under `--all`, where it reports every stale worktree and syncs nothing. All-or-nothing is preferred to skip-and-continue: with `tt worktree refresh` available the user can restore a consistent state deliberately, which is better than partially self-healing and committing a repository that is still inconsistent. A workspace that is stale but not behind is not a sync target at all, so it neither blocks the run nor is reported by it.

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
| **pre-checkout** | Before switching branch in `tt task checkout`, or before updating `HEAD` in `tt worktree switch` | Current (outgoing) worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH (newly-checked-out target), TT_PREVIOUS_TASK_ID, TT_PREVIOUS_TASK_BRANCH (outgoing) |
| **post-checkout** | After successful `tt task checkout` or `tt worktree switch` | Checked-out task worktree | Optional | TT_TASK_ID, TT_TASK_BRANCH (newly-checked-out), TT_PREVIOUS_TASK_ID, TT_PREVIOUS_TASK_BRANCH (outgoing) |
| **pre-create** | Before creating task in `tt task create` | Parent task worktree | Yes | TT_PARENT_TASK_ID, TT_PARENT_BRANCH, TT_TITLE, TT_SLUG, TT_DESCRIPTION, TT_LABELS (space-separated; labels with spaces/special chars quoted) |
| **post-create** | After task created in `tt task create` | New task worktree if created, else worktree we end up in | Optional | TT_TASK_ID (new), TT_TASK_BRANCH (new), TT_PARENT_TASK_ID, TT_PARENT_BRANCH; TT_WORKTREE_DIR = that same worktree |
| **pre-checkpoint** | Before `tt task checkpoint` performs any VCS operation | Current task worktree | Yes | TT_TASK_ID, TT_TASK_BRANCH, TT_MESSAGE (the checkpoint message, from `--message` or the editor) |
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

3. **Create a task** — `tt task create [--parent <parent-task-id>] [--slug <slug>] [--title <title>] [--label <label> ...] [--propagate [--rebase | --merge] [--shallow] [--force]] [--checkout [--worktree[=<path>] [--switch]]]`. The tool checks the parent's workspace is clean, prompts for title (and autosuggested branch name) if needed, reads the task body from stdin (via pipe or redirect) if stdin is not a terminal; otherwise opens an editor for body input. Locates the parent branch (default: the task this worktree has checked out; parent can be a project or task branch), and fails when no task is checked out and no `--parent` is given. Creates a single commit on the parent's branch that both creates the new task file (with `status: TODO`) and adds `subtask: [ ] <task-id>` to the parent's task file; advances the parent bookmark to this commit. Starts the child task branch on a fork commit on the updated parent tip, which points the `TASK.md` symlink at the child. If the parent is `DONE`, it is reopened first (see §6.2). With `--propagate`, it runs `tt task propagate --from <parent>` with any given flags to bring sibling branches up to date with the parent's new commit. With `--checkout`, it runs `tt task checkout` on the newly created task before exiting; `--worktree[=<path>]` passes through to checkout. See §6.1.

4. **Begin a task** — `tt task checkout <task-id> [--worktree [=<path>] [--switch]] [--rebase | --merge] [--force]`. The tool checks the target workspace is clean (or clobbers changes if `--force` is specified), verifies the task or project branch exists, optionally pulls parent changes into the task with `--rebase` or `--merge` (see §6.2), uses or creates the appropriate workspace per §6.2, sets task status to `IN-PROGRESS` in a new commit if the task status is currently `TODO` or `DONE` (reopening a completed task; the commit changes nothing else, since the `TASK.md` symlink already points at the task), runs `setup` when initializing a new worktree, and updates the `HEAD` symlink (unless `--worktree` is used without `--switch`). See §6.2.

5. **Work on the task** — User commits changes on the branch and accumulates context in `./TASK.md`.
   - **Add context** — Run `tt task context add [--title <title>]` and provide context body via stdin (e.g., `cat ./notes.md | tt task context add --title "Research notes"`). If stdin is a terminal, an editor is opened for body input. Creates a commit. See §5.2.
   - **Read context** — Run `tt task context get [<context-id>...]` to print one or more context files for the current task to stdout. See §5.2.
   - **Checkpoint** — Run `tt task checkpoint [--message <message>]` to create a `[tt:task:<task-id>:checkpoint] <message>` commit and advance the task bookmark. See §6.3.

6. **Complete the task** — `tt task complete [<task-id>] [--worktree=<path>] [--force]`. When work is done, marks the task `DONE` with a `[tt:task:<task-id>:complete] <title>` commit and advances the task bookmark. Requires all child tasks to be done unless `--force`. Can be invoked from any workspace by passing `<task-id>`. See §6.4.

7. **Finish the task** — For task branches (those with a parent): `tt task checkin [<task-id>] [--rebase | --merge] [--force] [--delete] [--switch] [--worktree=<path>] [--propagate [...]]`. The tool runs checkin validation (§6.6); if using `--rebase`/`--merge`, first propagates from parent and bails on conflict unless `--force`. It creates the handoff commit and merges it into the parent. The child worktree is left in place unless `--delete` is passed. The `HEAD` worktree symlink is left where it is unless `--switch` is passed, which moves it to the parent's worktree (or to the canonical repository root if the parent is not checked out anywhere). Can be invoked from any workspace by passing `<task-id>`. If merge conflicts occur (e.g. in other `.tt/` files), the user resolves manually; for `TASK.md`, keep the parent's version. With `--propagate`, also runs `tt task propagate --from <parent>` after the merge completes. For project branches (parentless roots): `tt task publish [<project-id>] --target <branch> [--message <msg>] [--changelog [--changelog-depth <n>]] [--force]`. Creates a handoff commit that strips task scaffolding files, merges into `--target`, and leaves the user on the project branch (no workspace switch). The publish commit message is taken from `--message` or composed in an editor (`--message` is required when stdin is not a terminal; the editor is optionally prefilled with a change summary via `--changelog`); an empty message cancels the publish. See §6.5 and §6.6.

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
   - For each task line, output: checkbox from status (`[ ]` / `[-]` / `[x]`, or `[?]` when the task file is unreadable or has no parseable `status:`); link `[<prefix><slug>-<hex>](.tt/task/<slug>-<hex>/TASK.md)`; title (read from `title:` in the task file on the canonical branch, as determined in step 3, falling back to `(no title)`). Indentation reflects hierarchy.

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

Test suites are co-located with the code they exercise as `*.test.sh` files — one per command and one per library module:

```
scripts/
├── harness/
│   └── harness.sh                    # Reusable test harness (sourced by each test file)
├── test                              # Top-level runner
└── cli/
    ├── lib/
    │   ├── *.test.sh                 # One suite per library module
    │   └── vcs/
    │       └── jj.test.sh            # VCS backend suite
    ├── task/
    │   └── **/*.test.sh              # One suite per tt command
    ├── workspace/*.test.sh
    ├── worktree/*.test.sh
    └── history/*.test.sh
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

Every command in the CLI and every library module has a dedicated test suite. The VCS backend suite additionally covers the invariants that branch writes rely on: that a write leaves every worktree's uncommitted changes intact and out of the created commit, that only the invoking worktree is ever reattached, that symlinks and file modes round-trip, and that an unsupported storage backend is refused. Edge cases requiring interactive input (editor prompts) cannot be tested non-interactively but all commands accept `--message`/`--title`/`--slug` flags or stdin pipes as alternatives.
