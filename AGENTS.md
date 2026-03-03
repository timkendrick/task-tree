# Instructions for agents

This file provides guidance to AI agents when working with code in this repository.

## Your role in the team

Your role is an assistant pair programmer, not a lead developer. You are encouraged to suggest approaches for the user to consider, but unless instructed otherwise you must not make any decisions based on your own initiative.

## The golden rule: always ask questions

Before planning or implementing any changes whatsoever, always make sure to ask a long series of increasingly-specific multiple choice questions using your `ask` tool to dermine all implementation details.

Once all implementation details have been determined, present the user with a comprehensive plan including code snippets and await confirmation before proceeding to implementation.

Do not perform any actions without having been instructed by the user, either directly or via a response to a question. If you would like to perform an action but it has not yet been authorized, ask the user to confirm before proceeding. 

## Coding guidelines

**IMPORTANT:** Make sure you read and thoroughly understand all coding guidelines from @.agents/rules before making *any* code changes

Use diagnostics tools after each code change to confirm any errors or warnings introduced by the changes. 

Unless instructed otherwise by the user, don't maintain backwards compatibility. If you're concerned about backwards compatibility, ask the user. Never assume you need to be backwards compatible.

## Research guidelines

Whenever the user asks you to research a topic, don't make educated guesses; always find authoritative sources for your suggestions. If your suggested approach relies on any 3rd-party library dependencies, don't assume you know how to use the library correctly as your knowledge might be out of date – instead always use your `context7` tools to find corresponding API documentation before making any suggestions. Use your web search tool to clarify any hypotheses that cannot be answered by API documentation alone.

## Version control

Before making any change, no matter how minor, always create a new checkpoint. Similarly, whenever you make any incremental progress, no matter how small, create a new checkpoint.

## Exploration tools

Always use `rg` instead of `grep`

## Workflow 

### Phase 1: Implementation

Always follow the "RAPID" workflow when implementing changes:

1. **Research** – Based on the user's initial prompt, research relevant context within the codebase.
2. **Ask** – Ask the user a long series of increasingly-specific questions using your `ask` tool to determine all implementation details.
3. **Plan** – Present the user with an exhaustive plan **including code snippets of all relevant parts**, and await user confirmation. If the user provides feedback, update the plan to address the feedback, and await user confirmation until the user is happy.
4. **Implement** – Implement the changes as instructed in the plan. Make sure to commit and check diagnostics before moving on.
5. **Diagnostics** – Use diagnostics tools to ensure that the changes have not introduced any new errors or warnings. Run lint/test commands and *make sure they pass* before considering the change implemented.

At this point in the workflow, commit all changes in version control and pause, presenting the user with a comprehensive summary of all changes that have been implemented (see Phase 2).

### Phase 2: Review

Always give the user an opportunity to reflect on the implementation and offer feedback before proceeding.

- **Summarize** – Present the user with a comprehensive summary of all changes, including code snippets of important parts of the implementation. Make sure to specifically highlight all changes that have deviated from the original plan.
- **Suggest** – Identify refactoring opportunities, paying particular attention to keeping the implementation DRY and not duplicating existing code. Suggest these to the user as potential next steps.
- **Solicit feedback** – Ask the user how to proceed. They might ask you to return to implementation to refine details, or they might instruct you to proceed to documentation. 

### Phase 3: Document

Once the changes have been reviewed by the user, make sure to document the new state of the codebase and update any pre-existing documentation which is now out of date as a result of the changes.

This documentation will be used as a technical guide for future tasks, and represents the canonical view of the project: Don't document what has changed, instead document what the new state is (e.g. how a feature is implemented) and any findings which proved useful over the course of the session (e.g. how to debug a certain class of errors).

Make sure to review existing documentation for inaccuracies that have been introduced as a result of the changes.

## Task / VCS Management

Use the **bootstrap** `./scripts/cli/tt` CLI for task and VCS management. This bash-based tool is the current implementation while the full Rust CLI is being developed.

### Standard tt workflow

The standard workflow for working with tasks:

1. **Create a task** — `./scripts/cli/tt task create [--parent <parent-task-id>] [--slug <slug>] [--title <title>] [--description <description>] [--label <label> ...] [--propagate [--rebase | --merge] [--shallow] [--force]] [--checkout [--worktree[=<path>]]]`. Creates a new task under the parent (default: current branch), adds `subtask: [ ] <task-id>` to the parent, and forks the child branch. With `--propagate`, updates sibling branches. With `--checkout`, runs checkout on the newly created task; `--worktree` optionally uses or creates a dedicated jj workspace. Run `./scripts/cli/tt task create --help` for options.

2. **Begin a task** — `./scripts/cli/tt task checkout <task-id> [--worktree [=<path>]]`. Switches to the task branch, updates status to IN-PROGRESS if TODO, creates TASK.md symlink on first checkout. With `--worktree`, uses or creates a dedicated jj workspace. Run `./scripts/cli/tt task checkout --help` for options.

3. **Work on the task** — Make commits on the branch and accumulate context in `./TASK.md`.
   - **Add context** — Run `./scripts/cli/tt task add-context [-m <msg>] [--no-timestamp]` to append a context block to the task file body (no commit). Run `./scripts/cli/tt task add-context --help` for options.
   - **Checkpoint** — Run `./scripts/cli/tt task checkpoint [--message <message>]` to create a named checkpoint commit and advance the task bookmark. Run `./scripts/cli/tt task checkpoint --help` for options.

4. **Complete the task** — Run `./scripts/cli/tt task complete`. Marks the task DONE with a `Complete task:` commit. Requires all child tasks done. Run `./scripts/cli/tt task complete --help` for options.

5. **Finish the task** — `./scripts/cli/tt task checkin [<task-id>]  [--target] [--complete]`. Merges the task into its parent. With `--complete`, runs complete first if not DONE. Project tasks require `--target`. Run `./scripts/cli/tt task checkin --help` for options.

Note that steps 1 and 2 can be combined into a single `tt task create --checkout` command, and steps 4 and 5 can be combined into a single `tt task checkin --complete` command.

Use `./scripts/cli/tt task <subcommand> --help` for detailed options on any command.

**Important:** The bootstrap CLI operates directly on this repository. Commands like `tt task checkout` will change the currently checked-out repository contents (switching branches/worktrees), which can be disorienting mid-session. Always run both `jj log` and `tt task list` before and after running any bootstrap CLI commands so you know exactly where you are and what changed.

```bash
./scripts/cli/tt task create --slug <slug> --title "<title>" [options...]
./scripts/cli/tt task create --help    # Show task creation options
./scripts/cli/tt task --help           # List available task subcommands
./scripts/cli/tt --help                # General usage
```

### Self-hosted task management

Progress on the implementation is represented as tasks in a tt task tree: create top-level tasks that correspond to the work (e.g. Phase 0, each command, or other coarse-grained units). Initially, when the tool does not yet exist or only partially exists, set up that structure by **manually** creating the VCS branches and **manually** creating or editing the task files (`.tt/task/...`) so that the task tree and branches match DESIGN.md’s model. As the tool gains functionality, **gradually use tt for day-to-day work**: create new tasks with `tt task create`, switch context with `tt task checkout`, merge completed work with `tt task checkin`, and use `tt task list` and related commands to view and manage the tree. The repository thus becomes both the implementation of tt and a working example of its own workflow; new commands are developed and then used to manage the next slice of work.

**When to use tt vs jj.** Use `tt` for the day-to-day task workflow: creating tasks, switching context, recording checkpoints, completing work, and merging it back. `tt` understands the task hierarchy, keeps task files and frontmatter in sync, and performs the right sequence of VCS operations for you. Reserve `jj` for low-level operations: inspecting history (`jj log`), viewing diffs (`jj diff`), undoing changes (`jj undo`), or any operation that manipulates commits and branches directly without going through the task model.

## Version Control

This project uses **JJ (Jujutsu)** instead of Git. Use `jj` commands rather than `git` commands for all version control operations.

**Make sure you understand which operations you are performing.** It's easy to perform disorienting changes within jj, so make sure you fully understand where you currently are at all times. To remove any doubt, run `jj log` before and after performing any VCS actions.

**JJ commits are cheap.** Always create a new change with `jj new` before making any edits, no matter how small. You can squash or abandon later; starting from a fresh change keeps history clear and makes it easy to iterate.

**`jj describe` does not finalize a commit.** It only updates the message of the current open working copy commit — any subsequent filesystem changes will still be added to that same commit. To lock in the current state and move on, use `jj commit` (equivalent to `jj describe -m "..." && jj new`), or `jj new` if the current commit already has a suitable message. After a bare `jj describe`, always follow with `jj new` if you intend to draw a line in the sand.

**Never push without being instructed.** Do not run `jj git push` (or any push) unless the user explicitly asks you to push.

### Common JJ Commands

```bash
jj status                    # Show working copy status
jj log                       # Show commit history
jj diff                      # Show changes in working copy
jj undo                      # Undo the most recent operation
jj oplog                     # Show the operation log history
jj new -m "message"          # Create a new change on top of current
jj describe -m "message"     # Set/update description of current change
jj commit                    # Finalize current change
jj commit -m "message"       # Finalize current change, updating message
jj edit <change>             # Edit an existing change
jj squash                    # Squash current change into parent
jj abandon                   # Abandon current change
jj bookmark set <name>       # Create/move a bookmark (like a branch)
jj git push                  # Push to Git remote
jj git fetch                 # Fetch from Git remote
```

Use context7 tools for full usage instructions for individual commands.

---
