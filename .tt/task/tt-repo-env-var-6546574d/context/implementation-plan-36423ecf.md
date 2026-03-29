---
title: "Implementation plan"
created: 2026-03-29T08:31:39Z
updated: 2026-03-29T08:31:39Z
---
# Plan: Support `TT_REPO` Environment Variable

**Task:** `task/tt-repo-env-var-6546574d`  
**Goal:** Make all `tt` commands honour a `TT_REPO` environment variable as a fallback for `--repo PATH`. `--repo` always takes priority; `TT_REPO` is used if `--repo` is not given and no `.jj` directory is found walking up from CWD.

---

## Summary of changes

1. **`scripts/cli/lib/common.sh`** — Add a `resolve_repo` helper function.
2. **All 23 command scripts** — Replace the `--repo`-resolution block (3–4 lines) with a single call to `resolve_repo`. Also update help text and usage strings to document `TT_REPO`.
3. **`DESIGN.md`** — Add a note in §5 (Commands) explaining `--repo` / `TT_REPO` resolution.

---

## Research findings

### Files affected

All scripts under `scripts/cli/` except `scripts/cli/workspace/init` (which takes a positional `<path-to-repo>` argument and does not use `find_repo_root`):

| Script | Has `--repo`? |
|---|---|
| `scripts/cli/task/checkin` | ✅ |
| `scripts/cli/task/checkout` | ✅ |
| `scripts/cli/task/checkpoint` | ✅ |
| `scripts/cli/task/complete` | ✅ |
| `scripts/cli/task/create` | ✅ |
| `scripts/cli/task/current` | ✅ |
| `scripts/cli/task/delete` | ✅ |
| `scripts/cli/task/edit` | ✅ |
| `scripts/cli/task/move` | ✅ |
| `scripts/cli/task/parent` | ✅ |
| `scripts/cli/task/prompt` | ✅ |
| `scripts/cli/task/propagate` | ✅ |
| `scripts/cli/task/publish` | ✅ |
| `scripts/cli/task/rename` | ✅ |
| `scripts/cli/task/show` | ✅ |
| `scripts/cli/task/tree` | ✅ |
| `scripts/cli/workspace/branch` | ✅ |
| `scripts/cli/workspace/switch` | ✅ |
| `scripts/cli/workspace/worktree` | ✅ |
| `scripts/cli/history/undo` | ✅ |
| `scripts/cli/task/context/add` | ✅ |
| `scripts/cli/task/context/delete` | ✅ |
| `scripts/cli/task/context/get` | ✅ |
| `scripts/cli/task/context/list` | ✅ |
| `scripts/cli/workspace/init` | ❌ (positional arg; not applicable) |

### Current `--repo` resolution pattern

Every affected script currently has this pattern (after arg-parsing):

```bash
  # Resolve repo root
  if [[ -z "$repo" ]]; then
    if ! repo="$(find_repo_root)"; then
      log "Error: No enclosing jj repository. Use --repo to specify."
      exit 1
    fi
  fi
  if [[ ! -d "$repo/.jj" ]]; then
    log "Error: Not a jj repository: $repo"
    exit 1
  fi
```

Minor variations in the first error message (e.g. "no .jj directory found" vs "Use --repo to specify.") but the structure is identical.

### Priority order

```
--repo PATH  >  TT_REPO  >  find_repo_root() (walk up CWD)
```

---

## Design decisions

- **Where the logic lives:** A new `resolve_repo` function in `common.sh` handles the full fallback chain. Each command script calls `resolve_repo "$repo"` and captures the result. This is DRY and keeps all scripts consistent.
- **Error messages:** The helper emits human-readable errors that mention both `--repo` and `TT_REPO`.
- **`workspace/init`:** Not changed — it receives the repo path as a positional argument and doesn't call `find_repo_root`.

---

## Implementation plan

### Step 1: Add `resolve_repo` to `common.sh`

Add the following function to `scripts/cli/lib/common.sh`, after the existing `find_repo_root` function:

```bash
# Usage: repo=$(resolve_repo "$repo_flag_value")
#
# Resolves the repository root using the following priority order:
#   1. $repo_flag_value — the value passed to --repo (if non-empty)
#   2. $TT_REPO        — the TT_REPO environment variable (if set and non-empty)
#   3. find_repo_root  — walk up from CWD to find a .jj directory
#
# Prints the resolved repo path to stdout.
# Exits 1 with an error message if the path cannot be resolved or is not a jj repo.
resolve_repo() {
  local repo="${1:-}"

  # Priority 1: explicit --repo flag
  if [[ -z "$repo" ]]; then
    # Priority 2: TT_REPO environment variable
    if [[ -n "${TT_REPO:-}" ]]; then
      repo="$TT_REPO"
    else
      # Priority 3: walk up from CWD
      if ! repo="$(find_repo_root)"; then
        log "Error: No enclosing jj repository. Use --repo or set TT_REPO."
        exit 1
      fi
    fi
  fi

  if [[ ! -d "$repo/.jj" ]]; then
    log "Error: Not a jj repository: $repo"
    exit 1
  fi

  printf '%s' "$repo"
}
```

### Step 2: Update each command script

For each of the 24 affected command scripts, make two changes:

#### 2a. Replace the `--repo` resolution block

Replace:

```bash
  # Resolve repo root
  if [[ -z "$repo" ]]; then
    if ! repo="$(find_repo_root)"; then
      log "Error: No enclosing jj repository. Use --repo to specify."
      exit 1
    fi
  fi
  if [[ ! -d "$repo/.jj" ]]; then
    log "Error: Not a jj repository: $repo"
    exit 1
  fi
```

With:

```bash
  repo="$(resolve_repo "$repo")"
```

(The exact wording of the error messages varies slightly across scripts, but the replacement is the same single line in all cases.)

#### 2b. Update `--repo` help text to mention `TT_REPO`

In each script's usage/help text, find the line that documents `--repo`, e.g.:

```
  --repo PATH           Repository root (default: walk up from CWD to find .jj).
```

And update it to:

```
  --repo PATH           Repository root (overrides TT_REPO env var; default: walk up from CWD to find .jj).
```

The exact phrasing differs slightly per script — all occurrences of `--repo PATH` lines (both in the inline comment block and in the `usage()` function) should be updated.

### Step 3: Update `DESIGN.md`

Add a note in the §5 Commands section (before §5.0 History) explaining the `--repo` / `TT_REPO` mechanism. The note should be added right before the `### 5.0 History` heading.

```markdown
### Repository root resolution

All `tt` commands that accept a `--repo PATH` option resolve the repository root using the following priority order:

1. **`--repo PATH`** — the explicit flag value, if provided.
2. **`TT_REPO`** — the value of the `TT_REPO` environment variable, if set and non-empty.
3. **CWD walk** — walk up from the current working directory until a `.jj` directory is found.

The command exits with an error if none of these resolves to a valid jj repository. `tt workspace init` is exempt — it always takes the repository path as a required positional argument.
```

---

## Task checklist

- [x] Create new jj change
- [x] Add `resolve_repo` to `scripts/cli/lib/common.sh`
- [x] Update `scripts/cli/task/checkin`
- [x] Update `scripts/cli/task/checkout`
- [x] Update `scripts/cli/task/checkpoint`
- [x] Update `scripts/cli/task/complete`
- [x] Update `scripts/cli/task/create`
- [x] Update `scripts/cli/task/current`
- [x] Update `scripts/cli/task/delete`
- [x] Update `scripts/cli/task/edit`
- [x] Update `scripts/cli/task/move`
- [x] Update `scripts/cli/task/parent`
- [x] Update `scripts/cli/task/prompt`
- [x] Update `scripts/cli/task/propagate`
- [x] Update `scripts/cli/task/publish`
- [x] Update `scripts/cli/task/rename`
- [x] Update `scripts/cli/task/show`
- [x] Update `scripts/cli/task/tree`
- [x] Update `scripts/cli/workspace/branch`
- [x] Update `scripts/cli/workspace/switch`
- [x] Update `scripts/cli/workspace/worktree`
- [x] Update `scripts/cli/history/undo`
- [x] Update `scripts/cli/task/context/add`
- [x] Update `scripts/cli/task/context/delete`
- [x] Update `scripts/cli/task/context/get`
- [x] Update `scripts/cli/task/context/list`
- [x] Update `DESIGN.md`
- [x] Run diagnostics (shellcheck if available; smoke-test `tt task current --help`)
- [x] Commit
