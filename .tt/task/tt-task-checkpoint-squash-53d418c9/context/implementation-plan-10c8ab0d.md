---
title: "Implementation plan"
created: 2026-04-03T09:08:03Z
updated: 2026-04-03T09:08:03Z
---
# Plan: Add `--squash` argument to `tt task checkpoint`

## Task

**Task ID:** `task/tt-task-checkpoint-squash-53d418c9`  
**Parent:** `project/bootstrap-cli-d35756ce`  
**Script:** `scripts/cli/task/checkpoint`  
**Design doc:** `DESIGN.md` (§6.3 and the command reference at line ~292)

---

## Background & Research Findings

### What `tt task checkpoint` currently does

`scripts/cli/task/checkpoint` runs:

```bash
jj -R "$repo" commit -m "$full_msg"         # closes @ and opens new empty WC
jj -R "$repo" bookmark set "$bookmark" -r '@-'  # advance bookmark to that commit
```

Before those operations it resolves the current branch, optionally opens an editor for the message, runs the pre-checkpoint hook, and begins a transaction. After, it runs the post-checkpoint hook and commits the transaction.

Typical commit graph before checkpoint:

```
bookmark → A → B → C → @ (open, empty WC)
```

After normal checkpoint:

```
bookmark → A → B → C → Checkpoint → @ (new open WC)
                              ↑
                         bookmark now here
```

### What `--squash` should do

Collapse all commits between the bookmark and `@` (inclusive of WC changes) into a single commit stacked directly after the bookmark, then advance the bookmark to it.

Before:

```
bookmark → A → B → C → @ (open WC, may have pending changes)
```

After:

```
bookmark → Checkpoint → @ (new open WC)
                 ↑
            bookmark now here
            (A, B, C abandoned automatically by jj)
```

### jj mechanics verified empirically

**Step 1 — squash intermediates into `@`:**

```bash
jj squash --from "<bookmark>::@- ~ <bookmark>" --into @ -m "<full_msg>"
```

- The revset `<bookmark>::@- ~ <bookmark>` expands to all commits strictly between the bookmark and `@-` (exclusive of the bookmark itself, exclusive of `@`).
- jj moves all content changes from those commits into `@`.
- Each source commit becomes empty and is automatically abandoned by jj (no `--keep-emptied`).
- `-m "<full_msg>"` sets the description on `@` to the checkpoint message, suppressing the interactive editor.
- After this step `@` sits directly on the bookmark with all accumulated changes and the right description.

**Step 2 — close `@`:**

```bash
jj new
```

- `jj commit -m "..."` = `jj describe -m "..."` + `jj new`. Since `@` already has the right description after step 1, we only need `jj new` to close it and open a fresh empty WC.
- The bookmark advance (`jj bookmark set "$bookmark" -r '@-'`) then works identically to the normal path.

**Edge case — nothing to squash:**

If `@-` is already the bookmark (no intermediate commits exist), the revset `<bookmark>::@- ~ <bookmark>` is empty. We detect this and skip the squash step, falling through to the normal `jj commit -m "$full_msg"` flow.

Detection:

```bash
local intermediate_count
intermediate_count="$(jj -R "$repo" log -r "${bookmark}::@- ~ ${bookmark}" --no-graph -T 'commit_id' 2>/dev/null | wc -l)"
```

If `intermediate_count` is 0, skip squash and run the normal commit flow.

---

## Questions & Decisions

| # | Question | Decision |
|---|----------|----------|
| 1 | What is the commit range to squash? | `bookmark+::@` inclusive (WC changes included) |
| 2 | What if there are no intermediate commits? | Proceed normally (skip squash, just `jj commit`) |
| 3 | What message does the squashed commit use? | The checkpoint message: `Checkpoint: <message> (<task-id>)` |
| 4 | What jj mechanism? | Single `jj squash --from "..." --into @ -m "..."` + `jj new` |

---

## Task List

- [ ] **1. Create jj commit** before making any changes
- [ ] **2. Add `--squash` flag** to argument parsing in `scripts/cli/task/checkpoint`
- [ ] **3. Update `usage()`** to document the new flag
- [ ] **4. Implement squash logic** in `main()`:
  - [ ] 4a. After the message is resolved (before hook), detect intermediate commit count
  - [ ] 4b. If `--squash` and intermediates exist: run `jj squash --from ... --into @ -m "$full_msg"` then `jj new`
  - [ ] 4c. If `--squash` and no intermediates: fall through to normal `jj commit -m "$full_msg"`
  - [ ] 4d. Normal (non-squash) path unchanged: `jj commit -m "$full_msg"`
- [ ] **5. Update DESIGN.md** — §6.3 and command reference (~line 292)
- [ ] **6. Run diagnostics / smoke test**
- [ ] **7. Commit**

---

## Implementation Detail

### Argument parsing addition

```bash
local squash=false

# in the while loop:
      --squash)
        squash=true
        shift
        ;;
```

### Usage update

```
Usage: ${SCRIPT_NAME} [-m <message>] [--squash] [--repo PATH] [--workspace-dir PATH]

Options:
  -m, --message <msg>   Commit message (skips editor prompt).
  --squash              Squash all commits since the last bookmark into a single checkpoint commit.
  --repo PATH           Repository root (overrides TT_REPO; default: walk up from CWD to find .jj).
  --workspace-dir PATH  Virtual project dir. Overrides workspace_dir in .tt/config.toml.
```

### Squash logic (replaces the current `jj commit` block)

```bash
  if [[ "$squash" == true ]]; then
    # Count commits strictly between bookmark and @-
    local intermediate_count
    intermediate_count="$(jj -R "$repo" log \
      -r "${bookmark}::@- ~ ${bookmark}" \
      --no-graph -T 'commit_id' 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "$intermediate_count" -gt 0 ]]; then
      # Squash all intermediate commits into @, setting the checkpoint message
      jj -R "$repo" squash \
        --from "${bookmark}::@- ~ ${bookmark}" \
        --into @ \
        -m "$full_msg"
      # @ now has the right content and description; just open a new WC
      jj -R "$repo" new
    else
      # Nothing to squash — behave like normal checkpoint
      jj -R "$repo" commit -m "$full_msg"
    fi
  else
    jj -R "$repo" commit -m "$full_msg"
  fi
```

### DESIGN.md changes

**Command reference (~line 292):** Update the one-liner for `tt task checkpoint` to mention `--squash`:

> **`tt task checkpoint [--message <msg>] [--squash]`** — … With `--squash`, squashes all commits between the last bookmark and the current working copy into a single checkpoint commit. See §6.3.

**§6.3 body:** Add a `--squash` subsection after the existing "Commit flow" paragraph:

> #### 6.3.2 Squashing intermediate commits (`--squash`)
>
> When `--squash` is passed, `tt task checkpoint` collapses all commits between the most recent bookmark state and the current working copy into a single checkpoint commit stacked directly after the bookmark. Intermediate commits are automatically abandoned by jj.
>
> **Commit flow with `--squash`:**
>
> 1. Count commits in the range `<bookmark>::@- ~ <bookmark>`. If none exist, fall back to the normal commit flow.
> 2. Run `jj squash --from "<bookmark>::@- ~ <bookmark>" --into @ -m "<full-message>"` to merge all intermediate commits into `@` and set its description.
> 3. Run `jj new` to close `@` and open a fresh working copy.
> 4. Advance the bookmark to `@-` as normal.
>
> **When there is nothing to squash** (the working copy parent is already the bookmark), `--squash` behaves identically to a normal checkpoint.

---

## Files Changed

| File | Change |
|------|--------|
| `scripts/cli/task/checkpoint` | Add `--squash` flag; add squash logic before `jj commit` |
| `DESIGN.md` | Update §6.3 and command reference |
