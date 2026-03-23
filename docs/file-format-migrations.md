# File Format Migrations

This guide describes how to safely perform migrations to the tt on-disk file format when the format changes in an incompatible way. It is based on the experience of the `standalone-context-files` migration (2026-03-15), which converted all task files from a flat format (`task/<slug>.md`) to a directory format (`task/<slug>/TASK.md` with optional `context/` files).

---

## Overview

A file format migration involves three concerns:

1. **The migration script** — a one-off script that rewrites task files on disk from the old format to the new format
2. **The rollout** — applying the script to every `task/*` and `project/*` bookmark in the repository, in the right order, without breaking anything
3. **The CLI scripts** — must be updated to read/write the new format before migration happens; the migration runs *after* the new format is already implemented

Because tt is self-hosting (the repository uses its own tooling), the migration must be applied to every branch that contains task files — not just the current working copy. jj's ability to create new commits on any bookmark without checking it out makes this tractable.

---

## Principles

- **Never rewrite history.** The migration creates new commits on each bookmark. `jj undo` or `jj bookmark set --allow-backwards` can roll back any individual branch.
- **Record commit IDs before touching anything.** Before migrating any branch, capture the current commit ID. This is your rollback anchor.
- **Test on a synthetic or isolated branch first.** Run the migration against a known-good test fixture before touching real branches. Validate the output before proceeding.
- **Migrate one branch at a time.** Verify each branch before moving to the next.
- **Stop and ask if anything is unexpected.** Do not attempt to fix unexpected states — roll back and seek guidance.

---

## Writing the Migration Script

The migration script must:

1. Accept `--repo PATH` to operate on a specific workspace directory (essential for isolated testing)
2. Accept `--workspace PATH` to create an isolated jj workspace for a single bookmark, run the migration inside it, and clean up automatically
3. Accept `--revision <rev>` to assert that a given revision is an ancestor of the target bookmark (safety guard — ensures the bookmark already has the correct version of the migration script)
4. Accept `--retain-workspace` to suppress automatic cleanup, leaving the workspace on disk for post-migration inspection
5. Use only `jj -R "$REPO_DIR"` for all VCS operations — never assume the current working directory is the repo root
6. Create a new WC with `jj new <bookmark>` before making filesystem changes, then commit with `jj commit -m "Migrate task files to <format>"` and advance the bookmark with `jj bookmark set <bookmark> -r '@-'`
7. Print the workspace name to **stdout** (one line); write all other output to **stderr** (`log()` → `>&2`)

### Workspace isolation pattern

The `--workspace` flag creates a jj workspace at the given path, checked out at the target bookmark. This means all `jj -R "$REPO_DIR"` calls affect only the temporary workspace's working copy — the main workspace is untouched:

```bash
jj -R "$ORIGINAL_REPO_DIR" workspace add \
  --revision "$target_bookmark" \
  --name "$ws_name" \
  "$workspace_dir"
REPO_DIR="$workspace_dir"
# ... run migration ...
# cleanup:
jj -R "$ORIGINAL_REPO_DIR" workspace forget "$ws_name"
rm -rf "$workspace_dir"
```

**Important:** `jj workspace add --revision <rev>` checks out `<rev>` as the initial working-copy commit, but `migrate_bookmark()` immediately runs `jj new <bookmark>` which moves the WC anyway. The `--revision` argument to the *migration script* is therefore **not** passed to `workspace add` — it is only used for the ancestry check.

### Ancestry check pattern

The `--revision` flag verifies that the given revision is an ancestor of the target bookmark before proceeding. This confirms the target has the correct version of the migration script in its history:

```bash
ancestry_check="$(jj -R "$REPO_DIR" --ignore-working-copy \
  log -r "${workspace_revision}::${target_bookmark}" --no-graph \
  -T 'commit_id ++ "\n"' 2>/dev/null)"
if [[ -z "$ancestry_check" ]]; then
  log "Error: '$workspace_revision' is not an ancestor of '$target_bookmark'."
  log "  jj rebase -b $target_bookmark -d $workspace_revision"
  exit 1
fi
```

Note: `-T '""'` does not work here — it always produces empty stdout even when matches exist. Use `-T 'commit_id ++ "\n"'`.

### Variables in trap functions

Bash trap functions (registered with `trap '...' EXIT`) do not inherit `local` variables from the calling function — they run after the function returns, outside its scope. Any variable a trap function needs must be declared at global scope (e.g. `_WS_NAME`, `_WS_DIR`) rather than as `local` variables inside `main()`.

---

## Writing the Test Script

Before running the migration on real branches, test it against a known fixture.

### Test fixture setup

The test bookmark should be a branch that:
- Contains task files in the **old** format
- Descends from the feature branch (so `--revision` check passes)
- Is not used for any real work (can be reset and re-migrated freely)

If the feature branch is itself an ancestor of the test bookmark, reset the test bookmark to the feature branch tip before each test run:

```bash
jj bookmark set task/test-migration-<hex> \
  -r task/<feature-branch> --allow-backwards
```

### Test script structure

```bash
# 1. Capture workspace name from migration script stdout
WS_NAME=$(bash scripts/migrate-task-files.sh \
  --repo "$REPO_DIR" \
  --workspace "$TMPDIR_WS" \
  --revision "$FEATURE_BRANCH" \
  --retain-workspace \
  "$TEST_BOOKMARK")

# 2. Run assertions against files on disk in $TMPDIR_WS
#    and against the jj tree via --ignore-working-copy

# 3. Verify via jj file list using the MAIN repo root, not the workspace dir
#    (jj file list outputs absolute paths when -R points to a non-root workspace)
jj -R "$REPO_DIR" --ignore-working-copy file list -r "$TEST_BOOKMARK"

# 4. Clean up
jj -R "$REPO_DIR" workspace forget "$WS_NAME"
rm -rf "$TMPDIR_WS"
```

### Key gotcha: `jj file list` path format

When `jj -R <path>` is used and `<path>` is not the repo root (e.g. it's a workspace directory nested inside a temp path), `jj file list` outputs **absolute paths** rather than repo-relative paths. Always run `jj file list` against the main repo root (`-R "$REPO_DIR"`) so that output paths are repo-relative and can be grepped with patterns like `^\.tt/task/`.

---

## Rollout Procedure

### 1. Survey the repository

Before touching anything, record the current commit ID of every `task/*` and `project/*` bookmark. This is your rollback table.

```bash
jj log -r 'bookmarks()' --no-graph \
  -T 'commit_id.short(8) ++ " " ++ local_bookmarks.map(|b| b.name()).join(",") ++ "\n"' \
  | grep -E '^[0-9a-f]+ (task|project)/'
```

Identify:
- **Open task branches** — have exclusive commits not yet in the project branch (need rebasing and migrating)
- **Closed/merged task branches** — all their commits are already in the project branch (no rebase needed; will be migrated as part of the project branch)
- **Project branches** — migrate last, after all child branches are done
- **Branches to skip** — test fixtures, orphan roots, `main`, etc.

To find which branches have exclusive commits not yet in the project:

```bash
for bm in $(jj log -r 'bookmarks()' --no-graph \
  -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' | grep '^task/'); do
  n=$(jj log -r "::${bm} ~ ::project/<name>" --no-graph -T 'commit_id ++ "\n"' \
    2>/dev/null | wc -l | tr -d ' ')
  echo "$n $bm"
done
```

### 2. Merge the feature branch into the project branch

```bash
# Create merge commit
jj new project/<name> task/<feature-branch> --no-edit
jj status  # must be conflict-free

# Describe and advance project bookmark
jj describe -m "Merge subtask: <title> (task/<feature-branch>)"
jj bookmark set project/<name> -r '@'
jj new '@'
```

### 3. Rebase open task branches

Only branches with exclusive commits need rebasing. Closed branches are already contained in the project history.

```bash
jj rebase -b task/<open-branch> -d project/<name>
```

After each rebase, check for conflicts:

```bash
jj log -r 'task/<branch>' --no-graph -T 'if(conflict, "CONFLICT\n")'
```

**If a rebase conflict occurs:**

The most common source of conflicts is the task file itself (`.tt/task/<slug>/TASK.md`) — both the task branch and the project branch may have edited it independently. Options:

- **Resolve manually:** Edit conflict markers in the file; keep the project branch's version of any shared fields (status, subtask list) and the task branch's version of task-specific content
- **Skip the rebase:** If the branch is simple enough (e.g. empty, or its only unique content is the task file itself), it may be easier to recreate it as a fresh branch from the new project tip using `tt task create`, then delete the old bookmark

**Conflicts arising from independent migration commits:** If both the task branch and the project branch have been individually migrated (two separate "Migrate task files to directory format" commits touching overlapping files), `jj propagate` will also conflict when run later. Resolve by checking out the conflict, taking the project branch's version of any shared task files, and discarding the task branch's migration commit.

### 4. Re-run the test suite

After rebasing, reset the test bookmark and re-run the test script to confirm the migration script still works:

```bash
jj bookmark set task/test-migration-<hex> \
  -r task/<feature-branch> --allow-backwards
bash scripts/test-migration.sh
```

All checks must pass before proceeding.

### 5. Migrate each branch

Migrate open task branches first (they have exclusive commits and need the new format to keep working), then the project branches last.

For each branch:

```bash
PRE=$(jj log -r '<bookmark>' --no-graph -T 'commit_id.short(8) ++ "\n"')

bash scripts/migrate-task-files.sh \
  --workspace /tmp/migrate-ws \
  --revision task/<feature-branch> \
  <bookmark>

POST=$(jj log -r '<bookmark>' --no-graph -T 'commit_id.short(8) ++ "\n"')
[[ "$PRE" != "$POST" ]] && echo "✓ advanced" || echo "✗ no change — check output"

# No old flat files remain
jj --ignore-working-copy file list -r '<bookmark>' \
  | grep -E '^\.tt/task/[^/]+\.md$' && echo "✗ flat files remain" || echo "✓ clean"
```

**Branch order:**
1. Open task branches (in any order)
2. Feature branch itself
3. Project branches (last — contain the full merged history)

**Project and unrelated branches:** Omit `--revision` for branches that do not descend from the feature branch (e.g. a second project in a separate lineage). The ancestry check would fail, but the migration script itself works correctly without it.

**Closed/merged task branches:** These can be skipped — their commits are already part of the project branch history and will be captured when the project branch is migrated.

### 6. Final sweep

Verify no flat task files remain on any active bookmark:

```bash
for bm in $(jj log -r 'bookmarks()' --no-graph \
  -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' \
  | grep -E '^(task|project)/'); do
  flat=$(jj --ignore-working-copy file list -r "$bm" 2>/dev/null \
    | grep -E '^\.tt/task/[^/]+\.md$' || true)
  [[ -n "$flat" ]] \
    && echo "✗ $bm: $(printf '%s\n' "$flat" | wc -l | tr -d ' ') flat files" \
    || echo "✓ $bm"
done
```

Remaining `✗` entries should be only test fixtures and historical closed task branches — not any active working branches.

### 7. Update CLI scripts and run propagate

After migrating all branches, run `tt task propagate` from the project branch to bring all open task branches up to date with the new project tip:

```bash
tt task propagate
```

If propagate produces conflicts, they likely stem from independent migration commits on both the task branch and the project branch (see step 3 above). Resolve by keeping the project branch's version of all shared task files.

After resolving, audit all CLI scripts for any remaining references to the old file format path patterns (e.g. `.tt/task/${suffix}.md` instead of `task_file_path "$suffix"`). Any path helper functions used across multiple commands should be centralised in `common.sh`.

---

## Rollback

At any point, a bookmark can be reset to its pre-migration state:

```bash
jj bookmark set <bookmark> -r <original-commit-id> --allow-backwards
```

The migration commit still exists in the repo until it is garbage-collected. To clean it up immediately:

```bash
jj abandon <migration-commit-id>
```

---

## Checklist

- [ ] New file format implemented and committed on feature branch
- [ ] Migration script written with `--repo`, `--workspace`, `--revision`, `--retain-workspace` flags
- [ ] Test script written; all checks pass against test fixture
- [ ] Pre-migration commit IDs recorded for all bookmarks
- [ ] Feature branch merged into project branch
- [ ] All open task branches rebased onto new project tip (no conflicts)
- [ ] Test suite re-run after rebases — all pass
- [ ] All open task branches migrated and verified
- [ ] Feature branch migrated and verified
- [ ] All project branches migrated and verified
- [ ] Final sweep: no flat files on any active bookmark
- [ ] `tt task propagate` run and any conflicts resolved
- [ ] All CLI scripts audited for old path patterns
- [ ] Migration script removed (no longer needed)
