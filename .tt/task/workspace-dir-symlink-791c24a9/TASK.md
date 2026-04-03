---
title: "Replace `workspace_dir` config with `.tt/workspace` symlink"
status: IN-PROGRESS
created: 2026-04-03T18:46:44Z
updated: 2026-04-03T18:46:45Z
---
Replace the `workspace_dir` key in `.tt/config.toml` with a machine-local `.tt/workspace`
symlink. `.tt/config.toml` is committed to the repo, making `workspace_dir` unsuitable for
storing a local filesystem path. The symlink is gitignored and serves as the per-checkout
pointer to the virtual project directory.

## Design

- `.tt/workspace` — a symlink to the virtual project directory (e.g. `/Users/tim/Sites/task-tree`)
- Added to `.tt/.gitignore` by `tt workspace init` (alongside `/history`)
- Resolved by a new `get_workspace_dir` implementation: `readlink "$repo/.tt/workspace"`
- Each jj worktree has its own working copy of `.tt/`, so the symlink must be planted
  separately in each worktree. `tt task checkout --worktree` does this automatically when
  creating a new worktree.

## Changes required

### `scripts/cli/workspace/init`
- Add `/workspace` to the `.tt/.gitignore` it writes
- Create `.tt/workspace` symlink pointing to the virtual project dir (alongside creating `HEAD`)
- Do **not** write `workspace_dir` to `config.toml` (it was never in the spec; only the test
  harness injected it as a workaround)

### `scripts/cli/lib/common.sh` — `get_workspace_dir`
- Replace TOML-parsing implementation with `readlink "$repo/.tt/workspace"`

### `scripts/cli/task/checkout`
- When creating a new worktree (`jj workspace add`), plant `.tt/workspace` symlink in the
  new worktree, copying it from the current repo's `.tt/workspace` if it exists

### `scripts/cli/task/checkin`, `task/checkout`, `task/checkpoint`, `task/complete`,
`task/context/add`, `task/delete`, `task/move`, `task/publish`, `task/rename`,
`workspace/switch`
- Remove `--workspace-dir` CLI option and all `get_workspace_dir` fallback calls
  from all of these commands; `get_workspace_dir` (reading `.tt/workspace`) is now
  the sole resolution mechanism — no flag needed
- Remove all `--workspace-dir` pass-throughs (e.g. in `checkin` calling `complete`)

### `scripts/harness/harness.sh` — `setup_workspace`
- Remove the manual `workspace_dir = "..."` injection into `.tt/config.toml`
- Instead create `.tt/workspace` symlink in the repo pointing to `$VIRTUAL` after
  `tt workspace init` (mirroring what `workspace init` now does automatically)

### `DESIGN.md`
- Remove all mentions of `workspace_dir` in `.tt/config.toml`
- Remove `--workspace-dir` option from all command signatures
- Add a note to §6.2 describing the `.tt/workspace` symlink and its gitignored status
- Update §9 step 1 to describe the symlink instead of the config key
