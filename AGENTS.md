## Agent guidelines

Design decisions often require understanding convoluted edge case scenarios. Explain complex graph topology scenarios via worked examples described in bullet points and illustrated with `jj log` style graph diagrams.

## Coding guidelines

**IMPORTANT:** Make sure you read and thoroughly understand all coding guidelines from `@.agents/rules/` before making *any* code changes

## Design Documentation

A developer-facing design document for this project exists at `DESIGN.md`, and an agent-facing skill exists at `.agents/skills/tt/SKILL.md`.

**IMPORTANT:** Make sure to keep DESIGN.md and .agents/skills/tt/SKILL.md up-to-date whenever making changes that affect user-facing features.

## Task / VCS Management

Use the **bootstrap** `./scripts/cli/tt` CLI for task and VCS management. This bash-based tool is the current implementation while the full Rust CLI is being developed.

To see an overview of the current task, run `tt task show`.

**IMPORTANT:** The bootstrap CLI operates directly on this repository. `tt task checkout` changes the currently checked-out repository contents (switching branches/worktrees) and `tt worktree switch` redirects which worktree is active, either of which can be disorienting mid-session. Other commands write to branches without moving the working copy, and will instead report worktrees their write left out of sync — bring those forward with `tt worktree sync`. Always run both `jj log` and `tt task tree` before and after running any bootstrap CLI commands so you know exactly where you are and what changed.

Branch-writing commands refuse to run while the working-copy commit carries a bookmark. If you see `Error: The working-copy commit is the tip of bookmark '<name>'`, run `jj new` to start a working-copy commit above it and retry.

For documentation on `tt` commands, run one of the following:

```shell
tt --help
tt <command> --help
tt <command> <subcommand> --help
```

## Workflow

Use the `tt` skill for task management.

Make sure to add test scenarios for all features and bugfixes, and to run any relevant test suites when making changes.

**IMPORTANT:** Read test harness instructions in `./DEVELOPER.md` before running tests.

## Version Control

### Self-hosted task management

Progress on the implementation is represented as tasks in a `tt` task tree: create top-level tasks that correspond to the work (e.g. Phase 0, each command, or other coarse-grained units). Initially, when the tool does not yet exist or only partially exists, set up that structure by **manually** creating the VCS branches and **manually** creating or editing the task files (`.tt/task/...`) so that the task tree and branches match DESIGN.md’s model. As the tool gains functionality, **gradually use tt for day-to-day work**: create new tasks with `tt task create`, switch context with `tt task checkout`, merge completed work with `tt task checkin`, and use `tt task tree` and related commands to view and manage the tree. The repository thus becomes both the implementation of tt and a working example of its own workflow; new commands are developed and then used to manage the next slice of work.

`tt` uses `jj` as its backing store: `tt` commands provide a high-level interface over the underlying `jj` on-disk representation.

**When to use tt vs jj.** Use `tt` for the day-to-day task workflow: creating tasks, switching context, recording checkpoints, completing work, and merging it back. `tt` understands the task hierarchy, keeps task files and frontmatter in sync, and performs the right sequence of VCS operations for you. Reserve `jj` for low-level operations: inspecting history (`jj log`), viewing diffs (`jj diff`), or any operation that manipulates commits and branches directly without going through the task model.

### `jj` guidelines

The project uses `jj` for version control:

- WC changes are staged by default, no need for `git add`
- Use `jj commit -m <message>` instead of `git commit`
- Use `jj new <rev>` instead of `git checkout`

`jj` is in active development so do not assume your `jj` knowledge is up to date. For any other `jj` commands beyond these basics, always consult context7 docs for up-to-date usage instructions.

**Never push without being instructed.** Do not run `jj git push` (or any push) unless the user explicitly asks you to push.

### Destructive changes

**IMPORTANT:** Before performing any complex VCS operations, or operations that could change history (`squash`, `rebase`, etc), first capture the current `jj` operation ID:

```shell
jj op log --no-graph -T id -n 1
```

This state can then be restored via:

```shell
jj op restore <operation-id>
```
