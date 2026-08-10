---
title: "Fail `tt worktree show` when no dedicated worktree exists"
status: DONE
created: 2026-08-08T08:13:30Z
updated: 2026-08-08T08:14:43Z
context: context/investigation-notes-b139f7e0
---
`tt worktree show --task <id>` currently falls back to printing the repository root and exiting `0` when no dedicated worktree exists for the task. This silently returns an unrelated tree instead of reporting failure, which is a design flaw: callers cannot distinguish "here is the task's worktree" from "there is no worktree, have the repo root instead".

Make `tt worktree show` exit `1` when no dedicated worktree is found, amend `DESIGN.md` to document the new contract, and harden the test suites that were relying on the fallback.

## Background

See the attached context file "Investigation notes: worktree show fallback" for the full investigation, including empirical proof that the fallback causes tests to pass vacuously.

Summary of the flaw, at `scripts/cli/worktree/show:85-89`:

```bash
worktree="$(find_worktrees_for_branch "$repo" "$task_id" "$task_prefix" "$project_prefix" | head -1)"
if [[ -z "$worktree" ]]; then
  worktree="$repo"
fi
```

Because `find_worktrees_for_branch` (in `scripts/cli/lib/common.sh`) enumerates *all* jj workspaces including the default one at the repo root, the repo root can be returned either as a genuine match (task checked out without `--worktree`) or as the fallback. Both print `$REPO` and exit `0`, so they are indistinguishable to a caller.

## Decision

Adopt **strict** semantics: `tt worktree show` reports only *dedicated* worktrees.

The repo root is never a valid result, whether it arrived via the fallback or as a genuine `find_worktrees_for_branch` match. A task checked out in the main workspace (without `--worktree`) therefore becomes unlookupable via `show` — this is accepted and intentional, since the command's purpose is to locate dedicated worktrees.

There is **no** opt-in flag to restore the old fallback. This is a hard behavior change; backwards compatibility is not maintained.

## Scope

### 1. Implementation — `scripts/cli/worktree/show`

Replace the fallback with an error:

```bash
worktree="$(find_worktrees_for_branch "$repo" "$task_id" "$task_prefix" "$project_prefix" | head -1)"
if [[ -z "$worktree" || "$worktree" == "$repo" ]]; then
  log "Error: No dedicated worktree for '$task_id'"
  log "  Run 'tt task checkout $task_id --worktree' to create one."
  exit 1
fi

printf '%s\n' "$worktree"
```

Notes:
- Compare normalized paths. `$repo` comes from `resolve_repo`, `$worktree` from `jj workspace list -T root`; confirm both are canonical (`realpath`) before comparing, or normalize explicitly, so a symlinked repo path does not defeat the `== "$repo"` check. The harness runs under `/var/...` which is a symlink to `/private/var/...` on macOS, so this matters.
- Keep the existing "task or project not found in repository" error (bookmark does not exist) distinct from the new "no dedicated worktree" error (bookmark exists, no workspace). They are different failures and should have different messages.
- Update the command's header comment and `usage()` text, both of which currently state "Falls back to the repository root if no dedicated worktree exists".

### 2. Documentation — `DESIGN.md`

Amend the `tt worktree show` bullet at **DESIGN.md:387**. Current text:

> **`tt worktree show --task <task-id> [--repo PATH]`** — Output the worktree path for the given task or project ID to stdout. Accepts a full task or project ID via the required `--task` flag. Falls back to the repository root if no dedicated worktree exists for the task. Exits with an error if the task ID is not found in the repository. Intended for use in shell command substitution.

Replace the fallback sentence with the new contract: outputs only dedicated worktree paths; exits with an error if the task has no dedicated worktree (including when the task is checked out in the main workspace); exits with a distinct error if the task ID is not found in the repository.

Check for any other references to the fallback elsewhere in `DESIGN.md` and update them for consistency.

### 3. Test harness — `scripts/harness/harness.sh`

Add a helper that creates a dedicated worktree for a task and asserts it was genuinely created, so a regression in worktree creation fails loudly at the point of setup rather than silently corrupting the rest of the test:

```bash
create_task_worktree() {
  local task_id="$1"; shift
  local path
  path=$(run_tt task checkout "$task_id" --worktree "$@" 2>/dev/null) || path=""
  assert_neq "worktree created for $task_id" "$path" "$REPO"
  assert_output_not_empty "worktree path for $task_id" "$path"
  printf '%s\n' "$path"
}
```

Requirements:
- Accept pass-through checkout arguments (`"$@"`) so callers can add `--switch`. `delete.test.sh` needs `--switch`; `workspace/repo.test.sh` deliberately does not.
- `tt task checkout` already prints the worktree path to stdout with all other output on stderr (DESIGN.md:325), so the path can be captured directly — there is no need to call `worktree show` at all in setup code.
- Place it near the other task helpers (`create_task`, `checkout_task`, around `harness.sh:149-190`).

### 4. Test updates

**`scripts/cli/worktree/show.test.sh`** — `test_worktree_show__no_dedicated_worktree_falls_back_to_repo` (line 7) asserts the old fallback and will fail. Rewrite it as a "no dedicated worktree errors" test: assert non-zero exit and an error message mentioning the task ID. Rename accordingly. Add a positive test that a task *with* a dedicated worktree returns that path and exits 0.

**`scripts/cli/worktree/delete.test.sh`** — 15 call sites use the `worktree show` fallback to derive a path for deletion, and only 1 guards the result against `$REPO`. Replace the two-line

```bash
run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
worktree_path=$(run_tt worktree show --task "$task_id" 2>/dev/null) || true
```

idiom with `worktree_path=$(create_task_worktree "$task_id" --switch)`. This both removes the dependency on `show`'s return value and stops masking checkout failures with `|| true`. Note `test_worktree_delete__head_symlink_unchanged` uses two tasks (`worktree_a`, and `task_b` whose path is not captured).

**`scripts/cli/workspace/repo.test.sh`** — `test_workspace_repo__from_worktree_resolves_canonical` (line 23) has the same defensive `if [[ -n "$worktree_path" && "$worktree_path" != "$REPO" ]]` guard that hid the bug in `worktree/active.test.sh`. Under strict semantics `show` exits 1, `worktree_path` becomes empty, and the test takes the else branch — passing without ever exercising the worktree case. Replace with `create_task_worktree` and a straight-line assertion; delete the else branch.

Search the whole suite for other `worktree show` consumers before finishing:

```shell
grep -rn "worktree show" scripts/
```

### 5. Verification

Run the affected suites (see `DEVELOPER.md`):

```shell
scripts/test worktree/show worktree/delete worktree/active workspace/repo
```

Then run the full suite, ideally on a RAM disk:

```shell
RAMDISK=$(scripts/ramdisk create) && TT_TEST_ROOT=$RAMDISK scripts/test --parallel; scripts/ramdisk destroy $RAMDISK
```

**Sabotage check.** The point of this task is that setup failures must fail loudly. After the change, verify the hardening actually works: temporarily neuter worktree creation in a *copy* of `delete.test.sh` (replace the checkout lines with a no-op) and confirm the suite now fails at setup instead of passing vacuously. Before this change, 27 assertions still passed under that sabotage and two tests (`test_worktree_delete__bookmark_preserved`, `test_worktree_delete__head_symlink_unchanged`) passed completely clean. Delete the copy afterwards.

## Acceptance criteria

- `tt worktree show --task <id>` exits 1 with a clear error when the task has no dedicated worktree, including when the task is checked out in the main workspace.
- The "bookmark not found" error remains distinct from the "no dedicated worktree" error.
- Path comparison is robust against symlinked repo roots.
- `DESIGN.md:387` documents the new contract; no stale references to the repo-root fallback remain.
- `create_task_worktree` exists in the harness and is used by `delete.test.sh` (15 sites) and `workspace/repo.test.sh`.
- No test derives a worktree path via `tt worktree show` in setup code.
- `test_worktree_delete__bookmark_preserved` and `test_worktree_delete__head_symlink_unchanged` fail when worktree creation is sabotaged.
- Full test suite passes.
