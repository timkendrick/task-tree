# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Task / VCS Management

Use the **bootstrap** `./scripts/cli/tt` CLI for task and VCS management. This bash-based tool is the current implementation while the full Rust CLI is being developed.

**Important:** The bootstrap CLI operates directly on this repository. Commands like `tt task checkout` will change the currently checked-out repository contents (switching branches/worktrees), which can be disorienting mid-session. Always run both `jj log` and `tt task list` before and after running any bootstrap CLI commands so you know exactly where you are and what changed.

```bash
./scripts/cli/tt task create --slug <slug> --title "<title>" [options...]
./scripts/cli/tt task create --help    # Show task creation options
./scripts/cli/tt task --help           # List available task subcommands
./scripts/cli/tt --help                # General usage
```

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
