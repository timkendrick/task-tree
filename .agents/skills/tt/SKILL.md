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

### Task commands

#### `tt task create`
```
tt task create --title "<title>" [--slug <slug>] [--parent <task-id>]
               [--label <label>...] [--propagate [--rebase | --merge] [--shallow] [--force]]
               [--checkout [--worktree[=<path>]]]
```
Creates a task under the current branch (or `--parent`). Body read from stdin if piped. On success, prints the generated task ID to stdout (all other output is on stderr) so it can be piped, e.g. `tt task checkout "$(tt task create --slug foo --title 'Foo' < ./desc.md)"`.

#### `tt task checkout`
```
tt task checkout <task-id> [--worktree[=<path>]] [--switch] [--force]
```
Switch to the given task branch. `--worktree` uses/creates a dedicated jj workspace; `--switch` also updates HEAD to the new worktree. Returns the worktree path to stdout for piping into other commands.

#### `tt task checkpoint`
```
tt task checkpoint [-m <message>] [--squash]
```
Record the current state of work. `--squash` collapses all commits since the last bookmark into a single checkpoint commit.

#### `tt task complete`
```
tt task complete [<task-id>] [--worktree=<path>] [--force]
```
Mark a task DONE. Requires all child tasks to be done, unless `--force` is given.

#### `tt task checkin`
```
tt task checkin [<task-id>] [--complete] [--rebase | --merge] [--force] [--delete]
                [--context <markdown>|-] [--retain-worktree]
                [--propagate [--propagate-rebase | --propagate-merge]
                [--propagate-shallow] [--propagate-force] [--propagate-dry-run]
                [--propagate-to <child-id>]]
```
Merge a task branch into its parent. `--complete` marks it done first. `--delete` removes the task file after checkin. `--propagate` propagates the updated parent tip to sibling branches.

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

#### `tt task diff`  (alias: `tt diff`)
```
tt task diff [--task <task-id>] [--include-metadata] [--repo PATH]
```
Show the diff of all unmerged commits on a task branch since it diverged from its parent branch. Output is written in standard Git diff format. Without `--task`, uses the current task and includes trailing commits and uncommitted working-copy changes. Changes to tt metadata (the `.tt/` directory and the root `TASK.md` symlink) are omitted unless `--include-metadata` is passed.

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
tt task delete [<task-id>] [--worktree=<path>] [--force]
```
Remove a task from its parent branch. `--force` skips DONE and clean working-copy checks.

#### `tt task propagate`
```
tt task propagate [--from <parent-id>] [--to <child-id>...] [--rebase | --merge]
                  [--shallow] [--force] [--dry-run]
```
Rebase or merge descendant task branches onto the parent's current tip. Defaults to the current branch.

#### `tt task publish`
```
tt task publish [<project-id>] --target <branch> [--rebase | --merge] [--force]
```
Merge a project branch into an external target branch (e.g. `main`). Removes task scaffolding files from the delivery branch. Use for projects, not tasks.

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
Print raw content of context file(s). If no IDs given, prints all context files for the task.

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
tt worktree switch [<worktree-path>] [--force]
```
Redirect the virtual project's HEAD symlink to an existing worktree. The worktree must already exist (run `tt task checkout --worktree` first).

#### `tt worktree list`
```
tt worktree list [--task <task-id>] [--quiet]
```
List all jj workspaces and their corresponding tt task/project IDs. `--quiet` prints names only.

#### `tt worktree show`
```
tt worktree show --task <task-id>
```
Output the worktree path for a task or project ID. Falls back to the repo root if no dedicated worktree exists.

#### `tt worktree delete`
```
tt worktree delete <worktree-path> [--force]
```
Delete the given worktree directory and remove its jj workspace. The task still exists and can be checked out again to recreate the worktree.

---

## Standard tt workflow

All tasks should follow the general `tt` workflow:

1. **Create a task** — `tt task create --title "<title>" [--slug <slug>] [--parent <parent-task-id>] [--label <label>...] [--propagate] [--checkout [--worktree[=<path>]]]`. Creates a new task under the parent (default: current branch), adds `subtask: [ ] <task-id>` to the parent, and forks the child branch. With `--propagate`, updates sibling branches. With `--checkout`, runs checkout on the newly created task; `--worktree` optionally uses or creates a dedicated jj workspace. Run `tt task create --help` for options.

2. **Begin a task** — `tt task checkout <task-id> [--worktree[=<path>]] [--switch] [--force]`. Switches to the task branch, updates status to IN-PROGRESS if TODO, creates TASK.md symlink on first checkout. With `--worktree`, uses or creates a dedicated jj workspace; `--switch` also updates the HEAD symlink to the new worktree. Run `tt task checkout --help` for options.

3. **Work on the task** — Make commits on the branch and accumulate context in `./TASK.md`.
   - **Add context** — Run `tt task context add [--title TITLE] [--slug SLUG]` to create a standalone context file for the task (reads body from stdin if piped, otherwise opens editor). Run `tt task context add --help` for options.
   - **Checkpoint** — Run `tt task checkpoint [-m <message>] [--squash]` to create a named checkpoint commit and advance the task bookmark. Run `tt task checkpoint --help` for options.

4. **Complete the task** — Run `tt task complete [<task-id>] [--force]`. Marks the task DONE with a `Complete task:` commit. Requires all child tasks done (use `--force` to bypass). Run `tt task complete --help` for options.

5. **Finish the task** — `tt task checkin [<task-id>] [--complete] [--rebase | --merge] [--delete] [--propagate]`. Merges the task into its parent. With `--complete`, runs complete first if not DONE. With `--delete`, removes the task file after checkin (requires DONE). With `--propagate`, updates sibling branches. Run `tt task checkin --help` for options.

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

5. **Check in** the task and propagate to siblings:
   ```shell
   tt task checkin --complete --propagate
   ```
   If useful handoff notes exist (e.g. decisions made, API shapes chosen, caveats for dependent tasks), write a handoff document to `.agents/plans/<task-id>-handoff.md` and include them in the checkin so they propagate to sibling and parent tasks:
   ```shell
   tt task checkin --complete --propagate --context - < .agents/plans/<task-id>-handoff.md
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

   - **Stay in the assigned worktree.** Agents must not check out other tasks or switch workspaces. Each agent is responsible only for its own task.
   - **Use the rebase-refresh idiom** when checking in, to avoid merge conflicts and stale working copies. Instead of a plain `tt task checkin`, run:
     ```shell
     tt task checkin --complete --rebase --propagate \
       && jj workspace update-stale && jj workspace list --template 'name ++ "\n"' \
         | while read workspace; do
            echo "Updating workspace: $workspace"
            (cd $(jj workspace root --name "$workspace") && jj workspace update-stale)
            done
     ```
     This sequence ensures the latest parent tip is rebased into the child branch before check-in, and that all workspaces are brought up to date afterward.

### Caveats

- **Worktree isolation is strict.** The only mechanism of communication between agents is via propagated task context (handoff notes). Agents must not attempt to change worktree, or to read or write files in another agent's worktree.
- **Stale workspaces.** After any checkin that propagates to sibling branches, all other workspaces that share those branches may become stale. Run `jj workspace update-stale` in each affected workspace after propagation. If needed, this can be automated with a shell alias:
  ```shell
  jj workspace update-stale && jj workspace list --template 'name ++ "\n"' \
    | while read workspace; do
        echo "Updating workspace: $workspace"
        (cd $(jj workspace root --name "$workspace") && jj workspace update-stale)
      done
  ```
- **Conflict prevention.** Conflicts typically arise when the parent task has not been propagated into the child branch before check-in. Always use the rebase-refresh idiom above to prevent this.
