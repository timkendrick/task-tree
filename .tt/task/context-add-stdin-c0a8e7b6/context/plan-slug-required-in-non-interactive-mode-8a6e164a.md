---
title: "Plan: --slug required in non-interactive mode"
created: 2026-03-22T17:19:29Z
updated: 2026-03-22T17:19:29Z
---
# Plan: `--slug` required in non-interactive mode

## Goal

When `tt task create` is invoked in non-interactive mode (stdin is not a TTY — e.g. piped or redirected), make `--slug` a required argument instead of silently falling back to the auto-derived default.

---

## Affected files

| File | Change |
|------|--------|
| `scripts/cli/task/create` | Add guard in slug-resolution block; update top-of-file comment and `usage()` |
| `DESIGN.md` | Document requirement in §5.2 and §6.1 |

---

## Research findings

### Current slug-resolution block (`scripts/cli/task/create`)

Located after the title-prompt block, around line 185–200:

```bash
local default_slug
default_slug="$(title_to_slug "$title")"
if [[ "$slug_explicit" == false ]]; then
  if [[ -z "$default_slug" ]]; then
    log "Error: Could not generate slug from title: $title"
    exit 1
  fi
  if [[ -t 0 ]]; then
    local prompted_slug
    read -e -p "Enter a task identifier (defaults to $default_slug): " prompted_slug
    slug="${prompted_slug:-$default_slug}"
  else
    slug="$default_slug"   # ← silently uses derived slug today
  fi
fi
```

Two things change here:
1. The `default_slug` local variable and its assignment are moved *inside* the `if [[ "$slug_explicit" == false ]]; then` block (they are only needed there).
2. The `else` branch (stdin not a TTY, `--slug` not given) is replaced with an error instead of silently defaulting.

### Existing error patterns in the script

Other argument errors in this script follow the pattern:

```bash
log "Error: <message>"
usage
```

where `usage()` prints the full help text to stderr and calls `exit 1`. This is the pattern to follow.

### Top-of-file comment block (line ~15)

```
#   --slug SLUG            Human-readable slug (prompted with suggested default if missing)
```

### `usage()` function (line ~45)

```
  --slug SLUG           Human-readable slug (prompted with suggested default if missing)
```

### DESIGN.md — §5.2 `tt task create` relevant excerpt

> Prompts for title if not provided. Reads the task body/description from stdin (via pipe or redirect) if stdin is not a terminal; otherwise opens an editor for body input.

### DESIGN.md — §6.1 Task creation

Describes `--parent` behaviour and preconditions. The slug defaulting behaviour is not currently documented here.

---

## Questionnaire transcript

**Q1: What should the error message say when --slug is missing in non-interactive mode?**
- ✅ `Error: --slug is required in non-interactive mode`

**Q2: Should the error call `usage()` (printing full help + exit 1) or just log the error and exit 1?**
- ✅ Call `usage()` — print full help text and exit 1

**Q3: Where should the non-interactive --slug check be placed?**
- ✅ Inside the existing slug resolution block — right after detecting non-interactive mode, before `slug="$default_slug"`

**Q4: Should `usage()` text and top-of-file comment be updated?**
- ✅ Yes — update both the comment block and the `usage()` function

**Q5: Should `DESIGN.md` be updated?**
- ✅ Yes — add a note in §5.2 (tt task create) and/or §6.1

---

## Decision log

| Decision | Choice | Rationale |
|---|---|---|
| Error message | `Error: --slug is required in non-interactive mode` | User's choice |
| Error handling | `log` + `usage()` (prints full help + exits 1) | User's choice; consistent with other argument errors in the script |
| Check placement | Inside existing slug block, replacing `slug="$default_slug"` | User's choice; keeps all slug logic in one place |
| Comment/usage update | Both top-of-file comment and `usage()` updated | User's choice |
| DESIGN.md update | §5.2 and §6.1 | User's choice |

---

## Detailed changes

### 1. `scripts/cli/task/create` — slug-resolution block

**Before** (the entire block, including the unconditional `default_slug` lines above the `if`):
```bash
local default_slug
default_slug="$(title_to_slug "$title")"
if [[ "$slug_explicit" == false ]]; then
  if [[ -z "$default_slug" ]]; then
    log "Error: Could not generate slug from title: $title"
    exit 1
  fi
  if [[ -t 0 ]]; then
    local prompted_slug
    read -e -p "Enter a task identifier (defaults to $default_slug): " prompted_slug
    slug="${prompted_slug:-$default_slug}"
  else
    slug="$default_slug"
  fi
fi
```

**After** (`default_slug` moved inside the block; `else` branch replaced with error):
```bash
if [[ "$slug_explicit" == false ]]; then
  local default_slug
  default_slug="$(title_to_slug "$title")"
  if [[ -z "$default_slug" ]]; then
    log "Error: Could not generate slug from title: $title"
    exit 1
  fi
  if [[ -t 0 ]]; then
    local prompted_slug
    read -e -p "Enter a task identifier (defaults to $default_slug): " prompted_slug
    slug="${prompted_slug:-$default_slug}"
  else
    log "Error: --slug is required in non-interactive mode"
    usage
  fi
fi
```

### 2. Top-of-file comment (`scripts/cli/task/create`)

**Before:**
```
#   --slug SLUG            Human-readable slug (prompted with suggested default if missing)
```

**After:**
```
#   --slug SLUG            Human-readable slug (required in non-interactive mode; prompted otherwise)
```

### 3. `usage()` function (`scripts/cli/task/create`)

**Before:**
```
  --slug SLUG           Human-readable slug (prompted with suggested default if missing)
```

**After:**
```
  --slug SLUG           Human-readable slug (required in non-interactive mode; prompted otherwise)
```

### 4. `DESIGN.md` — §5.2 (`tt task create`)

Add after the sentence: *"Reads the task body/description from stdin (via pipe or redirect) if stdin is not a terminal; otherwise opens an editor for body input."*

Add: **`--slug` is required when stdin is not a terminal (non-interactive mode); in interactive mode the user is prompted with a suggested default derived from the title.**

### 5. `DESIGN.md` — §6.1 (Task creation)

Add under the `**With --parent:**` section, after the description of how the child branch is initialised:

> **Slug requirement:** In non-interactive mode (stdin is not a terminal), `--slug` must be provided explicitly; the command errors if it is omitted. In interactive mode the user is prompted with a suggested default derived from the title.

---

## Task list

- [ ] Create a new jj change (`jj new -m "require --slug in non-interactive mode for tt task create"`)
- [ ] Edit `scripts/cli/task/create`: move `default_slug` declaration/assignment inside the `if [[ "$slug_explicit" == false ]]; then` block, and replace `slug="$default_slug"` in the else branch with the error + `usage` call
- [ ] Edit `scripts/cli/task/create`: update the top-of-file `--slug` comment line
- [ ] Edit `scripts/cli/task/create`: update the `usage()` `--slug` line
- [ ] Edit `DESIGN.md`: add sentence in §5.2
- [ ] Edit `DESIGN.md`: add note in §6.1
- [ ] Commit the change with `jj commit -m "..."`
- [ ] Verify no shell diagnostics / lint issues (shellcheck if available)
