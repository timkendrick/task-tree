## Coding guidelines

**IMPORTANT:** Make sure you read and thoroughly understand all coding guidelines from `@.agents/rules/` before making *any* code changes

## Design Documentation

A design document for this project exists at `DESIGN.md`. Make sure to keep this up-to-date whenever making changes that affect user-facing features.

## Task / VCS Management

Use the **bootstrap** `./scripts/cli/tt` CLI for task and VCS management. This bash-based tool is the current implementation while the full Rust CLI is being developed.

To see an overview of the current task, run `tt task show`.

**Important:** The bootstrap CLI operates directly on this repository. Commands like `tt task checkout` will change the currently checked-out repository contents (switching branches/worktrees), which can be disorienting mid-session. Always run both `jj log` and `tt task tree` before and after running any bootstrap CLI commands so you know exactly where you are and what changed.

For documentation on `tt` commands, run one of the following:

```shell
tt --help
tt <command> --help
tt <command> <subcommand> --help
```

## Workflow

Use the `rapid-workflow` skill for all non-trivial changes.

Use the `tt` skill for task management.

## Version Control

### Self-hosted task management

Progress on the implementation is represented as tasks in a tt task tree: create top-level tasks that correspond to the work (e.g. Phase 0, each command, or other coarse-grained units). Initially, when the tool does not yet exist or only partially exists, set up that structure by **manually** creating the VCS branches and **manually** creating or editing the task files (`.tt/task/...`) so that the task tree and branches match DESIGN.md’s model. As the tool gains functionality, **gradually use tt for day-to-day work**: create new tasks with `tt task create`, switch context with `tt task checkout`, merge completed work with `tt task checkin`, and use `tt task tree` and related commands to view and manage the tree. The repository thus becomes both the implementation of tt and a working example of its own workflow; new commands are developed and then used to manage the next slice of work.

This project uses **JJ (Jujutsu)** instead of Git. Use `jj` commands rather than `git` commands for all version control operations.

**Make sure you understand which operations you are performing.** It's easy to perform disorienting changes within jj, so make sure you fully understand where you currently are at all times. To remove any doubt, run `jj log` before and after performing any VCS actions.

**Always have a roll-back strategy.** Before performing any `jj` operation, capture the prior repository state operation ID via `jj op log --no-graph -T id -n 1`. This state can then be restored via `jj op restore <operation-id>`. Always use this rollback mechanism rather than attempting to revert individual changes.

**JJ commits are cheap.** Always create a new change with `jj new` before making any edits, no matter how small. You can squash or abandon later; starting from a fresh change keeps history clear and makes it easy to iterate.

**`jj describe` does not finalize a commit.** It only updates the message of the current open working copy commit — any subsequent filesystem changes will still be added to that same commit. To lock in the current state and move on, use `jj commit` (equivalent to `jj describe -m "..." && jj new`), or `jj new` if the current commit already has a suitable message. After a bare `jj describe`, always follow with `jj new` if you intend to draw a line in the sand.

**Never push without being instructed.** Do not run `jj git push` (or any push) unless the user explicitly asks you to push.

**When to use tt vs jj.** Use `tt` for the day-to-day task workflow: creating tasks, switching context, recording checkpoints, completing work, and merging it back. `tt` understands the task hierarchy, keeps task files and frontmatter in sync, and performs the right sequence of VCS operations for you. Reserve `jj` for low-level operations: inspecting history (`jj log`), viewing diffs (`jj diff`), undoing changes (`jj undo`), or any operation that manipulates commits and branches directly without going through the task model.

#### Common JJ Commands

```bash
jj status                    # Show working copy status
jj log                       # Show commit history
jj diff                      # Show changes in working copy
jj undo                      # Undo the most recent operation
jj oplog                     # Show the operation log history
jj new -m "message"          # Create a new change on top of current
jj commit -m "message"       # Finalize current change, updating message
jj squash                    # Squash current change into parent
jj abandon                   # Abandon current change
jj bookmark set <name>       # Create/move a bookmark (like a branch)
jj git push                  # Push to Git remote
jj git fetch                 # Fetch from Git remote
```

Use `context7` tools for full usage instructions for all `jj` commands.

---
