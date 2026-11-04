---
name: tt
description: Project task management with task-tree (tt)
---

# Overview

Task-tree (`tt`) is a project task management tool built on top of `jj` (jujutsu) that provides a workflow for managing tasks and their associated branches within the repository. It allows you to create tasks, switch between them, add context, checkpoint progress, complete tasks, and merge them back into their parent tasks.

All interactions with VCS and task management should be performed via the `tt` CLI.

## Current task overview

```shell
tt task show         # Show an overview of the current task
tt task tree --focus # Show the current task within the overall task tree
tt task current      # Print the current task ID
tt task parent       # Print the parent task ID
```

## Command reference

Use `tt task <subcommand> --help` for detailed options on any command.

```shell
tt task create --title "<title>" [options...]
tt task create --help    # Show task creation options
tt task --help           # List available task subcommands
tt --help                # General usage
```

## Worktrees and the canonical repository

The **canonical repository** is the original repository directory (`tt workspace repo` prints it). A **worktree** is any other jj workspace of the same repository, usually created for one task by `tt task checkout --worktree`.

`tt` acts on the canonical repository only when a command runs from it, or when a command names it explicitly. Run from a worktree, `tt` leaves the canonical repository wherever the user left it:

- `tt task checkout --worktree` never reuses the canonical repository.
- `tt worktree sync --all` skips the canonical repository.
- Out-of-sync warnings never name the canonical repository.
- `tt worktree list` never lists the canonical repository.

## Working copy rules

Two rules govern how `tt` treats the working copy. Both are worth knowing before running anything, because they explain the most common failure and the most common surprise.

**Commands that write to a branch do not move the working copy.** They build the commit on the branch directly, leaving `@` exactly where it was and never absorbing uncommitted changes into what they commit. Only `tt task checkout`, `tt task checkpoint`, `tt workspace init`, `tt worktree sync` and `tt history undo` move a working copy at all. (`tt worktree switch` moves no working copy either — it only redirects the `HEAD` symlink.)

A dirty working copy is therefore fine for most commands, including `tt task edit`, `tt task create`, `tt task complete`, `tt task delete`, `tt task reorder`, `tt worktree switch` and the context commands. These still require a clean one:

| Command | Condition |
|---|---|
| `tt task checkin` | Only when called without an explicit task ID |
| `tt task publish`, `tt task propagate` | Only when called without an explicit project ID / `--from`, and unless `--force` |
| `tt task move`, `tt task rename` | Always |
| `tt task checkout` | Unless `--force`, or when creating a new worktree |
| `tt worktree delete`, `tt history undo` | Unless `--force` |
| `tt workspace init` | Always |

**Never hand-edit task metadata.** `tt` alone writes the files under `.tt/task/` and the root `TASK.md` symlink. Every branch-writing command, `tt task checkpoint` included, refuses while uncommitted changes touch them:

```
Error: Worktree '<path>' has uncommitted changes to task metadata:
  .tt/task/<slug>-<hex>/TASK.md
  Discard these changes first, or use --force.
```

Use `tt task edit` and the context commands instead, and discard the hand edits (`jj restore .tt/task TASK.md`). `--force` bypasses the refusal where a command has it, but it can leave conflict markers in the working copy. `.tt/config.toml` and `.tt/hooks/` are not task metadata and may be edited freely.

**Checkpoint before running commands on the current task.** Commits made with plain `jj commit` are not on the task branch until `tt task checkpoint` records them. Commands that default to the current task (`edit`, `complete`, `delete`, `context add`, `context delete`, `create` without `--parent`, `reorder` without a task ID or modifier, `propagate` without `--from`, `publish` and `checkin` without an ID) refuse while such commits exist:

```
Error: Worktree '<path>' has commits after the task bookmark '<task-id>'.
  Checkpoint or discard these commits first, or pass the task ID explicitly to skip this check.
```

Run `tt task checkpoint` first. Passing the task ID explicitly skips the check, and the command then acts on the branch as it stands, without those commits. `--force` does not skip it.

The corollary: a worktree sitting on a branch that some other command advanced is left on the old tip. It is usable, just **behind**. Commands report this by name after a write:

```
The following worktrees are now out of sync:
  <path> (<task-id>)
Run 'tt worktree sync' in each of them to bring them up to date.
```

`tt worktree sync --all` does the whole set in one go, and preserves uncommitted work in each target worktree.

**A branch write refuses while the working-copy commit carries a bookmark.** `tt` expects `@` to sit *above* the branch tip, not to be it. If `@` is itself a bookmarked commit, commands abort with:

```
Error: The working-copy commit is the tip of bookmark '<name>'.
```

This happens after driving `jj` directly — typically `jj edit <bookmark>`. Recover by starting a new working-copy commit on top of it (`jj new`), then re-run the `tt` command. The refusal covers any bookmark on `@`, not just the branch being written.

**A branch write refuses while a workspace it depends on is stale.** A workspace is *stale* when its files belong to a commit whose content has since been rewritten; `jj` then refuses every command there. Commands abort with:

```
Error: The workspace is stale: <path>
  Recover it first: tt worktree refresh <path> --force
  Uncommitted changes in that workspace will be lost.
```

Stale is **not** the same as *behind*. A worktree left on an older tip is behind: its files are valid, `tt worktree sync` brings it forward, and uncommitted work is preserved. A stale workspace's files match no commit at all, only `tt worktree refresh --force` clears it, and **uncommitted work there is lost** — a stale working copy cannot be snapshotted first. Never reach for `refresh` when `sync` is what the situation calls for.

If a command fails and its rollback cannot restore, it says so and **leaves the transaction lock in place** on purpose, so the next `tt` command refuses rather than running against a half-written repository:

```
Error: Could not restore the VCS operation state.
  The repository was left mid-transaction at operation <op-id>.
```

Recover with `tt history undo --force` to retry the revert, or `tt history unlock --force` once you have fixed the repository by hand. `tt history undo` restores from whichever worktree you run it in, so run it from a healthy one.

A killed `tt` process can also leave a stuck history lock, `.tt/history.lock`. Every later command then fails with `Error: Timed out after 5s waiting for the history lock`. `tt history unlock --force` also removes a stuck history lock.

The workspace named in the refusal is most often the canonical repository root rather than the worktree you are standing in. That is deliberate: it is the workspace a failed command's rollback restores from, and in a repository driven from task worktrees nobody is standing in it, so it can sit stale unnoticed. Recover it with `tt worktree refresh --root --force` and re-run the command.

### Task commands

#### `tt task create`
```
tt task create --title "<title>" [--slug <slug>] [--parent <task-id>]
               [--label <label>...] [--propagate [--rebase | --merge] [--shallow] [--force]]
               [--checkout [--worktree[=<path>]]]
```
Creates a task under the task this worktree has checked out (or `--parent`); fails when nothing is checked out and no `--parent` is given. Body read from stdin if piped. On success, prints the generated task ID to stdout (all other output is on stderr) so it can be piped, e.g. `tt task checkout "$(tt task create --slug foo --title 'Foo' < ./desc.md)"`.

#### `tt task checkout`
```
tt task checkout <task-id> [--worktree[=<path>]] [--switch] [--force]
```
Switch to the given task branch. `--worktree` uses/creates a worktree for the task (never the canonical repository); `--switch` also updates HEAD to the new worktree. Returns the worktree path to stdout for piping into other commands.

#### `tt task checkpoint`
```
tt task checkpoint [-m <message>] [--squash]
```
Record the current state of work. `--squash` collapses all commits since the last bookmark into a single checkpoint commit. Always pass `-m` when running non-interactively: without it the command opens an editor, and when stdin is not a terminal it exits with an error instead. An empty message cancels the checkpoint.

#### `tt task complete`
```
tt task complete [<task-id>] [--force]
```
Mark a task DONE. Requires all child tasks to be done, unless `--force` is given.

#### `tt task checkin`
```
tt task checkin [<task-id>] [--complete] [--rebase | --merge] [--force] [--delete]
                [--context <markdown>|-] [--switch] [--retain-worktree]
                [--propagate [--propagate-rebase | --propagate-merge]
                [--propagate-shallow] [--propagate-force] [--propagate-dry-run]
                [--propagate-to <child-id>]]
```
Merge a task branch into its parent. `--complete` marks it done first. `--delete` removes the task file after checkin, along with the task's dedicated worktree if it has one (pass `--retain-worktree` to keep it). `--propagate` propagates the updated parent tip to sibling branches.

Checkin never removes a worktree unless `--delete` is given; use `tt worktree delete` to tear one down on its own, or `tt worktree prune` to remove every worktree whose task is `DONE`.

`--switch` moves the `HEAD` worktree symlink to the parent task's worktree after the merge (falling back to the canonical repository root if the parent is not checked out anywhere). Without it, `HEAD` is left exactly where it was.

`--context <markdown>` provides handoff context inline. `--context -` reads context from stdin. When no `--context` is given and stdin is a TTY, an editor opens for context input (empty input = no context file created).

#### `tt task show`
```
tt task show [<task-id>] [--expand-context]
```
Show metadata and direct child tasks of a task. `--expand-context` prints full context file content.

#### `tt task tree`
```
tt task tree [--focus] [--project <project-id>] [--all] [--detached]
```
Print the project todo list. `--focus` shows only the current task and its ancestors/context.

#### `tt task list`  (alias: `tt list`)
```
tt task list [--type <type>]... [--status <status>]... [--quiet] [--repo PATH]
```
List every task and project as a table of `ID`, `TYPE`, `STATUS` and `TITLE`, sorted by ID, with `*` marking the current task. `--type` takes `project` or `task`. `--status` takes `TODO`, `IN-PROGRESS`, `DONE`, or `''` for tasks without a status, ignoring case and hyphens. Repeat an option to match any of its values; combine options to require all of them. `--quiet` prints IDs only. Pipe it to a picker to choose a task, e.g. `tt task checkout "$(tt list --status todo --status in-progress --quiet | fzf)"`.

#### `tt task current`
```
tt task current
```
Print the current task or project branch name.

#### `tt task parent`
```
tt task parent [<task-id>] [--project]
```
Print the parent task ID. `--project` walks up to find the nearest ancestor project.

#### `tt task find`  (alias: `tt find`)
```
tt task find --revision <revision> [--repo PATH]
```
Print the task or project ID a revision belongs to. `<revision>` is any revision expression the version-control system accepts, and must resolve to exactly one commit.

#### `tt task revset`  (alias: `tt revset`)
```
tt task revset [--task <task-id>] [--all] [--git] [--repo PATH]
```
Print the revision range covering all unmerged commits on a task branch since it diverged from its parent — the same range `tt task diff` shows the contents of. Without `--task`, uses the current task and extends the range to any trailing commits beyond the task bookmark. `--git` prints a `<from>..<to>` commit-ID range instead of the native revset, for feeding to tools that expect Git syntax. `--all` prints the task's complete range across every connected component, and is not supported for project branches.

#### `tt task diff`  (alias: `tt diff`)
```
tt task diff [--task <task-id>] [--include-metadata] [--repo PATH]
```
Show the diff of all unmerged commits on a task branch since it diverged from its parent branch. Output is written in standard Git diff format. Without `--task`, uses the current task and includes trailing commits and uncommitted working-copy changes. Changes to tt metadata (the `.tt/` directory and the root `TASK.md` symlink) are omitted unless `--include-metadata` is passed.

#### `tt task changelog`  (alias: `tt changelog`)
```
tt task changelog [--task <task-id>] [--since <revision>] [--depth <n>] [--repo PATH]
```
Summarize the work checked into a task branch: a tree of the tasks checked into it, followed immediately by a list of the checkpoints recorded directly on it. Covers everything since the most recent common ancestor of the branch and `--since` (default: the parent branch). `--depth` limits the subtask levels reported (`0` for checkpoints only, `1` for immediate subtasks, and so on; default: all levels). Task titles and statuses are reported as they were when checked in, and tasks still in progress at that point are flagged `[IN-PROGRESS]`. Prints nothing when no work has been checked in.

#### `tt task edit`
```
tt task edit [<task-id>] [--title <title>] [--label <label>...] [--delete-label <label>...]
```
Edit a task's title, body, and/or labels. Body read from stdin if piped, otherwise opens editor.

#### `tt task rename`
```
tt task rename --slug <new-slug> [--task <task-id>]
```
Rename a task's slug (human-readable part of the task ID), preserving the hex suffix.

#### `tt task move`
```
tt task move --parent <parent-task-id> [--task <task-id>]
```
Reparent a task by moving it to a different parent.

#### `tt task delete`
```
tt task delete [<task-id>] [--force]
```
Remove a task from its parent branch. `--force` skips the DONE status check.

#### `tt task propagate`
```
tt task propagate [--from <parent-id>] [--to <child-id>...] [--rebase | --merge]
                  [--shallow] [--force] [--dry-run]
```
Rebase or merge descendant task branches onto the parent's current tip. Defaults to the current branch. If a descendant's task file cannot be read at its branch tip, propagate warns about it, checks the remaining descendants, then fails without changing any branch.

#### `tt task publish`
```
tt task publish [<project-id>] --target <branch> [-m <message>]
                [--changelog [--changelog-depth <n>]] [--force]
```
Merge a project branch into an external target branch (e.g. `main`). Removes task scaffolding files from the delivery branch. Use for projects, not tasks. The publish commit message comes from `-m`, or from an editor when it is omitted; an empty message cancels the publish. Always pass `-m` when running non-interactively: when stdin is not a terminal, omitting it is an error. `--changelog` prefills the message with a summary of the work since the target branch, bounded by `--changelog-depth`.

#### `tt task prompt`
```
tt task prompt [<task-id>] [--message <text>]
```
Write a self-contained implementation prompt for a task to stdout.

### Context commands

Context files are standalone freeform markdown files associated with a task, stored at `.tt/task/<slug>-<hex>/context/<ctx-slug>-<ctx-hex>.md`.

#### `tt task context add`  (alias: `tt add-context`)
```
tt task context add [<task-id>] [--title <title>] [--slug <slug>]
```
Create a context file. Body read from stdin if piped, otherwise opens editor. Examples:
```shell
tt task context add --title "Implementation plan" < ./plan.md
cat ./notes.md | tt task context add --title "Research notes"
tt task context add --title "Design notes"  # opens editor
```

#### `tt task context get`  (alias: `tt get-context`)
```
tt task context get [<context-id>...] [--task <task-id>]
```
Print context file(s), each as a frontmatter block naming the context ID, title, created and updated fields, then the trimmed body. If no IDs given, prints all context files for the task.

#### `tt task context list`  (alias: `tt list-context`)
```
tt task context list [<task-id>] [--task <task-id>]
```
List context IDs for a task (one per line).

#### `tt task context delete`  (alias: `tt delete-context`)
```
tt task context delete <context-id> [--task <task-id>]
```
Delete a context file and remove its `context:` entry from the task frontmatter.

### Worktree commands

#### `tt worktree switch`  (alias: `tt switch`)
```
tt worktree switch [<worktree-path>]
```
Redirect the virtual project's HEAD symlink to an existing worktree. The worktree must already exist (run `tt task checkout --worktree` first).

#### `tt worktree sync`  (alias: `tt sync`)
```
tt worktree sync [<worktree-path>] [--all] [--force]
```
Bring a worktree forward onto the head of the branch it is checked out on, updating its files to match. Use it when a command reports that worktrees are out of sync: a branch write advances the bookmark without moving any working copy but the invoking one. Uncommitted changes in the target worktree are preserved. Defaults to the worktree containing the current directory; `--all` synchronizes every out-of-sync worktree in the repository, plus the canonical repository when run from it. Reports the files added, modified and removed. Fires no hooks — the checked-out task does not change. Refuses a worktree whose uncommitted changes touch task metadata unless `--force`; with `--all` that worktree is skipped and the rest are synchronized.

#### `tt worktree refresh`  (alias: `tt refresh`)
```
tt worktree refresh [<path>] [--root] [--force]
```
Recover a stale workspace — one whose files belong to a rewritten commit, which `jj` refuses to load. Defaults to the worktree containing the current directory; `<path>` targets that worktree, `--root` targets the canonical repository root. There is no `--all`. Exits 0 silently when the target is not stale; without `--force` a stale target is reported and nothing changes. **Uncommitted changes in the recovered workspace are lost** — use `tt worktree sync` instead when the worktree is merely behind. Opens no transaction, so `tt history undo` does not revert it, and it stays usable while a transaction lock is present.

#### `tt worktree list`
```
tt worktree list [--task <task-id>] [--quiet]
```
List all worktrees and their corresponding tt task/project IDs. The canonical repository is not listed. `--quiet` prints names only.

#### `tt worktree show`
```
tt worktree show --name <worktree-name>
```
Output the path of the dedicated worktree with the given jj workspace name (the `NAME` column of `tt worktree list`). Worktrees are named after the task they were created for. Errors if no worktree bears that name.

#### `tt worktree delete`
```
tt worktree delete <worktree-path> [--force]
```
Delete the given worktree directory and remove its jj workspace. The task still exists and can be checked out again to recreate the worktree.

#### `tt worktree prune`
```
tt worktree prune [--dry-run] [--force]
```
Delete every worktree whose task is `DONE`, using `tt worktree delete` for each one. Prints each deleted path to stdout. `--dry-run` prints the same paths without deleting anything. `--force` is passed through to each delete. A worktree that fails to delete is reported and skipped, and the command exits non-zero.

---

## Standard tt workflow

All tasks should follow the general `tt` workflow:

1. **Create a task** — `tt task create --title "<title>" [--slug <slug>] [--parent <parent-task-id>] [--label <label>...] [--propagate] [--checkout [--worktree[=<path>]]]`. Creates a new task under the parent (default: current branch), adds `subtask: [ ] <task-id>` to the parent, and forks the child branch. The child branch's first commit points `./TASK.md` at the new task, so a worktree on the branch reports the task as current even before checkout. With `--propagate`, updates sibling branches. With `--checkout`, runs checkout on the newly created task; `--worktree` optionally uses or creates a worktree. Run `tt task create --help` for options.

2. **Begin a task** — `tt task checkout <task-id> [--worktree[=<path>]] [--switch] [--force]`. Switches to the task branch and updates status to IN-PROGRESS if TODO or DONE. Checkout does not change `./TASK.md`. With `--worktree`, uses or creates a worktree; `--switch` also updates the HEAD symlink to the new worktree. Run `tt task checkout --help` for options.

3. **Work on the task** — Make commits on the branch and accumulate context in `./TASK.md`.
   - **Add context** — Run `tt task context add [--title TITLE] [--slug SLUG]` to create a standalone context file for the task (reads body from stdin if piped, otherwise opens editor). Run `tt task context add --help` for options.
   - **Checkpoint** — Run `tt task checkpoint [-m <message>] [--squash]` to create a named checkpoint commit and advance the task bookmark. Run `tt task checkpoint --help` for options.

4. **Complete the task** — Run `tt task complete [<task-id>] [--force]`. Marks the task DONE with a `Complete task:` commit. Requires all child tasks done (use `--force` to bypass). Run `tt task complete --help` for options.

5. **Finish the task** — `tt task checkin [<task-id>] [--complete] [--rebase | --merge] [--delete] [--switch] [--propagate]`. Merges the task into its parent. With `--complete`, runs complete first if not DONE. With `--delete`, removes the task file after checkin (requires DONE). With `--switch`, moves `HEAD` to the parent task's worktree. With `--propagate`, updates sibling branches. Run `tt task checkin --help` for options.

Note that steps 1 and 2 can be combined into a single `tt task create --checkout` command, and steps 4 and 5 can be combined into a single `tt task checkin --complete` command.

## Workflow: Large tasks

Follow this workflow for tasks of sufficient complexity that they can sensibly be broken down into smaller, independent subtasks.

### Phase 1: Analysis

Begin by understanding the overall scope of the top-level task, then decompose it into a flat or nested set of child tasks:

1. Analyze the top-level task and identify a set of independent, well-scoped child tasks.
2. For each child task:
   - Write a comprehensive task description to `.agents/plans/<slug>-task-description.md`. This should include enough detail for an agent to implement the task autonomously without further context.
   - Create the task as a child of the current task, piping the description in from stdin (the command prints the new task ID to stdout):
     ```shell
     task_id=$(tt task create --slug <slug> --title "<title>" --propagate < .agents/plans/<slug>-task-description.md)
     ```
   - If the child task is itself complex enough to benefit from further decomposition, recursively apply the analysis phase to subdivide it into grandchild tasks, passing `--parent <task-id>` to register each grandchild under the correct parent:
     ```shell
     tt task create --slug <slug> --title "<title>" --parent "$task_id" --propagate < .agents/plans/<slug>-task-description.md
     ```

### Phase 2: Implementation

Work through each atomic leaf task (tasks with no incomplete children) in dependency order:

1. **Check out the task** in the current worktree:
   ```shell
   tt task checkout <task-id>
   ```

2. **Plan** (for non-trivial changes comprising more than a few lines):
   - Write an implementation plan to `.agents/plans/<task-id>-implementation-plan.md`.
   - Attach it to the task as a context file:
     ```shell
     tt task context add --title "Implementation Plan" < .agents/plans/<task-id>-implementation-plan.md
     ```

3. **Implement** the task, making incremental VCS commits to track atomic progress.

4. **Checkpoint** the completed work:
   ```shell
   tt task checkpoint --message "<summary>"
   ```

5. **Check in** the task and propagate to siblings, switching to the parent task afterwards:
   ```shell
   tt task checkin --complete --propagate --switch
   ```
   If useful handoff notes exist (e.g. decisions made, API shapes chosen, caveats for dependent tasks), write a handoff document to `.agents/plans/<task-id>-handoff.md` and include them in the checkin so they propagate to sibling and parent tasks:
   ```shell
   tt task checkin --complete --propagate --switch --context - < .agents/plans/<task-id>-handoff.md
   ```

6. **Check in the parent** if all sibling tasks are now complete. After checking in each leaf task, inspect the parent:
   ```shell
   tt task show <parent-task-id>
   ```
   If all subtasks listed in the parent are marked DONE, check in the parent as well (repeating step 5 at the parent level). This applies recursively for nested groups of grandchild tasks.

7. **Stop** when all child tasks are complete. Do **not** check in the top-level task until the user has reviewed and approved the changes.

---

## Workflow: Parallel development

Follow this workflow when the child tasks are independent enough to be developed concurrently. This is a variant of the Large Tasks workflow where Phase 2 is parallelized across multiple agents, each with their own isolated worktree.

Phase 1 (Analysis) is identical to the Large Tasks workflow.

### Phase 2: Parallel implementation

Instead of implementing child tasks sequentially, spawn one agent per child task and let them proceed concurrently, each in its own isolated worktree:

1. For each child task of the top-level task:
   a. **Check out a dedicated worktree** for the child task (the command prints the worktree path to stdout):
      ```shell
      worktree_path=$(tt task checkout <task-id> --worktree)
      ```
   b. **Generate a self-contained task prompt**:
      ```shell
      prompt=$(tt task prompt <task-id>)
      ```
   c. **Spawn an agent**, passing the worktree path and prompt. The agent should operate entirely within the given worktree and must not switch worktrees.

2. Each spawned agent follows the Large Tasks Phase 2 steps for its assigned child task, **with the following differences for parallel operation**:

   - **Stay in the assigned worktree.** Agents must not check out other tasks or switch workspaces. Each agent is responsible only for its own task. In particular, never pass `--switch` to `tt task checkin`: it would move the shared `HEAD` symlink out from under the other agents.
   - **Use the rebase-sync idiom** when checking in, to avoid merge conflicts and leaving sibling worktrees behind. Instead of a plain `tt task checkin`, run:
     ```shell
     tt task checkin --complete --rebase --propagate && tt worktree sync --all
     ```
     `--rebase` pulls the latest parent tip into the child branch before the check-in, and `tt worktree sync --all` brings every worktree the propagation left behind onto its branch head afterwards, preserving each one's uncommitted work.

### Caveats

- **Worktree isolation is strict.** The only mechanism of communication between agents is via propagated task context (handoff notes). Agents must not attempt to change worktree, or to read or write files in another agent's worktree.
- **Worktrees left behind.** A checkin that propagates to sibling branches advances those branches without touching the worktrees sitting on them, so those worktrees are left on the old tip. The command names each one it left behind; run `tt worktree sync --all` afterwards to bring them all forward. Do not hand-roll this with `jj` — `tt worktree sync` snapshots each worktree before moving it, so uncommitted work survives.
- **Conflict prevention.** Conflicts typically arise when the parent task has not been propagated into the child branch before check-in. Always use the rebase-sync idiom above to prevent this.
