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

## Standard tt workflow

The standard workflow for working with tasks:

1. **Create a task** — `tt task create --title "<title>" [--slug <slug>] [--parent <parent-task-id>] [--label <label>...] [--propagate] [--checkout [--worktree[=<path>]]]`. Creates a new task under the parent (default: current branch), adds `subtask: [ ] <task-id>` to the parent, and forks the child branch. With `--propagate`, updates sibling branches. With `--checkout`, runs checkout on the newly created task; `--worktree` optionally uses or creates a dedicated jj workspace. Run `tt task create --help` for options.

2. **Begin a task** — `tt task checkout <task-id> [--worktree[=<path>]] [--switch] [--force]`. Switches to the task branch, updates status to IN-PROGRESS if TODO, creates TASK.md symlink on first checkout. With `--worktree`, uses or creates a dedicated jj workspace; `--switch` also updates the HEAD symlink to the new worktree. Run `tt task checkout --help` for options.

3. **Work on the task** — Make commits on the branch and accumulate context in `./TASK.md`.
   - **Add context** — Run `tt task context add [--title TITLE] [--slug SLUG]` to create a standalone context file for the task (reads body from stdin if piped, otherwise opens editor). Run `tt task context add --help` for options.
   - **Checkpoint** — Run `tt task checkpoint [-m <message>] [--squash]` to create a named checkpoint commit and advance the task bookmark. Run `tt task checkpoint --help` for options.

4. **Complete the task** — Run `tt task complete [<task-id>] [--force]`. Marks the task DONE with a `Complete task:` commit. Requires all child tasks done (use `--force` to bypass). Run `tt task complete --help` for options.

5. **Finish the task** — `tt task checkin [<task-id>] [--complete] [--rebase | --merge] [--delete] [--propagate]`. Merges the task into its parent. With `--complete`, runs complete first if not DONE. With `--delete`, removes the task file after checkin (requires DONE). Run `tt task checkin --help` for options.

Note that steps 1 and 2 can be combined into a single `tt task create --checkout` command, and steps 4 and 5 can be combined into a single `tt task checkin --complete` command.

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
Creates a task under the current branch (or `--parent`). Body read from stdin if piped.

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
                [--context <markdown>] [--retain-worktree]
                [--propagate [--propagate-rebase | --propagate-merge]
                [--propagate-shallow] [--propagate-force] [--propagate-dry-run]
                [--propagate-to <child-id>]]
```
Merge a task branch into its parent. `--complete` marks it done first. `--delete` removes the task file after checkin. `--propagate` propagates the updated parent tip to sibling branches.

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

### Workspace commands

#### `tt workspace init`  (alias: `tt init`)
```
tt workspace init <path-to-repo> <path-to-virtual-project-folder> [--task-prefix <prefix>]
                  [--project-prefix <prefix>] [--force]
```
Initialize a new tt workspace. Creates `.tt/config.toml` in the repo and the virtual project folder.

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

### History commands

#### `tt history undo`  (alias: `tt undo`)
```
tt history undo [--force]
```
Undo the most recent mutating `tt` command by restoring the jj repository to the operation state before that command ran. The outgoing operation ID is logged so it can be manually restored with `jj op restore <id>`. `--force` bypasses safety checks (stale lock, op ID mismatch, dirty WC).
