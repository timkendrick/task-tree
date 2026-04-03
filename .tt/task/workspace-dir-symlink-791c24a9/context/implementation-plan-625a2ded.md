---
title: "Implementation plan"
created: 2026-04-03T18:59:44Z
updated: 2026-04-03T18:59:44Z
---
# Plan: Replace `workspace_dir` config with `.tt/workspace` symlink

## Task

`task/workspace-dir-symlink-791c24a9`

Replace the `workspace_dir` key in `.tt/config.toml` with a machine-local `.tt/workspace` symlink. The symlink is gitignored and serves as the per-checkout pointer to the virtual project directory.

Additionally, update the automatic `jj workspace` naming to use the full `task/`/`project/` prefixed task/project name.

---

## Research Findings

### Codebase Overview

All CLI scripts are in `scripts/cli/`. The shared library is `scripts/cli/lib/common.sh`. The test harness is in `scripts/harness/harness.sh`.

### Current `get_workspace_dir` (in `scripts/cli/lib/common.sh`, lines 185–197)

```bash
# Read workspace_dir from .tt/config.toml; returns 1 if not configured.
get_workspace_dir() {
  local repo="$1"
  local config="$repo/.tt/config.toml"
  if [[ -r "$config" ]]; then
    local ws_dir
    ws_dir="$(convfmt --from toml --to json < "$config" | jq -r '.workspace_dir // ""')" || true
    if [[ -n "$ws_dir" ]]; then
      printf '%s' "$ws_dir"
      return 0
    fi
  fi
  return 1
}
```

### Current `setup_workspace` (in `scripts/harness/harness.sh`, lines ~72–89)

```bash
setup_workspace() {
  local name="${1:-test-$$-$RANDOM}"
  REPO="$_TEST_ROOT/$name/repo"
  VIRTUAL="$_TEST_ROOT/$name/virtual"
  mkdir -p "$REPO"

  jj git init "$REPO" >/dev/null 2>&1
  cd "$REPO"

  echo "initial" > README.md
  jj -R "$REPO" commit -m "Initial commit" >/dev/null 2>&1
  jj -R "$REPO" bookmark set main >/dev/null 2>&1

  "$TT" workspace init "$REPO" "$VIRTUAL" >/dev/null 2>&1

  # Append workspace_dir to config.toml so get_workspace_dir() works.
  printf '\n# Virtual project directory\nworkspace_dir = "%s"\n' "$VIRTUAL" \
    >> "$REPO/.tt/config.toml"

  # Commit the config update so it's tracked
  jj -R "$REPO" commit -m "Configure workspace_dir" >/dev/null 2>&1
  jj -R "$REPO" bookmark set main >/dev/null 2>&1

  # Export so run_tt forwards it as --repo to all tt commands
  export TT_REPO="$REPO"
}
```

### Commands that accept `--workspace-dir` and call `get_workspace_dir`

| File | Notes |
|------|-------|
| `scripts/cli/workspace/switch` | Full flag + fallback to `get_workspace_dir` |
| `scripts/cli/task/checkout` | Full flag + fallback to `get_workspace_dir` |
| `scripts/cli/task/checkin` | Full flag + fallback + passes it to `complete` and `delete` sub-invocations |
| `scripts/cli/task/complete` | Full flag + fallback |
| `scripts/cli/task/delete` | Full flag + fallback |
| `scripts/cli/task/context/add` | Full flag + fallback |
| `scripts/cli/task/move` | Full flag + fallback |
| `scripts/cli/task/publish` | Full flag + fallback |
| `scripts/cli/task/checkpoint` | Full flag + fallback |
| `scripts/cli/task/rename` | Flag declared but **never calls `get_workspace_dir`** |

### `workspace init` (in `scripts/cli/workspace/init`)

Currently:
1. Creates `.tt/config.toml` with `task_prefix` and `project_prefix` only
2. Creates `.tt/.gitignore` with `/history`
3. Creates `HEAD` symlink in virtual folder → repo
4. Commits with `"Create workspace"`

Does **not** create `.tt/workspace` symlink or write `workspace_dir` to config (the test harness does that manually afterwards).

### `task checkout` worktree creation (in `scripts/cli/task/checkout`, line ~249)

```bash
jj "${jj_opts[@]}" workspace add -r "$task_id" "$target_worktree"
```

No `--name` flag currently. The jj workspace name is derived automatically from the directory name.

### `workspace switch.test.sh` line 46

```bash
virtual_dir="$(sed -n 's/^workspace_dir *= *//p' "$REPO/.tt/config.toml" | tr -d '"')"
```

This directly reads `workspace_dir` from `config.toml`. Must be updated to use `readlink "$REPO/.tt/workspace"`.

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| `get_workspace_dir` reads `readlink "$repo/.tt/workspace"` | As specified in task description |
| Return 1 if symlink doesn't exist | Same semantics as before; callers all use `|| true` fallback |
| `workspace init` creates `.tt/workspace` → virtual dir | Specified; alongside `HEAD` creation |
| `.tt/.gitignore` gets `/workspace` entry | Specified |
| `workspace init` does NOT write `workspace_dir` to config | Specified |
| `task checkout --worktree` passes `--name "$task_id"` | Specified; uses the full `task/foo-abc12345` name |
| `task checkout --worktree` plants `.tt/workspace` symlink in new worktree | Specified; copy from `$repo/.tt/workspace` if it exists |
| Remove `--workspace-dir` flag from all commands in scope | Specified: `task/context/add`, `task/delete`, `task/move`, `task/publish`, `task/rename`, `workspace/switch`, plus `task/complete`, `task/checkpoint`, `task/checkout`, `task/checkin` |
| Remove `--workspace-dir` pass-throughs in `checkin` → `complete`/`delete` | Specified |
| Test harness: replace `workspace_dir` injection with `.tt/workspace` symlink | Specified |

---

## Task List

- [ ] Step 0: Create VCS checkpoint before starting
- [ ] Step 1: Update `get_workspace_dir` in `scripts/cli/lib/common.sh`
- [ ] Step 2: Update `workspace init` — add `/workspace` to `.tt/.gitignore` and create `.tt/workspace` symlink
- [ ] Step 3: Update `task checkout` — pass `--name "$task_id"` to `jj workspace add`, plant `.tt/workspace` symlink in new worktree
- [ ] Step 4: Remove `--workspace-dir` flag and `get_workspace_dir` fallback from all commands
- [ ] Step 5: Update test harness `setup_workspace` — remove `workspace_dir` injection, add `.tt/workspace` symlink
- [ ] Step 6: Update `workspace/switch.test.sh` — replace `sed` config read with `readlink`
- [ ] Step 7: Update `workspace/init.test.sh` — verify `.tt/workspace` symlink exists and `.tt/.gitignore` has `/workspace`
- [ ] Step 8: Run all tests and verify they pass
- [ ] Step 9: Update `DESIGN.md` per task spec

---

## Implementation Details

### Step 1: `get_workspace_dir` in `scripts/cli/lib/common.sh`

**Old** (lines 185–197):
```bash
# Read workspace_dir from .tt/config.toml; returns 1 if not configured.
get_workspace_dir() {
  local repo="$1"
  local config="$repo/.tt/config.toml"
  if [[ -r "$config" ]]; then
    local ws_dir
    ws_dir="$(convfmt --from toml --to json < "$config" | jq -r '.workspace_dir // ""')" || true
    if [[ -n "$ws_dir" ]]; then
      printf '%s' "$ws_dir"
      return 0
    fi
  fi
  return 1
}
```

**New**:
```bash
# Read workspace dir from .tt/workspace symlink; returns 1 if not configured.
get_workspace_dir() {
  local repo="$1"
  local symlink="$repo/.tt/workspace"
  if [[ -L "$symlink" ]]; then
    local ws_dir
    ws_dir="$(readlink "$symlink")"
    if [[ -n "$ws_dir" ]]; then
      printf '%s' "$ws_dir"
      return 0
    fi
  fi
  return 1
}
```

### Step 2: `workspace init` — `scripts/cli/workspace/init`

Two changes:
1. Add `/workspace` to the `.tt/.gitignore` content
2. Create `.tt/workspace` symlink → virtual dir (using absolute path, same as `HEAD` symlink in virtual dir)

**Old** `.gitignore` write:
```bash
# Write .tt/.gitignore to ignore the transaction history log
local gitignore_file="$repo_abs/.tt/.gitignore"
printf '/history\n' > "$gitignore_file"
```

**New**:
```bash
# Write .tt/.gitignore to ignore the transaction history log and workspace symlink
local gitignore_file="$repo_abs/.tt/.gitignore"
printf '/history\n/workspace\n' > "$gitignore_file"
```

After creating `.tt/history`, add:
```bash
# Create .tt/workspace symlink pointing to virtual folder
ln -snf "$virtual_dir" "$repo_abs/.tt/workspace"
log "Created .tt/workspace -> $virtual_dir"
```

Also update the `.gitignore` mentions in the `usage()` function and final log message to reflect `/workspace` is added.

Note: `.tt/workspace` is ignored (won't be part of the `Create workspace` commit), just like `.tt/history`. The commit still includes only `.tt/config.toml` and `.tt/.gitignore`.

### Step 3: `task checkout` — `scripts/cli/task/checkout`

**Old** new-worktree creation (line ~249):
```bash
log "Creating workspace: $target_worktree"
jj "${jj_opts[@]}" workspace add -r "$task_id" "$target_worktree"
```

**New**:
```bash
log "Creating workspace: $target_worktree"
jj "${jj_opts[@]}" workspace add --name "$task_id" -r "$task_id" "$target_worktree"
# Plant .tt/workspace symlink in the new worktree
local src_workspace="$repo/.tt/workspace"
if [[ -L "$src_workspace" ]]; then
  local wt_tt_dir="$target_worktree/.tt"
  mkdir -p "$wt_tt_dir"
  ln -snf "$(readlink "$src_workspace")" "$wt_tt_dir/workspace"
fi
```

Note: jj workspace add creates the new worktree with a `.jj` symlink but also copies the `.tt/` directory into the worktree. Each worktree has its own working copy of `.tt/`, so planting the symlink in `$target_worktree/.tt/workspace` is correct.

**Also remove the `--workspace-dir` error message** that references `workspace_dir` in config (line ~202):
```bash
# Old:
if [[ -z "$workspace_dir" ]]; then
  log "Error: --worktree requires either --workspace-dir or an explicit path (--worktree=<path>)"
  log "  Set workspace_dir in .tt/config.toml or pass --workspace-dir."
  exit 1
fi

# New:
if [[ -z "$workspace_dir" ]]; then
  log "Error: --worktree requires a workspace dir (set via .tt/workspace symlink) or an explicit path (--worktree=<path>)"
  log "  Run 'tt workspace init' to create the .tt/workspace symlink."
  exit 1
fi
```

### Step 4: Remove `--workspace-dir` from all commands

For each of the following files, remove:
- The `--workspace-dir` option from the usage header comment and `usage()` function
- The `local workspace_dir=''` variable
- The `--workspace-dir)` case in the arg parser
- The `if [[ -z "$workspace_dir" ]]; then workspace_dir="$(get_workspace_dir "$repo")" || true; fi` block
- All `${workspace_dir:+--workspace-dir "$workspace_dir"}` pass-throughs in sub-command invocations
- Keep all `"${workspace_dir:-}"` usages in `run_hook`, `perform_workspace_switch`, `update_head_symlink` calls — but the value is now obtained solely from `get_workspace_dir` at the start

**Files to update:**
- `scripts/cli/workspace/switch`
- `scripts/cli/task/checkout`
- `scripts/cli/task/checkin`
- `scripts/cli/task/complete`
- `scripts/cli/task/delete`
- `scripts/cli/task/context/add`
- `scripts/cli/task/move`
- `scripts/cli/task/publish`
- `scripts/cli/task/checkpoint`
- `scripts/cli/task/rename`

**Pattern for each command** (where `get_workspace_dir` was called):

Remove the flag declaration/parsing block. Replace the "resolve" block with a single unconditional call:

```bash
# Resolve workspace dir via .tt/workspace symlink
local workspace_dir
workspace_dir="$(get_workspace_dir "$repo")" || true
```

For `scripts/cli/task/checkin`, also remove the `--workspace-dir` pass-through to `complete` and `delete` sub-invocations:

```bash
# Old in checkin calling complete:
"$SCRIPT_DIR/complete" --repo "$repo" \
  ${workspace_dir:+--workspace-dir "$workspace_dir"} \
  ...

# New:
"$SCRIPT_DIR/complete" --repo "$repo" \
  ...
```

```bash
# Old in checkin calling delete:
"$SCRIPT_DIR/delete" "$task_id" --force \
  --repo "$repo" \
  ${workspace_dir:+--workspace-dir "$workspace_dir"} \
  ...

# New:
"$SCRIPT_DIR/delete" "$task_id" --force \
  --repo "$repo" \
  ...
```

### Step 5: Test harness `setup_workspace`

**Old** (lines ~82–89 in `scripts/harness/harness.sh`):
```bash
"$TT" workspace init "$REPO" "$VIRTUAL" >/dev/null 2>&1

# Append workspace_dir to config.toml so get_workspace_dir() works.
printf '\n# Virtual project directory\nworkspace_dir = "%s"\n' "$VIRTUAL" \
  >> "$REPO/.tt/config.toml"

# Commit the config update so it's tracked
jj -R "$REPO" commit -m "Configure workspace_dir" >/dev/null 2>&1
jj -R "$REPO" bookmark set main >/dev/null 2>&1
```

**New**:
```bash
"$TT" workspace init "$REPO" "$VIRTUAL" >/dev/null 2>&1
# workspace init now creates .tt/workspace symlink automatically; no further setup needed.
```

Remove the two `jj commit` / `jj bookmark set` lines that were used to commit the workspace_dir config update. The `workspace init` command already commits `.tt/config.toml` and `.tt/.gitignore` with `"Create workspace"`.

### Step 6: `workspace/switch.test.sh`

**Old** (line ~46):
```bash
virtual_dir="$(sed -n 's/^workspace_dir *= *//p' "$REPO/.tt/config.toml" | tr -d '"')"
```

**New**:
```bash
virtual_dir="$(readlink "$REPO/.tt/workspace")"
```

### Step 7: `workspace/init.test.sh`

Add assertion in `test_workspace_init__basic_initialization`:
```bash
# Check .tt/.gitignore has /workspace
assert_contains "gitignore has /workspace" "$gitignore" "/workspace"

# Check .tt/workspace symlink exists pointing to virtual dir
assert_symlink ".tt/workspace symlink" "$repo/.tt/workspace" "$virtual"
```

### Step 9: DESIGN.md updates

1. **§3 Config** — Remove `workspace_dir` from the "Config:" bullet:
   - Old: "`.tt/config.toml` stores `task_prefix` (default `task/`) and `project_prefix` (default `project/`), both set via `tt workspace init`."
   - Keep as is (no `workspace_dir` was ever specified there in the design)

2. **§6.2** — Add a note describing the `.tt/workspace` symlink:
   After the paragraph describing `HEAD`, add:
   > **`.tt/workspace`** — a machine-local symlink pointing to the virtual project directory (e.g. `/Users/tim/Sites/task-tree`). It is created by `tt workspace init` and listed in `.tt/.gitignore`, so it is never tracked by jj. Because each jj worktree has its own copy of `.tt/`, the symlink must be planted separately in each worktree; `tt task checkout --worktree` does this automatically when creating a new worktree. Commands that need the virtual project directory (e.g. for updating `HEAD` or running hooks) resolve it by reading this symlink via `readlink "$repo/.tt/workspace"`.

3. **§9 step 1** — Update the "Initialize" description to mention the symlink:
   - Old: "…`.tt/config.toml` (task prefix default `task/`, project prefix default `project/`), and a `HEAD` symlink…"
   - New: "…`.tt/config.toml` (task prefix default `task/`, project prefix default `project/`), a `.tt/workspace` symlink pointing to the virtual project directory, a `.tt/.gitignore` (containing `/history` and `/workspace`) and a `HEAD` symlink…"

4. **§7 test harness note** — Remove mention of `workspace_dir` in `.tt/config.toml`:
   - Old: "The workspace includes `workspace_dir` in `.tt/config.toml` for worktree-related tests."
   - New: "The workspace includes a `.tt/workspace` symlink pointing to the virtual project directory for worktree-related tests."

---

## Files to Modify

| File | Changes |
|------|---------|
| `scripts/cli/lib/common.sh` | Replace `get_workspace_dir` implementation |
| `scripts/cli/workspace/init` | Add `/workspace` to `.gitignore`, create `.tt/workspace` symlink |
| `scripts/cli/task/checkout` | Add `--name "$task_id"` to `jj workspace add`, plant `.tt/workspace` in new worktree, remove `--workspace-dir` flag |
| `scripts/cli/task/checkin` | Remove `--workspace-dir` flag and pass-throughs |
| `scripts/cli/task/complete` | Remove `--workspace-dir` flag |
| `scripts/cli/task/delete` | Remove `--workspace-dir` flag |
| `scripts/cli/task/context/add` | Remove `--workspace-dir` flag |
| `scripts/cli/task/move` | Remove `--workspace-dir` flag |
| `scripts/cli/task/publish` | Remove `--workspace-dir` flag |
| `scripts/cli/task/checkpoint` | Remove `--workspace-dir` flag |
| `scripts/cli/task/rename` | Remove `--workspace-dir` flag (never used but accepted) |
| `scripts/cli/workspace/switch` | Remove `--workspace-dir` flag |
| `scripts/harness/harness.sh` | Remove `workspace_dir` injection; no extra commit needed |
| `scripts/cli/workspace/switch.test.sh` | Replace `sed` config read with `readlink` |
| `scripts/cli/workspace/init.test.sh` | Add `/workspace` in gitignore and `.tt/workspace` symlink assertions |
| `DESIGN.md` | Update §6.2, §9 step 1, §7 test harness note |
