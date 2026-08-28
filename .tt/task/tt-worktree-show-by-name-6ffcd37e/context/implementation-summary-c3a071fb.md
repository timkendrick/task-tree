---
title: "Implementation summary"
created: 2026-08-28T11:26:05Z
updated: 2026-08-28T11:26:05Z
---
# Implementation summary: locate `tt worktree show` target by `--name`

Requirements: `context/requirements-cee1558e` · Architecture: `context/architecture-93395bd2`

## What changed

`tt worktree show --name <worktree-name>` looks the target up by jj workspace name, matched
exactly against the `NAME` column of `tt worktree list`. `--task` is gone; no task/project ID
format validation and no bookmark existence probe remain.

Three distinct failures, all single-line to stderr, exit 1:

| Condition | Message |
|---|---|
| No workspace with that name | `Error: No worktree named '<name>'` |
| Unrecorded path, or path is not a directory | `Error: Worktree '<name>' has an invalid path` |
| Name resolves to the canonical repo root | `Error: Worktree '<name>' is the repository root, not a dedicated worktree` |
| Canonical root unresolvable | `Error: Could not resolve the repository root for '<repo>'` |

## Files

| File | Change |
|---|---|
| `scripts/cli/lib/common.sh` | Added `jj_workspace_list`, `list_worktree_entries`, `resolve_workspace_path`, `resolve_canonical_repo_path`; rewrote `find_worktrees_for_branch`, `resolve_workspace_name`, `list_workspaces` on top of `list_worktree_entries` |
| `scripts/cli/worktree/show` | `--task` → `--name`; removed prefix/bookmark logic; new error set; uses `resolve_canonical_repo_path` |
| `scripts/cli/worktree/delete` | Uses `resolve_canonical_repo_path` |
| `scripts/cli/task/checkin` | Uses `resolve_canonical_repo_path` |
| `scripts/cli/worktree/show.test.sh` | Rewritten for `--name`; 9 scenarios |
| `DESIGN.md` | §5.5 bullet rewritten around the workspace name |
| `.agents/skills/tt/SKILL.md` | Signature corrected; stale "falls back to the repo root" claim removed |

## Verification

- `scripts/test --parallel` — **1259 passed, 0 failed, 0 skipped** (full suite, run twice:
  once after the initial implementation, once after the review refactors).
- `shellcheck -x` on all touched files: no new findings (only pre-existing SC1091/SC2155/
  SC2295/SC2034).
- Manual smoke test against this live repository: dedicated worktree by name, `default`,
  unknown name, and lookup from inside another worktree all behave as specified.
- No `FIXME` remains in `scripts/cli/`.

## Deviations from the plan

All deviations arose from the code review and were approved before implementation.

### 1. `list_worktree_entries` extracted; all four consumers routed through it

The architecture proposed `resolve_workspace_path` as a standalone mirror of
`resolve_workspace_name`. Review flagged the two as near-identical loops. Rather than a
stringly-typed field-selector helper, parsing was lifted into `list_worktree_entries REPO`,
emitting tab-separated `name<TAB>path` records — matching the tab convention already used by
`list_workspaces` and `get_task_range_context`.

`find_worktrees_for_branch`, `resolve_workspace_name`, `resolve_workspace_path` and
`list_workspaces` all now consume it, so the raw `name: path` format is parsed in exactly one
place. `jj_workspace_list` and `parse_workspace_list_line` have `list_worktree_entries` as
their only caller.

Name: `list_worktree_entries`, not `list_workspace_entries` as first drafted.

### 2. `resolve_canonical_repo_path` extracted, three call sites updated

Review found the canonical-root-plus-symlink-resolution block duplicated in
`worktree/show`, `worktree/delete` and `task/checkin`. Folded into one helper.

Failure propagates (returns 1) rather than falling back to `$repo`, per explicit decision.
Consequences:

- `worktree/show` previously fell back to `$repo`. It now reports
  `Error: Could not resolve the repository root for '<repo>'` and exits 1, per direct
  instruction during implementation.
- `worktree/delete` and `task/checkin` previously fell back to the unresolved path when
  `resolve_path_symlinks` failed; they now abort under `set -e`. Both already aborted when
  `resolve_canonical_repo` itself failed, so this only tightens the second half.
- `task/checkin` previously canonicalized the repo root with `realpath`; it now uses
  `resolve_path_symlinks` (`cd && pwd -P`) via the helper. Equivalent at that point, where the
  repo root is guaranteed to exist. The `realpath` call on `child_worktree` is untouched, and
  the now-redundant `repo_root` local was removed.

### 3. `find_worktrees_for_branch` gained an explicit `return 0`

Its match branch was condensed from `if [[ ... ]]; then printf; fi` to
`[[ ... ]] && printf`. A `while` loop returns the status of the last command in its body, so
a final non-matching iteration would have made the function return 1 — the `if` form always
returned 0. The explicit `return 0` preserves the original contract.

### 4. Stale comments removed

- `find_worktrees_for_branch`'s "Uses jj template `name ++ ": " ++ root ++ "\n"`" line, now
  false since it delegates.
- The inline template-format comment inside the same function, superseded by
  `jj_workspace_list`'s doc comment.

### 5. Header comment in `scripts/cli/worktree/show`

Trimmed by the user during implementation (strict-contract sentence dropped, `--name`
description shortened). Confirmed intentional; left as found. The `usage()` text retains the
full description.

## Reviewed and rejected

- **Field-selector lookup helper** (`find_workspace_entry REPO FIELD VALUE`) — rejected in
  favor of `list_worktree_entries`, which avoids stringly-typed field selection.
- **`ws_name="$task_id"` alias in tests** — rejected. `$task_id` is the honest name for what
  `create_task` returns, and `test_worktree_show__name_independent_of_checked_out_task`
  documents that the workspace name is fixed at creation.
- **Unit tests for `resolve_workspace_path` in `common.test.sh`** — rejected. The 9
  integration scenarios cover every branch, and the sibling workspace helpers have no unit
  tests either.
- **Changes to `tt worktree list --task`** — out of scope by decision.
- **Adding canonicalization to `workspace/repo`, `worktree/delete:164`, `task/checkin:377`** —
  those call `resolve_canonical_repo` without symlink resolution, so they are not instances of
  the extracted pattern and were left alone.
