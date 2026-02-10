---
name: DESIGN.md critical analysis
overview: "Critical analysis of the todo-tree design document: evaluation of strengths and weaknesses, suggested improvements, and a list of clarifying questions for underspecified or unclear areas."
---

# Critical analysis: todo-tree [DESIGN.md](http://DESIGN.md)

## Scope

The document under review is [DESIGN.md](/Users/tim/Sites/task-tree/DESIGN.md). It describes **todo-tree** (`tt`), a CLI for task tracking and context management using the VCS (initially Jujutsu) as the backing store, with tasks as branches and a derived markdown todo list.

---

## Strengths

- **Clear conceptual model**  
Tasks = branches, subtasks = in-branch atomic steps, parent/child expressed by branch topology. The distinction between “task” (branch, mergeable unit) and “subtask” (same branch, checklist item) is well motivated.
- **VCS as single source of truth**  
Todo list is derived from branch structure and task file contents, not stored separately. That avoids sync issues and keeps full history in the repo.
- **Concrete data formats**  
GFM checkboxes, `.tt/task/<id>-<slug>.md` paths, frontmatter fields (title, status, description, labels, subtasks), and the `TASK.md` symlink are specified with examples. Implementers have a clear target.
- **Spelled-out list-generation algorithm**  
The “Generating the overall todo list” section (enumerate branches → resolve parents → build DAG → choose revision per task → load metadata/subtasks → order siblings → emit markdown) is detailed enough to implement and clarifies where to read each task file (parent vs task branch).
- **Explicit writability rules**  
Only the current task file and immediate parent task file are writable; others read-only. This avoids context leaking and supports “summary back to parent at merge” without over-editing.
- **Extensibility via hooks**  
`.tt/hooks/setup`, `pre-checkin`, `pre-receive`, `post-receive` give projects a defined way to plug in without the design specifying every workflow detail.
- **Multi-parent / DAG acknowledged**  
Merge commits and tasks appearing multiple times in the tree are called out; the doc does not oversimplify to a strict tree.
- **Rationale for “no reorder”**  
Sibling order by task-file creation (or commit) time is stated and justified, setting expectations and avoiding scope creep for reordering in v1.

---

## Weaknesses and gaps

### 1. User workflow is incomplete

- **No “view todo list” command**  
The doc describes how the full and “focused” lists are generated but not how the user invokes them (e.g. `tt list` vs `tt list --focused`). Without this, the main deliverable (the derived markdown list) has no defined UX.
- **Step 5 (checkin) ends abruptly**  
The last sentence (“If there is no parent task … it merges directly into the parent branch.”) ends the section. Missing: what happens after a successful merge (e.g. where does the user’s working copy point?), whether the tool switches to the parent task, and whether there is a “step 6” or follow-up command.
- **Merge conflicts and failure handling**  
The design says the child’s `TASK.md` symlink change is “ignored” on merge but does not specify how (e.g. merge driver, manual resolve, or jj-specific workflow). Merge conflicts in code or in other `.tt/` files are not addressed. Error recovery (failed merge, partial checkin) is unspecified.

### 2. Subtask lifecycle underspecified

- **Creation**  
Subtasks appear in frontmatter and in the todo list, but there is no described way to create them (CLI subcommand vs manual edit only). If manual only, that should be stated.
- **Ordering**  
Subtasks are shown as an ordered list (1.–8. in the example). It is unclear whether order is defined by frontmatter order, file creation time, or another rule.
- **Subtask “checkout”**  
There is no separate branch for subtasks; the doc says work happens “directly in this task’s VCS branch.” Whether the user “checks out” a subtask for focus (e.g. updating its status or context only) or just edits the task file is unclear.

### 3. Identifiers and naming

- **Task/subtask ID format**  
Examples use short hex-like IDs (e.g. `ea434dde`, `c10103b7`). The doc does not define: length, uniqueness scope (repo? parent?), or whether it’s generated or user-supplied. `tt new` has `--id <task-id>` but the semantics (optional override vs required) and format are not specified.
- **Branch and file naming**  
“Machine-readable name of the branch” and paths like `task/ea434dde-authentication` suggest `<id>-<slug>`. It is not explicit whether the slug is derived from the summary, user-provided, or both, and how collisions are avoided.

### 4. Multi-parent (DAG) semantics

- **Where the task file lives**  
For a task with multiple parents, “which branch holds the task file before merge?” is unclear. If the task has one branch, that branch has one tip; the doc’s “read from parent if merged, else from task branch” still applies, but the notion of “merged” when there are several parents (merge into each? into one?) needs clarification.
- **Duplicate appearance in the tree**  
“Tasks with multiple parents will appear multiple times in the tree” is stated. Editing or “checking out” such a task could be confusing; the design could briefly state that there is still a single branch and a single task file, and the list view is the only place it’s repeated.

### 5. Enforcement and robustness

- **Read-only enforcement**  
“Only current and immediate parent task files are writable” is a rule but not an enforcement mechanism (pre-commit hook, `tt` refusing to commit, or convention-only). Without this, the rule is easy to violate by accident.
- **TASK.md merge strategy**  
“Ignoring the conflicting change to the TASK.md symbolic link” needs an implementation note: how jj (or git) is instructed to prefer the parent’s `TASK.md` (or drop the child’s) so that merges are deterministic and documented.

### 6. Focused todo list is a stub

- **No algorithm**  
“A more efficient algorithm can be used to generate the todo list for just the current task and its direct ancestor tasks” has no steps. At minimum, the design should specify: input (current branch or task id), which branches/revisions are read, and how the markdown output differs (e.g. same format, reduced tree).

### 7. Minor issues

- **Typo**  
Example line 40: “OAauth2” → “OAuth2”.
- **Example link inconsistency**  
Line 48: `ef19c63e-forgotten-password` is missing the `.md` suffix in the link target, unlike other task links.
- **Frontmatter**  
Repeated `label:` and `subtask:` keys are valid in YAML but the doc does not state that order of `subtask:` entries defines display order. A single sentence would remove ambiguity.
- **Root branch name**  
“main” is used throughout; the design does not say if the root branch is configurable (e.g. in `.tt/config` or `tt init`).
- **“Script” vs “tool”**  
The workflow section repeatedly says “script” (e.g. “script checks …”, “script creates …”). If the implementation is not necessarily shell scripts, “the tool” or “tt” would be clearer.

---

## Suggested improvements

1. **Add a “Commands” or “CLI” subsection**
  - `tt init`, `tt new`, `tt checkout`, `tt checkin` (already implied).  
  - `tt list [--focused]` (or equivalent) to generate and print the full or focused todo list.  
  - Optional: `tt status` for current task and branch.
2. **Complete the checkin workflow**
  - One or two sentences on: after a successful merge, which branch/worktree is active and whether the user is prompted to run `tt checkout <parent>` or similar.  
  - Short “Merge conflicts” bullet: at least “conflicts in `.tt/` or working copy must be resolved by the user; recommended approach for TASK.md: …”.
3. **Specify TASK.md merge behaviour**
  - In “Merging completed tasks”, add one sentence or a small subsection: “On merge, the parent’s `TASK.md` is kept (child’s symlink change is discarded)” and reference how this is achieved (e.g. jj merge strategy or custom driver).
4. **Define task and subtask IDs**
  - ID format (e.g. 8 hex chars), uniqueness guarantee (e.g. per repo), and whether `--id` is optional (auto-generate) or required.  
  - Slug: derived from summary (e.g. lowercased, hyphenated) with optional override; behaviour on collision (suffix or error).
5. **Clarify subtask lifecycle**
  - Either: “Subtasks are created and ordered by editing the task file (no dedicated CLI),” or add a minimal `tt subtask add [--after <id>]` (and ordering rule) so that “ordered list” is well-defined.
6. **Focused todo list**
  - Add a short algorithm: “Given current branch B: resolve B to a task branch T; walk from T to root via parent(s); collect task files for that path; order and emit as in the full algorithm, but only for that subset.”
7. **Read-only enforcement**
  - State how writability is enforced (e.g. “tt will refuse to commit changes to task files outside current or immediate parent,” or “enforced by `.tt/hooks/pre-commit`”).
8. **Root branch and config**
  - Mention whether the main branch name is fixed as `main` or configurable (and where), so that “project root branch” is unambiguous.
9. **Copy-edit**
  - Fix “OAauth2”, the missing `.md` on the forgotten-password link, and consider “the tool” instead of “script” where appropriate.

---

## Open questions for the author

These would benefit from clarification in the design or in a follow-up:

- **Subtask workflow**  
How are subtasks created and reordered (CLI vs manual edit)? How is subtask order defined when generating the list?
- **Viewing the todo list**  
What is the exact command (and options) to produce the full and focused todo list (e.g. stdout, write to file, or both)?
- **Post-checkin behaviour**  
After a successful `tt checkin`, which branch/worktree is active? Is the user expected to run `tt checkout <parent>` (or equivalent) to continue on the parent task?
- **Merge conflicts**  
How should merge conflicts be handled, especially for `TASK.md`? Is there a preferred jj (or git) strategy or merge driver?
- **Task ID and slug**  
Exact format and uniqueness rules for task/subtask IDs; how slug is derived and how collisions are handled; semantics of `--id` in `tt new`.
- **Multi-parent tasks**  
For a task with multiple parents, is the task file only on that task’s branch until it is merged into each parent? When the task is “done,” is it merged into all parents or only one?
- **Enforcement of writability**  
How is “only current and immediate parent task file writable” enforced (tool, hooks, or convention)?

---

## Summary

The design is strong on the core model (tasks as branches, derived todo list, context in task files, writability rules) and on the full list-generation algorithm. The main gaps are: **incomplete user workflow** (no list command, checkin narrative cuts off, no conflict handling), **underspecified subtask lifecycle**, **missing definitions for IDs and naming**, **DAG edge cases**, and **no enforcement story** for read-only rules and TASK.md merge behaviour. Addressing the suggested improvements and answering the open questions would make the document implementation-ready and reduce ambiguity for both implementers and users.
