---
title: "Investigation notes: worktree show fallback"
created: 2026-08-08T08:14:43Z
updated: 2026-08-08T08:14:43Z
---
# Investigation notes: `tt worktree show` fallback

These notes record how the `tt worktree show` fallback was discovered and why it is considered a design flaw. Captured while diagnosing an unrelated test failure.

## How this surfaced

A failing test — `scripts/cli/worktree/active.test.sh`, `test_worktree_active__after_checkout_returns_worktree` — asserted that `tt task checkout --worktree` moves the `HEAD` symlink to the new worktree. It does not: per **DESIGN.md:519**, `HEAD` is updated on checkout *except* when `--worktree` is used without `--switch`. The implementation at `scripts/cli/task/checkout:371` matched the design; the test predated the `--switch` flag.

The relevant detail is *why the test did not fail earlier or more clearly*. It guarded its assertion like this:

```bash
worktree_path=$(run_tt worktree show --task "$task_id" 2>/dev/null) || worktree_path=""

if [[ -n "$worktree_path" && "$worktree_path" != "$REPO" ]]; then
  # assert HEAD == worktree_path
else
  # assert HEAD == REPO
fi
```

The guard used `worktree show` as a proxy for "did checkout move HEAD?". `worktree show` answers a different question — "does a worktree exist for this branch?" — and because `--worktree` does create the worktree, the test always took the first branch and asserted the wrong thing. That test has since been fixed (split into two tests covering `--worktree` with and without `--switch`), but the underlying API smell remained.

## The flaw

`scripts/cli/worktree/show:85-89`:

```bash
worktree="$(find_worktrees_for_branch "$repo" "$task_id" "$task_prefix" "$project_prefix" | head -1)"
if [[ -z "$worktree" ]]; then
  worktree="$repo"
fi
```

Two distinct outcomes collapse into one indistinguishable result:

1. The task has a dedicated worktree that happens to be the repo root.
2. The task has **no** worktree at all.

Both print `$REPO` and exit `0`.

This is not an accident — **DESIGN.md:387** documents it ("Falls back to the repository root if no dedicated worktree exists") and it is convenient for the stated use case, shell command substitution, where an unconditionally usable `cd` target is wanted. But callers who need to know *whether a worktree exists* have no signal to branch on.

Case 1 is real, not hypothetical: `find_worktrees_for_branch` in `scripts/cli/lib/common.sh` iterates **all** jj workspaces via `jj workspace list`, including the default workspace at the repo root. A task checked out without `--worktree` genuinely matches the repo root.

## Blast radius

`worktree show` is used **only in tests** — never in the implementation:

```
scripts/cli/worktree/delete.test.sh     15 call sites
scripts/cli/workspace/repo.test.sh       1 call site
scripts/cli/worktree/show.test.sh        (tests the command itself)
```

The dangerous idiom, repeated throughout `delete.test.sh`:

```bash
run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true   # failure masked
worktree_path=$(run_tt worktree show --task "$task_id" 2>/dev/null) || true   # never fails anyway
```

Both lines swallow errors and the fallback guarantees a non-empty result, so if worktree creation regresses, `worktree_path` silently becomes `$REPO` and the test proceeds against the repo root. Only **1 of 15** sites guards with `assert_neq "worktree is not repo"`.

## Empirical proof of vacuous passes

`delete.test.sh` was copied and all 14 `task checkout --worktree --switch` lines replaced with a no-op, simulating a total regression in worktree creation. The sabotaged suite still produced **27 passing assertions**.

Every negative test's primary assertion passed for the wrong reason:

```
── test_worktree_delete__dirty_wc_rejected
  ✓ dirty WC rejected (exit code 1)
  ✗ mentions uncommitted: expected to contain 'uncommitted changes'
    Actual: Error: Not a task worktree
```

`assert_failure` succeeded because `worktree delete` refused the *canonical repo*, not because the working copy was dirty. Same in `non_done_status_rejected` and `commits_after_bookmark_rejected`. Those tests are only saved by their follow-up `assert_contains` on the error message; the exit-code assertion alone is worthless.

Two tests passed **entirely clean** under full sabotage:

- **`test_worktree_delete__bookmark_preserved`** — deletes `$REPO` (refused, masked by `|| true`), then asserts the bookmark still exists. It survives because nothing happened. This test would pass if `worktree delete` were replaced by `/bin/true`.
- **`test_worktree_delete__head_symlink_unchanged`** — asserts `HEAD` still points at `task_b` after deleting `task_a`'s worktree. Under sabotage `worktree_a` is `$REPO`, the delete is refused, and `HEAD` is trivially unchanged. The test never exercises the "delete a different worktree" path it is named for.

## Collateral risk

Several tests write into `$worktree_path` before deleting it:

```bash
echo "dirty" > "$worktree_path/dirty-file.txt"     # dirty_wc_rejected
(cd "$worktree_path" && checkpoint_task "Work")    # bookmark_preserved
run_tt_in_worktree "$worktree_path" task complete  # ~14 sites
```

When `worktree_path` degrades to `$REPO` these mutate the repo root of the test workspace. It is contained by the harness sandbox so nothing outside the temp directory is affected, but a regression then manifests as confusing cross-contamination rather than a clean failure.

`worktree delete` itself is safe: it hard-refuses the canonical repo even under `--force` (**DESIGN.md:389**). That backstop is what keeps this misleading rather than destructive.

## Note on the chosen fix

Two candidate semantics were considered:

1. Error only when `find_worktrees_for_branch` returns nothing, still printing the repo root when it is a genuine match.
2. Error whenever the result is the repo root, so `show` only ever reports dedicated worktrees.

**Option 2 was chosen.** The consequence, accepted deliberately: a task checked out in the main workspace without `--worktree` becomes unlookupable via `tt worktree show`. The rule is simpler and matches the command's purpose of locating dedicated worktrees.

One implementation caveat follows from this: the `"$worktree" == "$repo"` comparison must be done on normalized paths. On macOS the harness runs under `/var/...`, a symlink to `/private/var/...`, so an unnormalized comparison can silently fail to match.
