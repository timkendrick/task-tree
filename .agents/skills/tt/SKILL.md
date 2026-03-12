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

1. **Create a task** — `./scripts/cli/tt task create [--parent <parent-task-id>] [--slug <slug>] [--title <title>] [--description <description>] [--label <label> ...] [--propagate [--rebase | --merge] [--shallow] [--force]] [--checkout [--worktree[=<path>]]]`. Creates a new task under the parent (default: current branch), adds `subtask: [ ] <task-id>` to the parent, and forks the child branch. With `--propagate`, updates sibling branches. With `--checkout`, runs checkout on the newly created task; `--worktree` optionally uses or creates a dedicated jj workspace. Run `./scripts/cli/tt task create --help` for options.

2. **Begin a task** — `./scripts/cli/tt task checkout <task-id> [--worktree [=<path>]]`. Switches to the task branch, updates status to IN-PROGRESS if TODO, creates TASK.md symlink on first checkout. With `--worktree`, uses or creates a dedicated jj workspace. Run `./scripts/cli/tt task checkout --help` for options.

3. **Work on the task** — Make commits on the branch and accumulate context in `./TASK.md`.
   - **Add context** — Run `./scripts/cli/tt task add-context [-m <msg>] [--no-timestamp]` to append a context block to the task file body (no commit). Run `./scripts/cli/tt task add-context --help` for options.
   - **Checkpoint** — Run `./scripts/cli/tt task checkpoint [--message <message>]` to create a named checkpoint commit and advance the task bookmark. Run `./scripts/cli/tt task checkpoint --help` for options.

4. **Complete the task** — Run `./scripts/cli/tt task complete`. Marks the task DONE with a `Complete task:` commit. Requires all child tasks done. Run `./scripts/cli/tt task complete --help` for options.

5. **Finish the task** — `./scripts/cli/tt task checkin [<task-id>]  [--target] [--complete]`. Merges the task into its parent. With `--complete`, runs complete first if not DONE. Project tasks require `--target`. Run `./scripts/cli/tt task checkin --help` for options.

Note that steps 1 and 2 can be combined into a single `tt task create --checkout` command, and steps 4 and 5 can be combined into a single `tt task checkin --complete` command.

## Command reference

Use `./scripts/cli/tt task <subcommand> --help` for detailed options on any command.

```shell
./scripts/cli/tt task create --slug <slug> --title "<title>" [options...]
./scripts/cli/tt task create --help    # Show task creation options
./scripts/cli/tt task --help           # List available task subcommands
./scripts/cli/tt --help                # General usage
```
