---
title: "Implementation plan: Standardize VCS operations"
created: 2026-08-28T22:51:50Z
updated: 2026-08-28T22:51:50Z
---
# Implementation plan: Standardize VCS operations

**Task:** `task/standardize-vcs-operations-d5419005`
**Branch:** `task/standardize-vcs-operations-d5419005` (child of `project/bootstrap-cli-d35756ce`)

## Executive summary

The `tt` bootstrap CLI is a collection of ~36 bash scripts under `scripts/cli/` that implement a
task-tree tool on top of the `jj` version-control system. Today every VCS operation is an inline `jj`
invocation written directly into command logic, spread across roughly 30 files and one 2,025-line
shared library (`scripts/cli/lib/common.sh`).

This task restructures that code into four strictly-layered tiers — commands, semantic facades, a
backend-neutral VCS interface, and a single jj backend module — and, in the process, replaces the
mechanism by which the tool writes files into commits.

Today, writing a file into a commit requires a working copy. Every mutating command therefore borrows
one: it runs `jj edit <bookmark>`, writes files onto disk, runs `jj commit`, moves the bookmark, and
then tries to put the working copy back where it found it. That pattern exists in one library helper
and eight hand-rolled duplicates. It collides with the user's uncommitted work, can absorb unrelated
files into tt's own commits, and can silently leave the user parked on a foreign branch when the
restore step fails.

After this task, all file-content mutation is **bare**: commits are built directly in the Git object
store that backs the jj repository, with no working copy involved at any point. The working copy is
touched only where that is the actual point of the command (`task checkpoint`, `task checkout`,
`workspace init`) or where the user has explicitly asked for it (`worktree sync`, a new command).

The task also delivers `ARCHITECTURE.md`, per-module test suites, and updates to `DESIGN.md` and
`DEVELOPER.md`.

---

## 1. Background

### 1.1 What `tt` is

`tt` models a project as a tree of tasks. Each task is a jj bookmark (branch) named
`task/<slug>-<8-hex>` or `project/<slug>-<8-hex>`, and each task owns a directory
`.tt/task/<slug>-<8-hex>/` containing a `TASK.md` file with YAML frontmatter plus any number of
context files. Parent/child relationships are recorded as `subtask:` frontmatter entries in the
parent's `TASK.md`. A repo-root `TASK.md` symlink points at the currently-checked-out task's file.

Commands are individual executables under `scripts/cli/<namespace>/<verb>`, dispatched by
`scripts/cli/tt`. Every one of them sources `scripts/cli/lib/common.sh`.

### 1.2 Why this task exists

Three concrete problems, in the words of the requirements document:

1. **No storage seam.** A second backend (Git) cannot be introduced without rewriting every command.
2. **Working-copy hijacking.** Because there is no way to write files into a commit without a working
   copy, every mutating command borrows one. This collides with the user's uncommitted work, can
   commit unrelated files, and can silently leave the user parked on a foreign branch when the
   restore step fails.
3. **Duplication.** The same five-step working-copy dance exists in one library copy and eight
   hand-rolled variants, each subtly different.

### 1.3 Prior work in this task

Two RAPID steps have already completed and their outputs are stored as task context:

- `.agents/plans/standardize-vcs-operations.requirements.md` — the agreed requirements.
- `.agents/plans/standardize-vcs-operations.architecture.md` — the agreed architecture, including
  verified mechanisms for bare writes, worktree handling, and the task-rename algorithm.

A `jj` command audit was also carried out (task context `context/jj-command-audit-c79dfc51`). Its
central finding: `write_and_commit_on_branch` is the *only* mutating function in `common.sh`; every
other jj-touching helper there is read-only. The eight hand-rolled duplicates live in the command
scripts themselves.

**These two documents are normative for this plan.** Where this plan and those documents disagree,
the disagreement is called out explicitly in §3 (Decision log); everything else follows them.

---

## 2. Research

### 2.1 Repository state

Working directory: `/Users/tkendrick/Sites/task-tree/task/standardize-vcs-operations-d5419005`
(a dedicated jj workspace for this task).

At the start of this planning session the task branch was 22 commits behind its parent, and
`common.sh` on the task branch was 1,692 lines while the audit had been performed against the
2,025-line version on the parent. The branch has since been brought up to date:

```
tt task propagate --from project/bootstrap-cli-d35756ce \
                  --to   task/standardize-vcs-operations-d5419005 --shallow
```

This rebased the task's 8 context commits onto `project/bootstrap-cli-d35756ce` with no conflicts.
`common.sh` is now 2,025 lines and matches the audit. **All line numbers in this plan refer to that
post-propagate state.**

### 2.2 Toolchain versions (verified on this machine)

| Tool | Version | Consequence |
| --- | --- | --- |
| `jj` | 0.43.0 | All primitives the architecture relies on exist: `restore --from/--into`, `new --no-edit/-A/-B`, `rebase -s/-d`, `squash --from/--into`, `--ignore-working-copy`, `--at-operation`. |
| `git` | 2.55.0 | Plumbing available: `hash-object`, `read-tree`, `update-index --cacheinfo`, `write-tree`, `commit-tree`, `update-ref`. |
| `bash` | **3.2.57** (macOS system bash) | **No `mapfile`/`readarray`, no `declare -A`.** The existing code uses neither; the new modules must not either. |

`jj config get user.name` / `user.email` resolve successfully and are the identity that
`_jj_commit_changeset` must stamp onto commits it builds with `git commit-tree` (the ambient Git
identity may differ).

The repository's backing store type is read from `.jj/repo/store/type`; the Git directory pointer is
`.jj/repo/store/git_target`, **resolved relative to `.jj/repo/store/`** (not `.jj/repo/`). In a
secondary jj workspace, `.jj/repo` is a *file* containing a relative path to the canonical repo's
`.jj/repo` directory.

### 2.3 Source inventory

```
scripts/cli/tt                       dispatcher
scripts/cli/lib/common.sh            2,025 lines, 95 functions — the whole library today
scripts/cli/lib/common.test.sh         701 lines — unit tests for the pure helpers
scripts/cli/task/*                   23 commands (+ context/{add,delete,get,list})
scripts/cli/workspace/*              init, repo, root
scripts/cli/worktree/*               active, delete, list, show, switch
scripts/cli/history/*                undo, unlock
scripts/harness/harness.sh           1,555 lines — the test harness
scripts/test                         test runner
scripts/ramdisk                      macOS RAM disk helper for fast test runs
DESIGN.md                            1,253 lines — user-facing design document
DEVELOPER.md                         developer guide (test running, RAM disk)
```

Total: ~15,500 lines across `scripts/`.

### 2.4 The 95 functions in `common.sh`

Listed here in file order with their line numbers, because Step 1 of the implementation is to
partition exactly this set across the new modules. `jj`-invoking functions are marked **[VCS]**.

| Line | Function | Line | Function |
| --- | --- | --- | --- |
| 12 | `jj_show_at_revision` **[VCS]** | 1004 | `_full_range_symlink_diff` **[VCS]** |
| 25 | `get_jj_op_id` **[VCS]** | 1012 | `_full_range_parse_symlink_removed` |
| 34 | `jj_show_at_op` **[VCS]** | 1018 | `_full_range_parse_symlink_added` |
| 61 | `format_commit_message` | 1024 | `_full_range_span_empty` |
| 89 | `parse_commit_message` | 1033 | `_full_range_covered_by` |
| 122 | `title_to_slug` | 1055 | `mainline_commit_records` **[VCS]** |
| 129 | `validate_slug` | 1069 | `find_parent_project` |
| 159 | `generate_hex` | 1092 | `find_branch_for_task` **[VCS]** |
| 171 | `generate_timestamp` | 1132 | `get_worktree_current_rev` **[VCS]** |
| 191 | `tt_metadata_path` | 1139 | `resolve_current_worktree` **[VCS]** |
| 202 | `task_root_path` | 1154 | `resolve_task_worktree` |
| 210 | `metadata_exclusion_fileset` | 1185 | `jj_workspace_list` **[VCS]** |
| 217 | `task_file_path` | 1215 | `write_and_commit_on_branch` **[VCS]** |
| 224 | `task_dir_path` | 1242 | `parse_workspace_list_line` |
| 232 | `task_context_path` | 1257 | `list_worktree_entries` |
| 244 | `parse_body` | 1274 | `find_worktrees_for_branch` |
| 249 | `log` | 1298 | `resolve_current` **[VCS]** |
| 256 | `resolve_path_symlinks` | 1331 | `resolve_current_rev` |
| 263 | `find_repo_root` | 1342 | `resolve_current_task_file` |
| 286 | `resolve_repo` | 1353 | `resolve_current_bookmark` |
| 314 | `get_task_prefix` | 1362 | `resolve_workspace_name` |
| 326 | `get_project_prefix` | 1379 | `resolve_workspace_path` |
| 338 | `is_task_branch` | 1396 | `list_workspaces` |
| 348 | `set_workspace_dir` | 1416 | `forget_worktree` **[VCS]** |
| 357 | `init_tt_history` | 1427 | `check_bookmark_up_to_date` **[VCS]** |
| 367 | `get_workspace_dir` | 1440 | `get_active_worktree` |
| 389 | `is_project_branch` | 1457 | `status_to_checkbox` |
| 397 | `count_revs_in_revset` **[VCS]** | 1481 | `collect_descendant_task_dirs` |
| 404 | `get_commit_description` **[VCS]** | 1556 | `parse_task_frontmatter` |
| 411 | `is_wc_clean` **[VCS]** | 1609 | `write_task_file` |
| 425 | `assert_bookmark_up_to_date` | 1647 | `write_context_file` |
| 439 | `run_hook` | 1663 | `write_task_stub` |
| 461 | `make_absolute_symlink` | 1686 | `_insert_frontmatter_line` |
| 476 | `update_head_symlink` | 1711 | `append_frontmatter_context` |
| 487 | `perform_workspace_switch` | 1719 | `append_frontmatter_subtask` |
| 517 | `parse_frontmatter_fields` | 1727 | `update_frontmatter_timestamp` |
| 539 | `parse_frontmatter_field` | 1769 | `resolve_canonical_repo` |
| 550 | `parse_quoted_frontmatter_field` | 1793 | `resolve_canonical_repo_path` |
| 563 | `parse_repeated_frontmatter_field` | 1805 | `resolve_history_file_location` |
| 575 | `prompt_raw` | 1822 | `tt_begin_transaction` **[VCS]** |
| 602 | `prompt` | 1872 | `tt_commit_transaction` **[VCS]** |
| 614 | `has_conflicts` **[VCS]** | 1914 | `tt_rollback_transaction` **[VCS]** |
| 628 | `find_parent_branch` **[VCS]** | 1963 | `_select_value` |
| 677 | `get_task_range_context` **[VCS]** | 1994 | `select_value` |
| 727 | `resolve_task_range` **[VCS]** | | |
| 743 | `resolve_task_fork_point` **[VCS]** | | |
| 791 | `get_full_task_range_records` **[VCS]** | | |
| 944 | `_full_range_resolve_commit` **[VCS]** | | |
| 958 | `_full_range_bookmark_task_file` | | |
| 971 | `_full_range_creation_boundary` **[VCS]** | | |
| 991 | `_full_range_query_waypoints` **[VCS]** | | |

25 of the 95 invoke `jj`. Of those 25, exactly one — `write_and_commit_on_branch` (line 1215) —
mutates anything.

### 2.5 The working-copy dance

`write_and_commit_on_branch` (`common.sh:1215–1240`) is the library copy:

```bash
if [[ "$target_worktree" == "$current_worktree" && "$current_bookmark" != "$bookmark" ]]; then
    original_parent_rev="$(jj -R "$repo" log -r '@-' --no-graph -T 'commit_id' 2>/dev/null)"
    jj -R "$repo" edit "$bookmark"
    jj -R "$repo" new
    "$writer_fn" "$repo" "$@"
    jj -R "$repo" commit -m "$message"
    jj -R "$repo" bookmark set "$bookmark" -r '@-'
    jj -R "$repo" new -r "$original_parent_rev"
else
    "$writer_fn" "$target_worktree" "$@"
    jj -R "$target_worktree" commit -m "$message"
    jj -R "$target_worktree" bookmark set "$bookmark" -r '@-'
fi
```

It is used by `task/edit`, `task/context/add` and `task/context/delete`. The other eight commands
(`task/create`, `task/checkin`, `task/publish`, `task/complete`, `task/delete`, `task/reorder`,
`task/rename`, `task/checkpoint`) each hand-roll their own variant.

Two secondary hazards the audit found:

- **`jj bookmark set` without `-r`** in `task/move`, `task/propagate` and `task/checkout`. The target
  is implicitly `@`, so correctness depends on the working copy sitting exactly where the previous
  step left it.
- **Best-effort restore** of the form `jj edit "$original_rev" 2>/dev/null || true` in
  `task/propagate` and `task/create`. Failure is swallowed, leaving the user on a foreign branch.

### 2.6 Per-command survey of mutating commands

Compiled by direct reading of all 17 mutating scripts. `@` positions are as observed today.

| Command | Requires clean WC today | `@` after (same branch) | `@` after (explicit task-id) | Write mechanism today |
| --- | --- | --- | --- | --- |
| `task create` | no | new empty child of new task branch, or restored | restored to original rev (best-effort) | `jj new`/`describe`/`bookmark set` ×3 + disk writes for parent `subtask:` entry |
| `task edit` | **yes** | new empty child of task branch | unchanged | `write_and_commit_on_branch` |
| `task context add` | **yes** | new empty child of task branch | unchanged | `write_and_commit_on_branch` (writes 2 files) |
| `task context delete` | **yes** | new empty child of task branch | unchanged | `write_and_commit_on_branch` (writes 1, `rm`s 1) |
| `task complete` | **yes** | restored via `jj new -r <orig>` | restored | `jj new <bm>` → `awk` in-place → `commit` → `bookmark set -r '@-'` |
| `task reorder` | **yes** | new commit on parent/canonical branch | same | `jj new <bm>` → `write_task_file` → `commit` → `bookmark set -r '@-'` |
| `task delete` | **yes** (unless `--force`) | new empty child of parent branch | same | `jj new <parent>` → write + `rm -rf` dirs → `commit` → `bookmark set` → `new '@'` |
| `task checkin` | **yes** | **moves onto the new merge commit on the parent branch** | on parent tip in target worktree | handoff via `jj new <child>` + disk writes + `commit`; merge via `jj new <parent> <handoff>` + `describe` + `bookmark set -r '@'` + `new '@'` |
| `task publish` | **yes** | back on the project branch | in target worktree | same shape as checkin; handoff deletes `TASK.md` + `.tt/task/` via `rm` |
| `task move` | **yes** | depends on which of 3 cases | restored via saved change ID | two `jj new`+disk-write+`commit` cycles, then `jj rebase -s roots(...) -d <new parent>` |
| `task rename` | **yes** | clean child of renamed task tip | same | pre-saves file content at a captured operation ID via `jj_show_at_op`, then `jj edit` each commit in the unmerged range and rewrites paths on disk |
| `task propagate` | no | restored to `original_rev` via `jj edit` | same | `jj rebase -s roots(...) -d <parent>`, or `jj new <child> <parent>` merge; `jj edit` restores |
| `task checkpoint` | n/a (needs dirt) | clean child of new checkpoint commit | n/a | `jj commit` / `jj squash --from <intermediates> --into @` |
| `task checkout` | **yes** (unless `--force`) | clean child of checkout commit | same | `jj workspace add` or `jj new <task>`, symlink + status write on disk, `describe`, `bookmark set`, `new '@'` |
| `workspace init` | **yes** | clean child of init commit | n/a | disk writes then `jj commit` |
| `worktree delete` | **yes** (unless `--force`) | unchanged | unchanged | `jj workspace forget` + `rm -rf` |
| `history undo` | **yes** (unless `--force`) | unchanged | unchanged | `jj op restore <before-op>` |

Notes carried forward into the plan:

- `task complete` fires `pre-complete` (blocking) and `post-complete` (non-blocking, receives
  `TT_COMMIT`). `task delete` fires `pre-delete`/`post-delete`. `task checkin` fires
  `pre-checkin`/`post-receive`. `task checkpoint` fires `pre-checkpoint`/`post-checkpoint`.
  `task checkout` fires `pre-checkout`/`post-checkout` and, for new worktrees, `setup`.
- `workspace init` and `history undo` do **not** open a tt transaction; every other mutating command
  does.
- `task rename`'s current pre-save step exists solely because its in-place `jj edit` loop destroys
  the content it later needs to read. The architecture's Phase 0/Phase 1 algorithm removes the need
  for it entirely.

### 2.7 Test infrastructure

`scripts/test` discovers suites with `find scripts/cli -name '*.test.sh' -type f`. **Any new
`*.test.sh` file anywhere under `scripts/cli/` — including `scripts/cli/lib/` and
`scripts/cli/lib/vcs/` — is picked up automatically.** No runner change is required.

Suite convention (see `scripts/cli/lib/common.test.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

test_<function>__<scenario>() { ... }

run_tests "<suite title>"
```

The harness provides `setup_workspace`, `run_tt`, `run_tt_in_worktree`, and a large assertion
vocabulary (`assert_eq`, `assert_contains`, `assert_matches`, `assert_bookmark_exists`,
`assert_file_on_branch`, `assert_task_status`, `assert_subtask_entry`, `assert_wc_clean`,
`assert_history_integrity`, `assert_tt_workspace_integrity`, …). Tests are discovered by
`declare -F | grep '^test_'`, filtered by `--filter`, and run one per subprocess in the parallel pool.

Running tests:

```bash
scripts/test                                    # all suites, serial (slow)
scripts/test --parallel                         # worker pool, TT_TEST_CONCURRENCY (default 4)
scripts/test lib/vcs                            # suite filter: path substring
scripts/test --filter symlink                   # test filter: ERE against "SUITE: fn_name"
RAMDISK=$(scripts/ramdisk create) && TT_TEST_ROOT=$RAMDISK scripts/test --parallel; \
  scripts/ramdisk destroy $RAMDISK              # recommended for full runs
```

### 2.8 Documentation touchpoints

- `DESIGN.md` §5.5 lists the `worktree` commands — `worktree sync` is added there.
- `DESIGN.md` §6.6 lists `task checkin` validation, including "Working copy is clean".
- `DESIGN.md` §6.9 (`task delete`) and the other §6.x command sections state preconditions that
  change.
- `DEVELOPER.md` covers test running and the RAM disk; the library module layout, the per-module
  suites and `TT_VERBOSE` are added.
- `ARCHITECTURE.md` does not yet exist and is created at the repository root.

---

## 3. Decision log

Decisions already fixed by the requirements and architecture documents, plus decisions taken during
this planning session. Numbered for reference from the implementation steps.

### Fixed by the requirements/architecture documents

| # | Decision |
| --- | --- |
| D1 | Four layers: commands → facades (`task`, `workspace`, `worktree`, `history`) → `lib/vcs.sh` → `lib/vcs/jj.sh`. Utilities (`ui`, `string`, `format`, `path`, `frontmatter`, `commit`, `hook`) sit beside the facades and perform no VCS access. |
| D2 | `lib/common.sh` becomes an aggregator containing nothing but `source` directives, in dependency order. It remains the single entry point that commands source. |
| D3 | Naming: every library function is `_<namespace>_<verb>[_<noun>]`. Names describe intent, never mechanism. |
| D4 | `lib/vcs.sh` declares one static wrapper per operation (`_vcs_x() { _jj_x "$@"; }`). No dynamic dispatch, no `eval`, no backend-selection env var. |
| D5 | Every `_jj_*` function takes the repository root as its first argument, honours `TT_VERBOSE`, never logs, never exits, and reports failure by exit status. |
| D6 | No `jj` revset or template string may appear outside `lib/vcs/jj.sh`. Multi-field query results are line-oriented TSV in a documented column order. |
| D7 | Bare writes require the Git backing store. Anything else fails with exactly `Unsupported repository backend: <type>`. No fallback. |
| D8 | A changeset is expressed as a sparse **staging directory** plus an explicit **deletion list** of exact file paths. No recursive deletion; a caller removing a directory enumerates it first. Granularity is one bare commit per logical tt commit. |
| D9 | A worktree's working-copy commit may only be rewritten by an operation running inside that worktree. Other worktrees are left **behind**, never rewritten, and are reported as out of sync. |
| D10 | Every mutating command refuses to start while `@` carries a bookmark, whatever the working-copy state, naming the bookmark and the remedy. No exemptions — including `task checkpoint`. |
| D11 | No global clean-working-copy requirement. Cleanliness is required only where it protects real semantics: `task rename`, `task move`, `task checkin`. |
| D12 | Merge commits never carry file writes. `checkin` and `publish` build a linear handoff commit, then create an empty merge commit. |
| D13 | `task rename` uses the two-phase algorithm of architecture §9: compute every target tree from the *original* objects first, then rewrite in place oldest-first via `_vcs_restore_tree`, addressing commits by change ID. It refuses when a foreign worktree's `@` lies in the rewrite set. |
| D14 | Only three commands are working-copy-bound: `task checkpoint`, `task checkout`, `workspace init`. `worktree sync` runs inside a worktree as the sanctioned mechanism of D9, not as an exception. |
| D15 | New command `tt worktree sync [<worktree-path>] [--all]`, run inside the target worktree, is the sole mechanism for bringing a behind worktree forward. |
| D16 | `TT_VERBOSE=1` echoes each backend command line to stderr and forwards the invocation's own stderr. It never changes stdout or exit status. |
| D17 | One test suite per module, co-located. `lib/common.test.sh` cases are relocated into the suite that owns the function, and `common.test.sh` is deleted once empty. |
| D18 | Delivery is a single task branch with incremental checkpoint commits — one per module extracted or command group migrated. No sub-task tree. |
| D19 | bash 3.2 only: no `mapfile`/`readarray`, no `declare -A`. Keyed lookups use parallel arrays or files in a scratch directory. |

### Taken during this planning session

| # | Decision | Rationale |
| --- | --- | --- |
| D20 | The task branch was brought up to date with `project/bootstrap-cli-d35756ce` before any implementation work. | The branch was 22 commits behind, and those 22 commits modify `common.sh`, `task/changelog`, `task/diff`, `task/revset`, `worktree/show` and `worktree/delete` — precisely the files this refactor rewrites. Refactoring stale code and merging later would produce a large, avoidable conflict. Done; no conflicts. |

| D21 | Migration is sequenced **split first, then vertical slice**: Phase A mechanically splits `common.sh` with the full suite green throughout; Phase B builds the backend and bare-write mechanism against its own suite; Phase C migrates commands group by group. | Each phase is independently verifiable. A vertical-slice-first order would leave two library structures coexisting for most of the task, with live name-collision and duplication hazards. |
| D22 | **Universal `@` rule.** No mutating command moves the working copy. The only commands that move `@` are `task checkpoint`, `task checkout`, `workspace init`, `worktree sync` and `worktree switch`. `task checkin` and `task publish` stop landing `@` on the new merge commit; `create`, `complete`, `delete`, `reorder`, `move` and `propagate` stop restoring `@` because they never move it. | A single rule is auditable; per-command decisions are not knowable in advance and cannot be stated in a plan. Reattaching `@` onto a new tip it already descended from is not a move: the working copy stays on the same branch. |
| D23 | `task rename` **refuses** when any foreign worktree's working-copy commit lies in the rewrite set. The error names each blocking worktree and its task and offers `tt worktree sync <path>` or `tt worktree delete <path>`. **`--force` does not override it.** | Overriding genuinely destroys uncommitted work in another worktree rather than merely being risky, so no flag should offer it. |
| D24 | Repository discovery moves into the backend: `_vcs_find_repository_root`, `_vcs_check_is_repository`, `_vcs_resolve_repository_root`, `_vcs_get_backend_type`. `lib/workspace.sh` exposes `_workspace_resolve_repo` for the `--repo` / `$TT_REPO` / walk-up priority logic. `lib/path.sh` keeps only pure path arithmetic. | `.jj` detection and `.jj/repo` pointer-following are backend-specific knowledge, and utilities may perform no VCS access. Leaving them in a utility would break acceptance criterion 1 and would need rewriting for a Git backend. |
| D25 | Each Phase A commit **moves, renames and updates every call site** for exactly one module. No back-compatibility aliases or shims at any point. | The tree stays coherent after every commit, and `grep` for an old name returning nothing is a mechanical completeness check. Aliases would leave two names per function live for most of the task. |
| D26 | Test cases **relocate with their module**, in the same commit that extracts it. `common.test.sh` shrinks step by step and is deleted in A5 when empty. | No commit leaves a coverage gap, and each module lands with its suite already in place. |
| D27 | All documentation (`ARCHITECTURE.md`, `DESIGN.md`, `DEVELOPER.md`) is written as a **final phase**, after the implementation settles. Module headers are still written with their module. | Avoids documentation churn across a long refactor. The requirements and architecture documents already serve as the specification during implementation. |
| D28 | `tt worktree sync` fires **no hooks**. It still runs inside a transaction. **This supersedes requirements §7.1**, which asked for hook parity with `tt worktree switch`. | Sync moves a worktree forward on the branch it is already on; the checked-out task does not change, so no checkout hook is semantically warranted. DESIGN.md states "no hooks" explicitly so the omission reads as deliberate rather than as an oversight. |

---

## 4. Technical strategy

### 4.1 Delivery shape

Single task branch, no sub-task tree (D18). Four phases, 18 checkpoint commits:

| Phase | Commits | Gate |
| --- | --- | --- |
| **A — Structural split** | A1–A5 | Full test suite passes **unmodified**. Any test change during Phase A is a defect, not a result. |
| **B — New mechanism** | B1–B4 | `lib/vcs/jj.test.sh` passes; the full suite still passes unmodified. |
| **C — Command migration** | C1–C8 | Each migrated command's own suite passes; every changed assertion justified individually. |
| **D — Documentation** | D1 | Documentation matches the delivered code. |

Each commit is made with `tt task checkpoint -m "<message>"`. A commit is not made until its gate
passes.

### 4.2 Module extraction mechanics (Phase A)

Each Phase A commit does four things atomically, for exactly one module:

1. Create `scripts/cli/lib/<module>.sh` with a header stating its responsibility and public surface.
2. Move the owning functions into it, renamed to `_<namespace>_<verb>[_<noun>]`.
3. Update **every** call site across `scripts/cli/**`. Completeness is verified mechanically:
   `grep -rn '\bold_name\b' scripts/` must return nothing.
4. Move that function's test cases into `scripts/cli/lib/<module>.test.sh`.

`common.sh` gains a `source` line and loses the moved functions.  There are no aliases and no shims,
so the tree is coherent after every commit (D25).

Phase A is a **pure refactor**: no behavior changes and no signature changes beyond namespacing.
Where a function's current signature is poor, that is recorded as a Phase C item rather than fixed
in flight.

Module load order in `common.sh`:

```
ui → string → format → path → frontmatter → commit → hook
   → vcs (→ vcs/jj) → history → task → workspace → worktree
```

### 4.3 Testing strategy

**Per-module suites.** One `<module>.test.sh` beside each module. `scripts/test` discovers them
automatically — it globs `scripts/cli/**/*.test.sh` — so no runner change is needed. Existing
`common.test.sh` cases relocate with their function (D26); `common.test.sh` is deleted in A5 once
empty.

**The backend suite is the load-bearing one.** `lib/vcs/jj.test.sh` covers every `_jj_*` function on
both its happy path and its failure path, plus the twelve hazard scenarios enumerated in requirements
§8.2. It is written in step B2, **before any command is migrated**, so that Phase C never has to
debug the mechanism and the command at the same time.

**Regression bar.** The full suite must pass. Phases A and B must pass it *unmodified*. In Phase C,
assertions legitimately change where bare operations change observable state — `@` no longer moving,
fewer intermediate commits produced. Every such change is called out in its commit message in this
form:

```
Assertion changed (intended): task/checkin.test.sh:412
  was: assert_current_task "on parent after checkin" "$parent_id"
  now: assert_current_task "@ unchanged after checkin" "$child_id"
  why: D22 — checkin no longer moves the working copy.
```

**Running.** Day-to-day development uses filters (`scripts/test lib/vcs`,
`scripts/test --filter symlink`). Every phase gate is verified with the full parallel suite on a RAM
disk:

```bash
RAMDISK=$(scripts/ramdisk create) && TT_TEST_ROOT=$RAMDISK scripts/test --parallel; \
  scripts/ramdisk destroy $RAMDISK
```

### 4.4 Behavioral change budget

Exactly four categories of user-visible change are permitted. Anything outside them is a defect.

1. **`@` stops moving** (D22). Mutating commands leave the working copy where they found it, except
   `task checkpoint`, `task checkout`, `workspace init`, `worktree sync` and `worktree switch`. `@`
   is still *reattached* onto a new tip when it descended from the old one; that keeps the working
   copy on the same branch and is not a move.
2. **Preconditions relax** (D11). Clean-working-copy checks are removed except in `task rename`,
   `task move` and `task checkin`. Each removal is justified as "existed only to serve the dance".
3. **New refusals.** Every mutating command refuses when `@` carries a bookmark (D10); a non-Git
   backing store fails with `Unsupported repository backend: <type>` (D7); `task rename` refuses on
   blocking foreign worktrees (D13, D23).
4. **New surface.** `tt worktree sync`, and the advisory out-of-sync warning emitted by mutating
   commands.

### 4.5 Documentation

Written as a final phase (D27), once the implementation has settled:

- **`ARCHITECTURE.md`** (new, repository root) — the four layers and what each may call; the
  `_<namespace>_<verb>_<noun>` naming rule; the module inventory with one-line responsibilities; the
  complete list of operations a backend must implement; the working-copy-bound exceptions and why
  they exist.
- **`DESIGN.md`** — user-facing changes only: `tt worktree sync` in §5.5 (noting explicitly that it
  fires no hooks), the relaxed preconditions in the affected §6.x sections and in §6.6, the
  out-of-sync warning, the unsupported-backend error, and the `@`-carries-a-bookmark refusal.
  Internal layering is deliberately excluded.
- **`DEVELOPER.md`** — the library module layout, how to run the new per-module suites, and
  `TT_VERBOSE`.
- **Module headers** — each module states its responsibility and public surface. These are written
  with the module in Phase A/B, not deferred to Phase D.

### 4.6 Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| The bare-write mechanism does not behave as the design's prototype did | Step B2 is gated by `jj.test.sh` before any command depends on it. If it fails, the task stops there rather than part-migrating. |
| A Phase A extraction silently breaks a caller the grep missed | Full suite must pass unmodified after every Phase A commit, and `grep -rn '\bold_name\b' scripts/` must return nothing. |
| `task rename` is the hardest command and could destabilise the branch | Migrated last among the writers (C5), with its three design topologies as explicit test scenarios. |
| The branch drifts behind its parent again during a long task | Re-propagate from `project/bootstrap-cli-d35756ce` at each phase boundary, then re-run the full suite. |
| bash 3.2 constraints violated accidentally | No `mapfile`/`readarray`/`declare -A` anywhere; keyed lookups use parallel arrays or scratch-directory files. Reviewed per commit. |
| A staging directory leaks into the repository or onto disk | Every staging directory is created with `mktemp -d` and removed by a `trap ... RETURN`/`EXIT` in the function that created it; `jj.test.sh` asserts no stray refs, bookmarks or temp paths survive. |

### 4.7 Explicitly out of scope

Implementing a Git backend; any change to the task-tree data model, task file format, or command
surface beyond §4.4; migration of the bootstrap bash CLI toward the Rust CLI; and fixing unrelated
defects discovered in passing — those become new sibling tasks under
`project/bootstrap-cli-d35756ce`.

---

## 5. Implementation details

### 5.0 Overview

**18 commits across four phases.** One correction to the phase boundaries sketched in §4.1:
`lib/vcs.sh` and `lib/vcs/jj.sh` are created **during Phase A** (step A3), not Phase B. Three Phase-A
modules — `history`, `workspace`, `worktree` — need repository discovery and the operation log, and
under D24 those are backend concerns. A3 is still a pure move; Phase B then *extends* the backend
rather than creating it.

| # | Commit subject | Phase | Gate |
| --- | --- | --- | --- |
| A1 | Extract UI, string and formatting helpers into library modules | A | full suite, unmodified |
| A2 | Extract path, frontmatter, commit-message and hook helpers | A | full suite, unmodified |
| A3 | Extract VCS backend interface and jj implementation | A | full suite, unmodified |
| A4 | Extract history, workspace and worktree facades | A | full suite, unmodified |
| A5 | Extract task facade and reduce common.sh to source directives | A | full suite, unmodified |
| B1 | Express every VCS query as a named backend operation | B | full suite unmodified + `lib/vcs/jj.test.sh` |
| B2 | Add bare commit construction to the jj backend | B | `jj.test.sh` §8.2 scenarios |
| B3 | Add worktree working-copy invariants, reattachment and sync | B | `lib/worktree.test.sh` |
| B4 | Add the task-facade staged write API | B | `lib/task.test.sh` |
| C1 | Migrate single-branch task writers to bare writes | C | 4 command suites |
| C2 | Migrate task creation, reordering and deletion to bare writes | C | 3 command suites |
| C3 | Migrate checkin and publish to handoff-plus-merge | C | 2 command suites |
| C4 | Migrate move and propagate to bare graph operations | C | 2 command suites |
| C5 | Migrate task rename to two-phase tree rewriting | C | rename suite, 3 topologies |
| C6 | Route working-copy-bound commands through the backend | C | 3 command suites |
| C7 | Add `tt worktree sync`; migrate worktree and history commands | C | new suite + 4 suites |
| C8 | Migrate read-only commands and close the layering | C | full suite + grep audit |
| D1 | Add ARCHITECTURE.md and update DESIGN.md and DEVELOPER.md | D | documentation review |

**Cross-cutting conventions applied in every Phase C commit that migrates a mutating command:**

1. Add `_worktree_ensure_working_copy "$repo"` to the precondition block, **before**
   `_history_begin_transaction` (architecture §6.1 — the check must run before the snapshot that
   would do the damage).
2. Remove the clean-working-copy precondition unless the command is `rename`, `move` or `checkin`.
3. Remove target-worktree resolution used only to pick whose working copy to borrow. Keep it where it
   is informational (reporting which worktree holds a task).
4. Remove `current_bookmark` / `current_worktree` values threaded through purely to restore `@`.
5. Call `_worktree_report_unsynced "$repo" "$branch"` once after the writes.
6. Add three cases to the command's own suite: the `@`-carries-a-bookmark refusal (once with a clean
   working copy, once with a bookmark unrelated to the command's target); that a dirty working copy
   survives untouched and is not absorbed into the created commit; and that `@` did not move.

**Command used for every commit:** `tt task checkpoint -m "<subject>"`, run from this worktree. Run
`jj log` and `tt task tree` before and after, per `AGENTS.md`.

---

### 5.1 Step A1 — Extract UI, string and formatting helpers

**Goal.** Create the three leaf utility modules that everything else depends on.

**Files created**

```
scripts/cli/lib/ui.sh          scripts/cli/lib/ui.test.sh
scripts/cli/lib/string.sh      scripts/cli/lib/string.test.sh
scripts/cli/lib/format.sh      scripts/cli/lib/format.test.sh
```

**Functions moved and renamed**

| From `common.sh` (line) | To | New name |
| --- | --- | --- |
| `log` (249) | `ui.sh` | `_ui_log` |
| `prompt_raw` (575) | `ui.sh` | `_ui_prompt_raw` |
| `prompt` (602) | `ui.sh` | `_ui_prompt` |
| `_select_value` (1963) | `ui.sh` | `_ui_select_raw` |
| `select_value` (1994) | `ui.sh` | `_ui_select` |
| `title_to_slug` (122) | `string.sh` | `_string_to_slug` |
| `validate_slug` (129) | `string.sh` | `_string_validate_slug` |
| `generate_hex` (159) | `string.sh` | `_string_generate_hex` |
| `generate_timestamp` (171) | `string.sh` | `_string_generate_timestamp` |
| `status_to_checkbox` (1457) | `format.sh` | `_format_status_checkbox` |

**Scale.** `log` is the single largest rename in the whole task: **390 call sites across 35 of the
37 non-test scripts**. Perform it with a scripted replacement and then verify by grep, rather than by
hand:

```bash
grep -rlE '(^|[^a-zA-Z0-9_.-])log (["$])' scripts/cli | while IFS= read -r f; do
  perl -pi -e 's/(^|[^a-zA-Z0-9_.\-])log (?=["\$])/${1}_ui_log /g' "$f"
done
```

The negative character class before `log` is essential: it prevents `jj log`, `op log` and
`jj -R "$repo" log` from being rewritten. After the replacement, confirm no VCS invocation was hit:

```bash
grep -rn 'jj .*_ui_log\|_ui_log --no-graph\|op _ui_log' scripts/     # must be empty
```

**Colour handling.** `ui.sh` also becomes the home for `NO_COLOR` handling. Today no command emits
ANSI sequences (only the test harness does), so this is a documented empty surface in the module
header rather than code; if a Phase C or D change needs colour, it is added here.

**`format.sh` scope.** In this step it holds only `_format_status_checkbox` (4 call sites). The
architecture also lists "tree indentation, task lines" as belonging here; those currently live inline
in `task/tree` and `task/show`. Moving them is only in scope if the two commands are found to contain
*identical* rendering logic — check with a diff of the relevant blocks. If they differ, leave them and
note it; unifying divergent rendering is a behavioral change and belongs to the sibling task
`task/standardize-command-output-a1c39913`.

**Tests relocated from `common.test.sh`.** All `test_select_value__*` and `test__select_value__*`
cases → `ui.test.sh`. Any slug/timestamp cases → `string.test.sh`. Rename the test functions to match
the new function names (`test__ui_select__…`).

**`common.sh` after this step** gains, at the top:

```bash
_TT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_TT_LIB_DIR/ui.sh"
. "$_TT_LIB_DIR/string.sh"
. "$_TT_LIB_DIR/format.sh"
```

**Checks before committing**

1. `grep -rnE '(^|[^a-zA-Z0-9_.-])(log|prompt|prompt_raw|select_value|_select_value|title_to_slug|validate_slug|generate_hex|generate_timestamp|status_to_checkbox) ' scripts/` returns nothing outside the new modules.
2. `bash -n` on every changed file.
3. Full parallel suite passes with **zero test files modified other than the relocations**.

---

### 5.2 Step A2 — Extract path, frontmatter, commit-message and hook helpers

**Files created**

```
scripts/cli/lib/path.sh          scripts/cli/lib/path.test.sh
scripts/cli/lib/frontmatter.sh   scripts/cli/lib/frontmatter.test.sh
scripts/cli/lib/commit.sh        scripts/cli/lib/commit.test.sh
scripts/cli/lib/hook.sh          scripts/cli/lib/hook.test.sh
```

**Functions moved and renamed**

| From `common.sh` (line) | To | New name |
| --- | --- | --- |
| `tt_metadata_path` (191) | `path.sh` | `_path_metadata` |
| `task_root_path` (202) | `path.sh` | `_path_task_root` |
| `task_file_path` (217) | `path.sh` | `_path_task_file` |
| `task_dir_path` (224) | `path.sh` | `_path_task_dir` |
| `task_context_path` (232) | `path.sh` | `_path_task_context` |
| `resolve_path_symlinks` (256) | `path.sh` | `_path_resolve_symlinks` |
| `make_absolute_symlink` (461) | `path.sh` | `_path_make_absolute_symlink` |
| `metadata_exclusion_fileset` (210) | — | **replaced**, see below |
| `parse_body` (244) | `frontmatter.sh` | `_frontmatter_parse_body` |
| `parse_frontmatter_fields` (517) | `frontmatter.sh` | `_frontmatter_parse_fields` |
| `parse_frontmatter_field` (539) | `frontmatter.sh` | `_frontmatter_parse_field` |
| `parse_quoted_frontmatter_field` (550) | `frontmatter.sh` | `_frontmatter_parse_quoted_field` |
| `parse_repeated_frontmatter_field` (563) | `frontmatter.sh` | `_frontmatter_parse_repeated_field` |
| `parse_task_frontmatter` (1556) | `frontmatter.sh` | `_frontmatter_parse_task` |
| `write_task_file` (1609) | `frontmatter.sh` | `_frontmatter_write_task_file` |
| `write_context_file` (1647) | `frontmatter.sh` | `_frontmatter_write_context_file` |
| `_insert_frontmatter_line` (1686) | `frontmatter.sh` | `_frontmatter_insert_line` |
| `append_frontmatter_context` (1711) | `frontmatter.sh` | `_frontmatter_append_context` |
| `append_frontmatter_subtask` (1719) | `frontmatter.sh` | `_frontmatter_append_subtask` |
| `update_frontmatter_timestamp` (1727) | `frontmatter.sh` | `_frontmatter_update_timestamp` |
| `format_commit_message` (61) | `commit.sh` | `_commit_format_message` |
| `parse_commit_message` (89) | `commit.sh` | `_commit_parse_message` |
| `run_hook` (439) | `hook.sh` | `_hook_run` |

The constants `TT_METADATA_DIR` and `TT_TASK_SYMLINK_FILENAME` move to `path.sh` unchanged — the
naming convention governs functions, not variables.

**`metadata_exclusion_fileset` — the one genuine change in this step.** It currently returns a **jj
fileset expression**:

```bash
printf '~(root:"%s" | root-file:"%s")' "$TT_METADATA_DIR" "$TT_TASK_SYMLINK_FILENAME"
```

That is backend syntax, and D6 forbids it outside `lib/vcs/jj.sh`. Replace it with a pure helper that
emits the *paths* and lets the backend build the expression:

```bash
# Usage: _path_metadata_exclusions
# Emits one "<kind>\t<path>" record per tt-metadata path that diffs should exclude.
# <kind> is 'dir' or 'file'. Backends translate these into their own path syntax.
_path_metadata_exclusions() {
  printf 'dir\t%s\nfile\t%s\n' "$TT_METADATA_DIR" "$TT_TASK_SYMLINK_FILENAME"
}
```

Its only consumer is `scripts/cli/task/diff`. In this step, `task/diff` assembles the fileset inline
from those records — no worse than today, since `task/diff` already invokes `jj diff` directly — and
carries a `# TODO(C8)` marker. Step C8 replaces the whole thing with
`_vcs_show_diff REPO FROM TO [EXCLUDE…]`.

**Known-poor signatures, recorded not fixed.** Two functions pass data through global variables:

- `_frontmatter_parse_task` writes `PARSED_TITLE`, `PARSED_STATUS`, `PARSED_CREATED`,
  `PARSED_UPDATED`, `PARSED_BODY`, `PARSED_LABELS[]`, `PARSED_CONTEXTS[]`, `PARSED_SUBTASKS[]`.
- `_frontmatter_write_task_file` reads `REWRITE_LABELS[]`, `REWRITE_CONTEXTS[]`, `REWRITE_SUBTASKS[]`.

Both are preserved verbatim in Phase A. bash 3.2 has no associative arrays and no way to return
structured data, so the globals are a legitimate idiom here; they are documented in the module header
as part of the public surface rather than treated as a defect.

**Tests relocated.** The bulk of `common.test.sh` — every `test_append_frontmatter_*`,
`test__insert_frontmatter_line__*`, `test_parse_frontmatter_*`, `test_write_task_file__*`,
`test_update_frontmatter_timestamp__*` case — moves to `frontmatter.test.sh`. Path cases move to
`path.test.sh`; `parse_commit_message` / `format_commit_message` cases to `commit.test.sh`.

**Checks before committing.** As A1: grep for every old name returns nothing; `bash -n` clean; full
suite passes with no test changes beyond relocation.

---

### 5.3 Step A3 — Extract VCS backend interface and jj implementation

**Goal.** Create the seam. This step moves only the functions that are *purely* VCS wrappers, plus
repository discovery (D24) and the working-copy primitives that the legacy dance needs in A5.

**Files created**

```
scripts/cli/lib/vcs.sh           scripts/cli/lib/vcs.test.sh
scripts/cli/lib/vcs/jj.sh        scripts/cli/lib/vcs/jj.test.sh
```

**Functions moved into `lib/vcs/jj.sh`**

| From `common.sh` (line) | New backend name | Notes |
| --- | --- | --- |
| `jj_show_at_revision` (12) | `_jj_read_file_at_revision` | clean signature |
| `jj_show_at_op` (34) | `_jj_read_file_at_operation` | clean signature |
| `get_jj_op_id` (25) | `_jj_get_operation_id` | clean signature |
| `count_revs_in_revset` (397) | `_jj_count_revisions` | **TRANSITIONAL** — takes a revset; replaced in B1 |
| `get_commit_description` (404) | `_jj_get_commit_description` | clean signature |
| `is_wc_clean` (411) | `_jj_check_working_copy_clean` | restricted (§4 "Working copy") |
| `has_conflicts` (614) | `_jj_check_has_conflicts` | **TRANSITIONAL** — takes a revset |
| `mainline_commit_records` (1055) | `_jj_list_mainline_commits` | clean signature (`REPO BASE TIP`) |
| `get_worktree_current_rev` (1132) | `_jj_get_working_copy_revision` | restricted |
| `resolve_current_worktree` (1139) | `_jj_resolve_worktree_root` | |
| `jj_workspace_list` (1185) | `_jj_list_worktrees` | |
| `forget_worktree` (1416) — the `jj` half | `_jj_forget_worktree` | the `rm -rf` half goes to `worktree.sh` in A4 |
| `find_repo_root` (263) | `_jj_find_repository_root` | D24 |
| `resolve_canonical_repo` (1769) | `_jj_resolve_repository_root` | D24 |
| `resolve_canonical_repo_path` (1793) | `_jj_resolve_repository_path` | D24 |
| — (new) | `_jj_check_is_repository` | `[[ -d "$1/.jj" ]]`, extracted from `resolve_repo` |

**New restricted working-copy primitives** (needed by `_task_write_and_commit_on_branch` in A5, so
that even the transitional dance goes through the seam):

```bash
_jj_get_working_copy_parent  WORKTREE            # jj log -r '@-' -T commit_id
_jj_set_working_copy_revision WORKTREE REV       # jj edit REV
_jj_new_working_copy_child   WORKTREE [REV]      # jj new [-r REV]
_jj_commit_working_copy      WORKTREE MESSAGE    # jj commit -m MESSAGE
_jj_set_bookmark             REPO NAME REV       # jj bookmark set NAME -r REV
```

`_jj_set_bookmark` **always requires an explicit revision** (architecture §4). The three call sites
that currently omit `-r` (`task/move` ×2, `task/propagate` ×2, `task/checkout` ×1) are given the
revision they implicitly relied on — `@` — written out explicitly. This is the earliest point at
which hazard 2 from the audit is closed, and it is behaviour-preserving.

**`lib/vcs.sh`** sources the backend and declares one wrapper per operation:

```bash
_TT_LIB_DIR="${_TT_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
. "$_TT_LIB_DIR/vcs/jj.sh"

_vcs_read_file_at_revision()   { _jj_read_file_at_revision "$@"; }
_vcs_read_file_at_operation()  { _jj_read_file_at_operation "$@"; }
_vcs_get_operation_id()        { _jj_get_operation_id "$@"; }
# …one line per operation, in the order of the contract…
```

**What deliberately does *not* move here.** Nine task-domain functions embed jj revsets but are
task-domain logic, not VCS wrappers: `find_parent_branch`, `find_branch_for_task`, `resolve_current`,
`resolve_task_range`, `get_task_range_context`, `resolve_task_fork_point`,
`get_full_task_range_records`, the `_full_range_*` family, and `check_bookmark_up_to_date`. They move
to `lib/task.sh` in A5 **with their revsets still inline**, each carrying a
`# TRANSITIONAL(B1): inline revset` marker. Step B1 lifts every one of those revsets into a named
backend operation.

> **Layering note.** Between A5 and B1, `lib/task.sh` contains direct `jj` invocations. This is a
> known, time-boxed violation of D1, confined to Phase A, and closed by B1. Acceptance criteria 1 and
> 2 are therefore first satisfied at B1, not at A5. Every such site carries the marker above so the
> outstanding set is greppable.

**`lib/vcs.test.sh`** in this step asserts only the contract's shape: that for every `_vcs_*` function
defined there is a correspondingly named `_jj_*` function, and vice versa. This is cheap and catches
wrapper drift for the rest of the task:

```bash
test__vcs_contract__every_wrapper_has_a_backend() {
  local missing=""
  for fn in $(declare -F | awk '{print $3}' | grep '^_vcs_'); do
    declare -F "_jj_${fn#_vcs_}" >/dev/null || missing="$missing $fn"
  done
  assert_eq "every _vcs_ wrapper has a _jj_ implementation" "$missing" ""
}
```

**Checks before committing.** Old names absent; `bash -n` clean; full suite unchanged; the new
contract test passes.

---

### 5.4 Step A4 — Extract history, workspace and worktree facades

**Files created**

```
scripts/cli/lib/history.sh     scripts/cli/lib/history.test.sh
scripts/cli/lib/workspace.sh   scripts/cli/lib/workspace.test.sh
scripts/cli/lib/worktree.sh    scripts/cli/lib/worktree.test.sh
```

**Functions moved and renamed**

| From `common.sh` (line) | To | New name |
| --- | --- | --- |
| `init_tt_history` (357) | `history.sh` | `_history_init` |
| `resolve_history_file_location` (1805) | `history.sh` | `_history_resolve_file` |
| `tt_begin_transaction` (1822) | `history.sh` | `_history_begin_transaction` |
| `tt_commit_transaction` (1872) | `history.sh` | `_history_commit_transaction` |
| `tt_rollback_transaction` (1914) | `history.sh` | `_history_rollback_transaction` |
| `resolve_repo` (286) | `workspace.sh` | `_workspace_resolve_repo` |
| `get_task_prefix` (314) | `workspace.sh` | `_workspace_get_task_prefix` |
| `get_project_prefix` (326) | `workspace.sh` | `_workspace_get_project_prefix` |
| `set_workspace_dir` (348) | `workspace.sh` | `_workspace_set_dir` |
| `get_workspace_dir` (367) | `workspace.sh` | `_workspace_get_dir` |
| `update_head_symlink` (476) | `workspace.sh` | `_workspace_update_head` |
| `get_active_worktree` (1440) | `workspace.sh` | `_workspace_get_active_worktree` |
| `parse_workspace_list_line` (1242) | `worktree.sh` | `_worktree_parse_list_line` |
| `list_worktree_entries` (1257) | `worktree.sh` | `_worktree_list_entries` |
| `list_workspaces` (1396) | `worktree.sh` | `_worktree_list` |
| `resolve_workspace_name` (1362) | `worktree.sh` | `_worktree_resolve_name` |
| `resolve_workspace_path` (1379) | `worktree.sh` | `_worktree_resolve_path` |
| `find_worktrees_for_branch` (1274) | `worktree.sh` | `_worktree_find_for_branch` |
| `resolve_task_worktree` (1154) | `worktree.sh` | `_worktree_resolve_for_task` |
| `forget_worktree` (1416) — the `rm -rf` half | `worktree.sh` | `_worktree_delete` |
| `perform_workspace_switch` (487) | `worktree.sh` | `_worktree_switch` |

`_workspace_resolve_repo` keeps its exact priority order — `--repo` value, then `$TT_REPO`, then
walk-up — but the walk-up and the validity check now go through `_vcs_find_repository_root` and
`_vcs_check_is_repository`. Its error messages are unchanged, because command suites assert on them.

`_worktree_resolve_for_task` is moved unchanged even though most of it becomes dead in Phase C —
Phase A does not delete anything. Its removal is tracked in C1/C2.

**`resolve_canonical_repo` callers.** `_history_resolve_file` calls
`_vcs_resolve_repository_root` (A3). `_history_commit_transaction` and
`_history_rollback_transaction` currently re-derive the canonical repo by `cd`-ing to the history
file's directory and calling `find_repo_root`; that becomes `_vcs_find_repository_root`. Preserve the
fallback behaviour and the warning text exactly — `history/undo.test.sh` and
`history/unlock.test.sh` assert on them.

**Tests relocated.** `common.test.sh` transaction and workspace-listing cases move to
`history.test.sh` and `worktree.test.sh`.

---

### 5.5 Step A5 — Extract task facade; reduce `common.sh` to source directives

**Files created**

```
scripts/cli/lib/task.sh   scripts/cli/lib/task.test.sh
```

**Files deleted**

```
scripts/cli/lib/common.test.sh    (now empty)
```

**Functions moved and renamed**

| From `common.sh` (line) | New name | Marker |
| --- | --- | --- |
| `is_task_branch` (338) | `_task_check_is_task_branch` | |
| `is_project_branch` (389) | `_task_check_is_project_branch` | |
| `assert_bookmark_up_to_date` (425) | `_task_assert_bookmark_current` | |
| `check_bookmark_up_to_date` (1427) | `_task_check_bookmark_current` | TRANSITIONAL(B1) |
| `find_parent_branch` (628) | `_task_find_parent_branch` | TRANSITIONAL(B1) |
| `find_parent_project` (1069) | `_task_find_parent_project` | |
| `find_branch_for_task` (1092) | `_task_find_branch` | TRANSITIONAL(B1) |
| `get_task_range_context` (677) | `_task_get_range_context` | TRANSITIONAL(B1) |
| `resolve_task_range` (727) | `_task_resolve_range` | TRANSITIONAL(B1) |
| `resolve_task_fork_point` (743) | `_task_resolve_fork_point` | TRANSITIONAL(B1) |
| `get_full_task_range_records` (791) | `_task_get_full_range_records` | TRANSITIONAL(B1) |
| `_full_range_resolve_commit` (944) | `_task_full_range_resolve_commit` | TRANSITIONAL(B1) |
| `_full_range_bookmark_task_file` (958) | `_task_full_range_bookmark_task_file` | |
| `_full_range_creation_boundary` (971) | `_task_full_range_creation_boundary` | TRANSITIONAL(B1) |
| `_full_range_query_waypoints` (991) | `_task_full_range_query_waypoints` | TRANSITIONAL(B1) |
| `_full_range_symlink_diff` (1004) | `_task_full_range_symlink_diff` | TRANSITIONAL(B1) |
| `_full_range_parse_symlink_removed` (1012) | `_task_full_range_parse_symlink_removed` | |
| `_full_range_parse_symlink_added` (1018) | `_task_full_range_parse_symlink_added` | |
| `_full_range_span_empty` (1024) | `_task_full_range_span_empty` | |
| `_full_range_covered_by` (1033) | `_task_full_range_covered_by` | |
| `resolve_current` (1298) | `_task_resolve_current` | TRANSITIONAL(B1) |
| `resolve_current_rev` (1331) | `_task_resolve_current_revision` | |
| `resolve_current_task_file` (1342) | `_task_resolve_current_file` | |
| `resolve_current_bookmark` (1353) | `_task_resolve_current_branch` | |
| `collect_descendant_task_dirs` (1481) | `_task_collect_descendant_dirs` | |
| `write_task_stub` (1663) | `_task_write_stub` | |
| `write_and_commit_on_branch` (1215) | `_task_write_and_commit_on_branch` | **LEGACY(C1)** |

**`_task_write_and_commit_on_branch`.** Rewritten to compose the A3 primitives rather than call `jj`
directly, so the layering holds even in its transitional form:

```bash
# LEGACY(C1): the working-copy dance. Replaced by _task_commit_on_branch in Phase C.
_task_write_and_commit_on_branch() {
  local repo="$1" target_worktree="$2" bookmark="$3"
  local current_worktree="$4" current_bookmark="$5" message="$6" writer_fn="$7"
  shift 7

  if [[ "$target_worktree" == "$current_worktree" && "$current_bookmark" != "$bookmark" ]]; then
    local original_parent_rev
    original_parent_rev="$(_vcs_get_working_copy_parent "$repo")"
    _vcs_set_working_copy_revision "$repo" "$bookmark"
    _vcs_new_working_copy_child "$repo"
    "$writer_fn" "$repo" "$@"
    _vcs_commit_working_copy "$repo" "$message"
    _vcs_set_bookmark "$repo" "$bookmark" '@-'
    _vcs_new_working_copy_child "$repo" "$original_parent_rev"
  else
    "$writer_fn" "$target_worktree" "$@"
    _vcs_commit_working_copy "$target_worktree" "$message"
    _vcs_set_bookmark "$target_worktree" "$bookmark" '@-'
  fi
}
```

**`common.sh` after this step** — the entire file:

```bash
# Aggregator for the tt bootstrap CLI library.
# Source this file; do not execute directly. Defines nothing itself.
_TT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$_TT_LIB_DIR/ui.sh"
. "$_TT_LIB_DIR/string.sh"
. "$_TT_LIB_DIR/format.sh"
. "$_TT_LIB_DIR/path.sh"
. "$_TT_LIB_DIR/frontmatter.sh"
. "$_TT_LIB_DIR/commit.sh"
. "$_TT_LIB_DIR/hook.sh"
. "$_TT_LIB_DIR/vcs.sh"
. "$_TT_LIB_DIR/history.sh"
. "$_TT_LIB_DIR/task.sh"
. "$_TT_LIB_DIR/workspace.sh"
. "$_TT_LIB_DIR/worktree.sh"
```

**Checks before committing**

1. `grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{' scripts/cli/lib/common.sh` returns `0` — satisfies
   acceptance criterion 4.
2. Every function in every module matches `^_(ui|string|format|path|frontmatter|commit|hook|vcs|jj|history|task|workspace|worktree)_`.
3. `scripts/cli/lib/common.test.sh` no longer exists.
4. Full suite passes; total test count is unchanged from before A1.

---

### 5.6 Step B1 — Express every VCS query as a named backend operation

**Goal.** Close the layering violation left open by A5, and remove every revset and template from
outside `lib/vcs/jj.sh` — acceptance criteria 1, 2 and 6.

**Backend operations added** (names and signatures from architecture §4; each replaces the inline
revset noted in the right-hand column):

| Operation | Replaces |
| --- | --- |
| `_vcs_get_backend_type REPO` | new — reads `.jj/repo/store/type` |
| `_vcs_check_backend_supported REPO` | new — fails `Unsupported repository backend: <type>` |
| `_vcs_restore_operation REPO OP_ID` | `jj op restore` in `history/undo`, `_history_rollback_transaction` |
| `_vcs_get_commit_id REPO REV` | `jj log -T commit_id` in `create`, `move`, `checkin`, `rename`, `complete` |
| `_vcs_get_change_id REPO REV` | `jj log -T change_id` in `rename`, `propagate` |
| `_vcs_check_revision_exists REPO REV` | `jj log -r REV -T ''` in `resolve_task_range`, `publish`, `checkout` |
| `_vcs_check_commit_empty REPO REV` | `jj log -T empty` in `_task_resolve_range`, `checkpoint` |
| `_vcs_check_has_conflicts REPO REV` | `_jj_check_has_conflicts` — revset arg dropped |
| `_vcs_check_descendants_have_conflicts REPO REV` | `has_conflicts "descendants(…)"` in `checkin`, `publish`, `propagate` |
| `_vcs_check_is_ancestor REPO ANCESTOR DESCENDANT` | `::` revsets in `propagate`, `checkin` |
| `_vcs_find_fork_point REPO REV_A REV_B` | `fork_point(…)` in `_task_resolve_fork_point` |
| `_vcs_find_nearest_bookmark REPO REV` | `heads(ancestors(@) & bookmarks())` in `_task_resolve_current` |
| `_vcs_list_commits_in_range REPO FROM TO` | `::TO ~ ::FROM` in `rename`, `changelog`, `revset` |
| `_vcs_count_commits_in_range REPO FROM TO` | `_jj_count_revisions` — revset arg dropped |
| `_vcs_list_range_roots REPO FROM TO` | `roots(::X ~ ::Y)` in `move`, `propagate` |
| `_vcs_list_mainline_commits REPO BASE TIP` | already clean from A3 |
| `_vcs_format_revision_range REPO FORMAT FROM TO` | `task/revset`'s `--git` branch (§7.4) |
| `_vcs_list_bookmarks REPO` | `log -r 'bookmarks()' -T local_bookmarks…` in `_task_find_parent_branch`, `_task_find_branch` |
| `_vcs_list_bookmarks_at REPO REV` | `log -T bookmarks` in `task/show`, `worktree/list` |
| `_vcs_check_bookmark_exists REPO NAME` | ad-hoc `jj log -r NAME` existence probes |
| `_vcs_rename_bookmark REPO OLD NEW` | `jj bookmark rename` in `task/rename` |
| `_vcs_delete_bookmark REPO NAME` | `jj bookmark delete` in `task/delete` |
| `_vcs_check_file_exists_at_revision REPO REV PATH` | `jj file show … >/dev/null` probes |
| `_vcs_list_files_at_revision REPO REV [PREFIX]` | `jj file list` in `task/rename`; needed by `--delete-prefix` |
| `_vcs_list_files_at_operation REPO OP REV [PREFIX]` | `jj --at-operation file list` in `task/rename` |
| `_vcs_show_diff REPO FROM TO [EXCLUDE…]` | `jj diff` in `task/diff`, `task/checkin` |
| `_vcs_create_worktree REPO NAME PATH REV` | `jj workspace add` in `task/checkout` |
| `_vcs_get_worktree_revision REPO NAME` | worktree `@` lookups |

**`TT_VERBOSE` (D16).** Add a single internal helper in `lib/vcs/jj.sh` and route every backend
invocation through it:

```bash
# Usage: _jj_run REPO ARG...
# Runs `jj -R REPO ARG...`. Echoes the command line to stderr and forwards the
# invocation's stderr when TT_VERBOSE=1; otherwise both are discarded.
# Never logs and never exits: returns the underlying exit status.
_jj_run() {
  local repo="$1"; shift
  if [[ "${TT_VERBOSE:-}" == "1" ]]; then
    printf '+ jj -R %s %s\n' "$repo" "$*" >&2
    jj -R "$repo" "$@"
  else
    jj -R "$repo" "$@" 2>/dev/null
  fi
}
```

For read helpers, stdout is the return value and is always captured; only stderr is gated. A parallel
`_jj_run_git` wrapper does the same for the Git plumbing added in B2.

**`lib/vcs/jj.test.sh`** gains a case per read-only operation covering the happy path and the failure
path (absent revision, absent file, absent bookmark), plus one asserting that `TT_VERBOSE=1` writes
the command line to stderr and leaves stdout byte-identical.

**Checks before committing**

1. `grep -rn 'jj ' scripts/cli --include='*' | grep -v 'lib/vcs/jj' | grep -v '\.test\.sh'` — the
   only remaining hits are the commands not yet migrated in Phase C; **no hit is inside `lib/`**.
2. `grep -rn 'TRANSITIONAL(B1)' scripts/` returns nothing.
3. Full suite passes unmodified.

---

### 5.7 Step B2 — Add bare commit construction to the jj backend

**Goal.** The mechanism the whole task exists for. Nothing calls it yet, so a failure here costs
nothing beyond this step.

**Backend operations added**

```
_jj_commit_changeset  REPO PARENT_REV MESSAGE STAGE_DIR [DELETE_PATH...]  → new commit ID
_jj_create_merge_commit REPO MESSAGE PARENT_REV...                        → new commit ID
_jj_set_description   REPO REV MESSAGE
_jj_move_commits      REPO SOURCE_REV DEST_REV
_jj_squash_commit     REPO FROM_REV INTO_REV
_jj_restore_tree      REPO SOURCE_REV TARGET_REV
_jj_abandon_commit    REPO REV
```

**`_jj_commit_changeset` algorithm** (architecture §5):

```
1. _jj_check_backend_supported REPO
      read .jj/repo/store/type; if not 'git', fail with
      "Unsupported repository backend: <type>"
2. GIT_DIR ← contents of .jj/repo/store/git_target,
      resolved RELATIVE TO .jj/repo/store/   (not .jj/repo/)
3. scratch ← mktemp -d ;  trap cleanup RETURN
   index  ← "$scratch/index"   # do NOT create the file; an empty file is
                               # rejected as a malformed index
4. GIT_INDEX_FILE=$index git read-tree <PARENT_REV's tree>
5. for each DELETE_PATH:   git update-index --force-remove -- "$path"
6. for each file under STAGE_DIR (find -type f -o -type l), path relative to STAGE_DIR:
        if symlink   → mode 120000, blob ← hash-object of the link TARGET STRING
        elif -x      → mode 100755, blob ← hash-object of the file
        else         → mode 100644, blob ← hash-object of the file
        git update-index --add --cacheinfo "$mode,$blob,$path"
7. tree ← git write-tree
8. identity ← jj config get user.name / user.email
   commit ← git commit-tree "$tree" -p <PARENT_REV> -m "$MESSAGE"
              with GIT_AUTHOR_NAME/EMAIL and GIT_COMMITTER_NAME/EMAIL set from identity
9. git update-ref "refs/heads/$tmp_ref" "$commit"
   jj git import
   resolve the imported commit; drop the temporary ref and any bookmark it created
10. print the new commit ID
```

Deletions are applied **before** the staging overlay (step 5 before step 6), so removing a prefix and
writing a path beneath it in the same changeset is well defined.

Identity must be set explicitly because the ambient Git identity can differ from the jj-configured
one.

**bash 3.2 constraint.** Iterating `find` output with a `while read` loop over a process
substitution is the only safe pattern available — no `mapfile`. Paths containing newlines are out of
scope (tt paths are slugs and fixed filenames); note this in the function header.

**`lib/vcs/jj.test.sh` — the twelve required scenarios** (requirements §8.2). Each is a
`test__jj_commit_changeset__*` or sibling function:

| # | Scenario |
| --- | --- |
| 1 | Writing to a branch while the current worktree has uncommitted changes preserves those changes and does not include them in the created commit. |
| 2 | A mutating operation refuses when `@` carries a bookmark — including with a clean working copy, and when the bookmark is unrelated to the target. |
| 3 | The current worktree is reattached to the new commit when its working-copy commit descended from the previous tip. |
| 4 | The current worktree is left alone when its working-copy commit did not descend from the previous tip. |
| 5 | Writing to a branch checked out in another worktree leaves that worktree untouched and usable. |
| 6 | … reports it as out of sync. |
| 7 | … preserves its uncommitted changes, including changes never snapshotted. |
| 8 | Synchronizing a behind worktree brings it onto the branch head and preserves its uncommitted changes. |
| 9 | Symlink creation, retargeting and deletion round-trip correctly through a bare write. |
| 10 | Executable and regular file modes are preserved. |
| 11 | Deletions remove paths from the resulting commit. |
| 12 | Created commits carry the jj-configured identity even when the ambient Git identity differs; a non-Git backing store fails with the specified message; branch-setting targets the intended revision regardless of where `@` sits. |

Scenarios 2–8 depend on B3 helpers; write them in B3 and cross-reference. Scenarios 1 and 9–12
belong to B2 and gate this commit.

Also assert, after every bare write: **no temporary ref, bookmark or scratch directory survives**
(`jj bookmark list` and `git for-each-ref refs/heads/tt-*` are both clean; `$TMPDIR` has no residue).

**Non-Git backing store test.** Create a fixture whose `.jj/repo/store/type` reads `simple`, call any
bare-write operation, and assert stderr is exactly `Unsupported repository backend: simple`.

---

### 5.8 Step B3 — Add worktree working-copy invariants, reattachment and sync

**Functions added to `lib/worktree.sh`**

```bash
_worktree_ensure_working_copy REPO
    # Refuses when @ carries any bookmark, whatever the working-copy state (D10).
    # Names the bookmark and the remedy. Called from every mutating command's
    # precondition block, BEFORE _history_begin_transaction.

_worktree_reattach_current REPO OLD_TIP NEW_REV
    # Moves the current worktree's working-copy commit onto NEW_REV if it
    # descended from OLD_TIP; does nothing otherwise. The rebase runs inside the
    # worktree, so the working copy is updated in the same step.

_worktree_list_unsynced REPO BRANCH
    # TSV: <worktree-path>\t<task-id> for every worktree OTHER than the current
    # one whose working-copy commit still descends from the previous tip.

_worktree_report_unsynced REPO BRANCH
    # Prints the advisory warning to stderr; always returns 0.

_worktree_sync REPO WORKTREE
    # Brings WORKTREE onto the head of its branch, running INSIDE it.
    # Snapshots first, so uncommitted work is preserved. Reports what changed.
```

**Refusal message** for `_worktree_ensure_working_copy`:

```
Error: The working-copy commit is the tip of bookmark 'task/foo-1234abcd'.
  tt cannot write to a branch while the working copy carries a bookmark, because
  capturing the working copy would absorb unrelated changes into that branch.
  Move off it first:
    jj new
```

The scope is **any** bookmark, not merely the branch being written, because the snapshot contaminates
whichever bookmark `@` carries. There are no exemptions — including `task checkpoint` (D10).

**Why the check is not folded into `_history_begin_transaction`.** Recognizing a branch tip requires
knowing tt's branch model; the transaction module's responsibility is the `.tt/history` log, and
embedding the invariant there would make the undo log unreadable without also understanding tt's
branching conventions. The *snapshot* does stay in `_history_begin_transaction`: capturing the working
copy needs no knowledge of branches, and it must happen after the operation ID is recorded for
`tt history undo` to restore uncommitted work faithfully.

**`_history_begin_transaction` change.** After recording the before-op ID and appending the
in-progress line, snapshot the current worktree (`_vcs_snapshot_worktree`). Order matters: op ID
first, snapshot second.

**Out-of-sync warning format** (requirements §4.5, verbatim):

```
The following worktrees are now out of sync:
  <path> (<task-id>)
```

followed by a line directing the user to `tt worktree sync`. The message contains no
backend-specific remedy. The command still succeeds.

**Tests** — `lib/worktree.test.sh` covers scenarios 2–8 from the B2 table, plus: the refusal fires for
a clean working copy; the refusal fires for a bookmark unrelated to the target; `_worktree_sync`
preserves un-snapshotted files; `_worktree_reattach_current` is a no-op when `@` did not descend from
the old tip.

---

### 5.9 Step B4 — Add the task-facade staged write API

**Function added to `lib/task.sh`** (architecture §7):

```
_task_commit_on_branch REPO BRANCH MESSAGE
    [--modify PATH]... [--delete PATH]... [--delete-prefix PREFIX]...
    -- WRITER_FN [ARGS...]
```

Prints the new commit ID. Steps:

1. Resolve the branch tip (`_vcs_get_commit_id`).
2. Create a staging directory (`mktemp -d`, cleaned by `trap ... RETURN`).
3. Materialize each `--modify` path from the tip into the staging directory, creating parent
   directories. **A path absent at the tip is an error**, not an empty file.
4. Expand each `--delete-prefix` into exact file paths via `_vcs_list_files_at_revision`, and combine
   with the `--delete` paths into the deletion list.
5. Run `WRITER_FN` with the staging root as its first argument, followed by `ARGS`.
6. `_vcs_commit_changeset REPO <tip> MESSAGE <stage> <deletions...>`.
7. `_vcs_set_bookmark REPO BRANCH <new commit>`.
8. `_worktree_reattach_current REPO <tip> <new commit>`.

**The three inputs are orthogonal.** `--modify` materializes existing files for read-modify-write; the
staging directory carries new and replaced content; the delete flags carry removals. **A file
disappearing from the staging directory is not a deletion** — removals are always declared. Document
this prominently in the function header, because it is the single most likely misuse.

**Example** (from architecture §7):

```bash
_task_commit_on_branch "$repo" "$parent_bookmark" "$msg" \
  --modify "$parent_task_file" \
  --delete-prefix ".tt/task/$slug" \
  -- _write_parent_without_subtask "$task_id"

_write_parent_without_subtask() {
  local stage="$1" task_id="$2"
  _frontmatter_remove_subtask "$stage/$parent_task_file" "$task_id"
}
```

**Argument parsing.** `--` separates the flags from the writer function and its arguments; parse
flags in a `while` loop until `--` is seen, then treat the remainder positionally. Reject an unknown
flag rather than passing it through.

**`_frontmatter_remove_subtask`** does not exist today — the removal is hand-rolled with `awk` in
`task/delete` and `task/move`. Add it to `lib/frontmatter.sh` in this step, with cases in
`frontmatter.test.sh`, so C2 and C4 both consume one implementation.

**Tests** — `lib/task.test.sh`: writes land on the branch and not in the working copy; `--modify` of
an absent path fails; `--delete-prefix` expands to the right file set; the bookmark advances to the
new commit; `@` does not move; a dirty working copy is untouched.

---

### 5.10 Step C1 — Migrate single-branch task writers to bare writes

**Commands:** `task/edit`, `task/context/add`, `task/context/delete`, `task/complete`.

These four write one file set to one branch and are the simplest possible exercise of
`_task_commit_on_branch`. They are migrated together because they share a writer shape and because
deleting `_task_write_and_commit_on_branch` requires all three of its callers to move at once.

**Per command**

| Command | Writer | Flags |
| --- | --- | --- |
| `task/edit` | rewrite `TASK.md` from the edited buffer | `--modify <task file>` |
| `task/context/add` | write the new context file **and** append `context:` + bump `updated:` in `TASK.md` | `--modify <task file>` |
| `task/context/delete` | rewrite `TASK.md` without the `context:` entry | `--modify <task file>`, `--delete <context file>` |
| `task/complete` | set `status: DONE`, bump `updated:` | `--modify <task file>` |

Note `context/delete`'s `rm -f` becomes an explicit `--delete`, per D8.

**Removals in this step**

- `_task_write_and_commit_on_branch` (deleted entirely).
- `_worktree_resolve_for_task` calls in all four commands.
- `_jj_check_working_copy_clean` preconditions in all four (D11 — these existed only to serve the
  dance).
- `current_bookmark` / `current_worktree` threading in all four.

**Additions in all four:** `_worktree_ensure_working_copy`, `_worktree_report_unsynced`, and the
three cross-cutting test cases from §5.0.

**Expected assertion changes** — anywhere a suite asserts `@` moved onto the new commit or that the
working copy was clean afterwards. Each is rewritten to assert `@` is unchanged, with the
justification format from §4.3.

**`task/complete` hooks.** `pre-complete` still fires before the write; `post-complete` still fires
after the transaction commits and still receives `TT_COMMIT`, now set from the commit ID returned by
`_task_commit_on_branch` rather than read back from `@-`.

---

### 5.11 Step C2 — Migrate task creation, reordering and deletion

**Commands:** `task/create`, `task/reorder`, `task/delete`.

**`task/create`** is the first two-branch write. Today it interleaves three `jj new`/`describe`/
`bookmark set` sequences with disk writes and a best-effort `jj edit` restore. After migration:

```
1. _worktree_ensure_working_copy
2. _history_begin_transaction
3. parent branch:  _task_commit_on_branch REPO PARENT msg
                      --modify <parent task file>
                      -- _write_parent_with_subtask <task-id>
4. task branch:    _task_commit_on_branch REPO <fork point> msg
                      -- _write_task_stub <suffix>
                   …then _vcs_set_bookmark REPO <task-id> <new commit>
5. delegate to `tt task edit` for the body (unchanged)
6. _worktree_report_unsynced ; _history_commit_transaction
```

Step 4 creates a **new** branch, so it does not use `_task_commit_on_branch`'s
resolve-the-branch-tip path. Two options, decided during implementation: either give
`_task_commit_on_branch` an explicit `--parent REV` form, or add a sibling
`_task_commit_new_branch REPO NEW_BRANCH PARENT_REV MESSAGE …`. Prefer the second — creating a branch
and advancing one are different operations and conflating them would make the common case less clear.

The `--checkout` path continues to delegate to `tt task checkout` (which is working-copy-bound and is
migrated in C6). Without `--checkout`, `@` does not move at all — the current best-effort restore
disappears.

**`task/reorder`** has two modes (reorder a subtask in the parent's file; tidy the current task's own
frontmatter). Both become a single `_task_commit_on_branch` with `--modify` of the file being
rewritten. The `jj new <branch>` that currently moves `@` onto the target branch disappears.

**`task/delete`** is the first user of `--delete-prefix`:

```bash
deletes=()
for dir in $(_task_collect_descendant_dirs …) "$(_path_task_dir "$suffix")"; do
  deletes+=(--delete-prefix "$dir")
done
_task_commit_on_branch "$repo" "$parent_bookmark" "$msg" \
  --modify "$parent_task_file" "${deletes[@]}" \
  -- _write_parent_without_subtask "$task_id"
```

Bookmark deletion (`_vcs_delete_bookmark`) and worktree removal (`_vcs_forget_worktree` +
`_worktree_delete`) follow the write, unchanged in ordering. `pre-delete` / `post-delete` still fire
at the same points.

`task/delete`'s clean-working-copy precondition is removed (it served the dance); its `--force`
semantics for the *other* safety checks — task status, descendants — are untouched.

---

### 5.12 Step C3 — Migrate checkin and publish to handoff-plus-merge

**Commands:** `task/checkin`, `task/publish`.

Both follow architecture §8 exactly. Merge commits never carry file writes:

```bash
handoff="$(_task_commit_on_branch "$repo" "$child_branch" "$handoff_message" …)"
merge="$(_vcs_create_merge_commit "$repo" "$checkin_message" "$parent_branch" "$handoff")"
_vcs_check_has_conflicts "$repo" "$merge" && { abort unless --force; }
_vcs_set_bookmark "$repo" "$parent_branch" "$merge"
_worktree_reattach_current "$repo" "$old_parent_tip" "$merge"
```

Git plumbing therefore only ever constructs linear commits; merges are delegated to the backend,
which computes the merged tree and represents conflicts natively.

**`task/checkin` specifics**

- The handoff commit writes: the parent task file (subtask checkbox → `[x]`, plus any `context:`
  entries carried up), and reverts the repo-root `TASK.md` symlink. Symlinks round-trip through the
  bare write as mode `120000` (B2 scenario 9).
- **`task/checkin` keeps its clean-working-copy precondition** (D11) — it validates the unmerged
  range for stray task-file modifications, which is a real semantic requirement, not a dance artifact.
- `_task_assert_bookmark_current` is unchanged.
- `pre-checkin` (blocking) and `post-receive` (non-blocking) fire at the same points.
- **`@` no longer lands on the merge commit** (D22). This is the intended correction called out in
  architecture §13: checkin should affect the target branch, not the invoking worktree.

**`task/publish` specifics**

- The handoff commit removes the repo-root `TASK.md` and the whole `.tt/task/` tree. Under D8 there is
  no recursive deletion, so this is `--delete-prefix "$(_path_task_root)"` plus
  `--delete "$TT_TASK_SYMLINK_FILENAME"`, with the prefix expanded to exact paths by
  `_vcs_list_files_at_revision`.
- Its clean-working-copy precondition is **removed** — unlike checkin, publish performs no unmerged
  range validation.
- `@` no longer returns to the project branch; it does not move.

---

### 5.13 Step C4 — Migrate move and propagate to bare graph operations

**Commands:** `task/move`, `task/propagate`.

**`task/move`** becomes two `_task_commit_on_branch` calls plus one graph operation:

```
old parent:  --modify <old parent task file>  --delete-prefix <task stub dir>
                 -- _write_parent_without_subtask
new parent:  --modify <new parent task file>
                 -- _write_parent_with_subtask_and_stub
graph:       _vcs_move_commits REPO <range roots> <new parent>
```

The stub currently copied via `jj_show_at_revision` into the working copy is instead read with
`_vcs_read_file_at_revision` and written into the staging directory.

**`task/move` keeps its clean-working-copy precondition** (D11): it carries `@` through a rebase of
the task's unmerged range.

**`task/propagate`** is already almost bare — its writes are graph-only. The work is:

- Replace `jj rebase -s roots(…) -d …` with `_vcs_list_range_roots` + `_vcs_move_commits`.
- Replace `jj new <child> <parent>` merges with `_vcs_create_merge_commit` + `_vcs_set_bookmark`.
- **Delete all three best-effort restores** of the form `jj edit "$original_rev" 2>/dev/null || true`
  (audit hazard 2). Under D22 there is nothing to restore, because `@` never moved.
- Give the two `jj bookmark set` calls that omitted `-r` their explicit revision (already done in A3;
  verify).
- Its resume-commit logic and idempotency checks are unchanged in behaviour.

`task/propagate` has no clean-working-copy precondition today and gains none (architecture §6.2).

---

### 5.14 Step C5 — Migrate task rename to two-phase tree rewriting

**Command:** `task/rename`. The hardest step; migrated last among the writers.

**Algorithm** (architecture §9, adopted verbatim):

```
refuse if any FOREIGN worktree's working-copy commit lies in the rewrite set   (D23)

rewrite set ← descendants of the commit that INTRODUCED the task directory:
                 _vcs_list_commits_in_range over roots(files("<old-prefix>"))

Phase 0 — reads only, no mutation:
  for each commit C in the set:
      read C's tree from the ORIGINAL stored objects
      rewrite paths under the old prefix to the new prefix
      retarget any symlink whose target points into the old prefix
      rewrite the parent task file's subtask reference
      write the result as a detached staging commit; record it against C's CHANGE ID
  import every staging commit in one step

Phase 1 — rewrite in place, oldest first, addressed by CHANGE ID:
  for each commit C in the set:
      _vcs_restore_tree REPO <staging commit for C> C

_vcs_rename_bookmark REPO <old-id> <new-id>
abandon the staging commits and drop their temporary refs
refresh the current worktree from inside itself
```

**Why the rewrite set is defined this way.** Two narrower definitions were tried during design and
rejected: *descendants of the parent bookmark tip* misses the task branch whenever the parent has
advanced past the fork point; *the task's unmerged range* leaves trailing commits and the working-copy
commit holding a diff that **undoes the rename**, so the next checkpoint would push the old paths back
onto the branch.

**Why two phases.** Computing every target tree up front, from the original objects, means nothing in
Phase 1 reads state that Phase 1 itself has disturbed. Consequently the current pre-save step
(`jj_show_at_op` reading at a captured operation ID) is **deleted entirely** — it exists only because
the in-place `jj edit` loop destroys the content it later needs.

**Change IDs, not commit IDs.** Each rewrite rebases the remainder of the set and invalidates their
commit IDs. bash 3.2 has no associative arrays (D19), so the change-ID → staging-commit mapping is
held as files in a scratch directory: `"$scratch/map/$change_id"` containing the staging commit ID.

**Foreign-worktree refusal (D23).** Message per §3:

```
Error: Cannot rename while other worktrees hold commits in the rewrite range:
  <path> (<task-id>)
  …

Rewriting these would discard uncommitted work in those worktrees. Resolve each first:
  tt worktree sync <path>
  tt worktree delete <path>

(--force does not override this check.)
```

The refusal must leave the repository **completely unmodified** — it runs before
`_history_begin_transaction`.

**`task/rename` keeps its clean-working-copy precondition** (D11): it carries `@` through a repeated
rewrite of the whole task range.

**Test scenarios** — `task/rename.test.sh` covers the three topologies exercised during design, and
for each asserts every outcome from architecture §9.5:

| Topology | Assertions |
| --- | --- |
| A freshly forked task | every change ID in the graph unchanged; no commit contains a path under the old prefix; no task file references the old task ID; root `TASK.md` symlink retargeted and still a symlink; the working-copy commit's diff is empty; zero conflicts; no staging bookmarks or refs survive |
| A task with trailing commits beyond its bookmark, plus a context file | as above, plus: the trailing commits carry no rename-reverting diff |
| A task whose parent advanced past the fork point, with a sibling branch present | as above, plus: the sibling's inherited copy of the parent task file no longer references the old ID; non-task content and its incremental history are untouched |

Plus: the refusal fires when a foreign worktree's `@` is in the set, names each blocking worktree,
leaves the repository unmodified, and leaves that worktree's un-snapshotted files intact; and
`--force` does **not** bypass it.

---

### 5.15 Step C6 — Route working-copy-bound commands through the backend

**Commands:** `task/checkpoint`, `task/checkout`, `workspace/init`.

These three legitimately require a working copy (D14). They keep their current shape; the change is
that every `jj` invocation is replaced by a **restricted** `_vcs_*` operation, and each is documented
as working-copy-bound in its header and in `ARCHITECTURE.md`.

**Restricted operations used** (architecture §4, "Working copy — restricted"). They take a **worktree
root** and execute with the process working directory inside it:

```
_vcs_snapshot_worktree WORKTREE          _vcs_get_working_copy_revision WORKTREE
_vcs_get_working_copy_parent WORKTREE    _vcs_check_working_copy_clean WORKTREE
_vcs_set_working_copy_revision WORKTREE REV
_vcs_commit_working_copy WORKTREE MESSAGE
_vcs_squash_working_copy WORKTREE FROM_REV
_vcs_reattach_worktree WORKTREE FROM_REV DEST_REV
```

**`task/checkpoint`** gains `_worktree_ensure_working_copy` — **no exemption** (D10). Amending a
branch tip is not what a checkpoint means. Its existing requirement that there be work to snapshot is
retained (D11). Its `--squash` path becomes `_vcs_squash_working_copy`.

**`task/checkout`** keeps its clean-working-copy precondition and `--force` bypass. `jj workspace add`
becomes `_vcs_create_worktree`; the symlink and status write remain on-disk operations, because
populating a worktree is the point of the command. The `jj bookmark set` that omitted `-r` gets its
explicit revision.

**`workspace/init`** keeps `_vcs_commit_working_copy`. It still opens no transaction — there is no
history file to record into until it has created one.

---

### 5.16 Step C7 — Add `tt worktree sync`; migrate worktree and history commands

**New command:** `scripts/cli/worktree/sync`, with `scripts/cli/worktree/sync.test.sh`.

```
tt worktree sync [<worktree-path>] [--all] [--repo PATH]
```

**Behaviour** (requirements §7.1, amended by D28):

- Brings a worktree forward onto the head of the branch it is checked out on, updating its working
  copy to match. Uncommitted changes are snapshotted before the move and are preserved.
- With no argument, targets the worktree containing the current working directory; errors if the CWD
  is not within a known worktree.
- With `--all`, synchronizes every out-of-sync worktree in the repository, entering each in turn,
  reporting conflicts and continuing, exiting non-zero if any failed.
- Errors if the given path is not a known worktree of the repository.
- Reports what changed (files added, modified, removed), or that the worktree was already up to date.
- Runs within a transaction.
- **Fires no hooks** (D28). State this explicitly in the `usage()` text and in DESIGN.md so the
  omission reads as deliberate.

It is the sole mechanism for bringing a behind worktree forward, and is safe by construction because
it runs inside the target worktree — the snapshot protects that worktree's uncommitted work exactly
as it does for any other command.

**Also in this step**

- `worktree/delete` — `jj workspace forget` → `_vcs_forget_worktree`; `rm -rf` → `_worktree_delete`.
  Its clean-working-copy precondition is **retained**: it protects against deleting a worktree with
  unsaved work, which is real semantics, not a dance artifact.
- `worktree/switch` — already mutates only the `.tt/workspace` symlink; route its `jj workspace root`
  through `_vcs_resolve_worktree_root`. Continues to fire `pre-checkout` / `post-checkout`.
- `history/undo` — `jj op restore` → `_vcs_restore_operation`.
- `history/unlock` — `op log` → `_vcs_get_operation_id`.

**`tt` dispatcher** — register `worktree sync` and add it to the command list in `usage()`.

---

### 5.17 Step C8 — Migrate read-only commands and close the layering

**Commands:** `task/revset`, `task/diff`, `task/changelog`, `task/tree`, `task/show`, `task/current`,
`task/parent`, `task/prompt`, `task/select`, `task/context/get`, `task/context/list`,
`worktree/list`, `worktree/show`, `worktree/active`, `workspace/repo`, `workspace/root`.

Each has its direct `jj` invocations replaced by the `_vcs_*` operations added in B1. No behavioral
change is expected in any of them, so **their suites must pass unmodified**; a required assertion
change in this step is a defect.

**`task/revset` — the one interface change** (requirements §7.4). The external surface is unchanged:
`--git` still selects a commit-ID range and its absence still selects the backend-native range
expression. Internally the flag selects a required `<native|git>` format argument:

```bash
_vcs_format_revision_range "$repo" "$format" "$from" "$to"    # format: native | git
```

so the syntax of each form is owned by the backend rather than the command.

**`task/diff`** drops the inline fileset assembly left in place by A2 and calls
`_vcs_show_diff REPO FROM TO [EXCLUDE...]`, passing the records from `_path_metadata_exclusions`.

**Final layering audit — the gate for this commit.** All six must hold:

```bash
# AC1a: no file outside lib/vcs/ invokes jj or git
grep -rnE '(^|[^a-zA-Z0-9_./-])(jj|git) ' scripts/cli --include='*' \
  | grep -v '^scripts/cli/lib/vcs/' | grep -v '\.test\.sh:'          # must be empty

# AC1b: no file outside lib/ calls a _vcs_ function
grep -rn '_vcs_' scripts/cli | grep -v '^scripts/cli/lib/'           # must be empty

# AC2: no revset or template syntax outside the backend
grep -rnE 'ancestors\(|descendants\(|roots\(|heads\(|fork_point\(|first_ancestors\(|commit_id|change_id|local_bookmarks' \
  scripts/cli --include='*' | grep -v '^scripts/cli/lib/vcs/jj.sh'   # must be empty

# AC3: every library function is namespaced and lives in its own module
for m in ui string format path frontmatter commit hook vcs history task workspace worktree; do
  grep -hoE '^_[a-z]+_[a-z0-9_]*\(\)' "scripts/cli/lib/$m.sh" | grep -v "^_${m}_"
done                                                                  # must be empty

# AC4: common.sh contains only source directives
grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{' scripts/cli/lib/common.sh   # must be 0

# AC5: the dance is gone
grep -rn 'write_and_commit_on_branch\|jj edit\|_vcs_set_working_copy_revision' scripts/cli \
  | grep -v 'lib/vcs/jj.sh' | grep -v 'checkpoint\|checkout\|workspace/init\|worktree/sync'
                                                                      # must be empty

# AC6: every backend function takes the repo first and honours TT_VERBOSE
grep -n '^_jj_' scripts/cli/lib/vcs/jj.sh                             # review by hand
```

**Also in this step:** run the full suite twice — once normally, once with `TT_VERBOSE=1` — and
confirm the results are identical, proving the variable affects diagnostics only (D16).

---

### 5.18 Step D1 — Documentation

**`ARCHITECTURE.md`** (new, repository root):

1. The four layers, with the call-rule table from requirements §3.1.
2. The `_<namespace>_<verb>[_<noun>]` naming rule, with the intent-not-mechanism principle.
3. The module inventory, one line of responsibility each, in load order.
4. **The full backend contract** — every operation a backend must implement, grouped as Repository,
   Operation log, Revisions, Bookmarks, Files, Mutations, Worktrees, Working copy (restricted), with
   signature and return value. Generate the list from `lib/vcs.sh` so it cannot drift.
5. The bare write mechanism, including the `git_target`-relative-to-`.jj/repo/store/` and
   don't-pre-create-the-index constraints.
6. The working-copy rules: only-from-inside rewriting; the `@`-carries-a-bookmark invariant and why it
   is not folded into the transaction module; out-of-sync reporting.
7. The three working-copy-bound commands and why each is one.
8. The bash 3.2 constraint.

**`DESIGN.md`** — user-facing only:

| Section | Change |
| --- | --- |
| §5.5 Worktree | Add `tt worktree sync`, stating that it fires no hooks |
| §6.6 Checkin validation | Retain "Working copy is clean" — checkin still requires it |
| §6.1.1, §6.1.2, §6.4, §6.7, §6.9 | Remove the clean-working-copy precondition from `edit`, `context add/delete`, `complete`, `reorder`, `delete`, `publish` |
| §6.x, all mutating commands | Add the `@`-carries-a-bookmark refusal; state that `@` does not move |
| §6.5 Checkin and publishing | State that `@` no longer moves onto the merge commit |
| New subsection | The out-of-sync warning and the unsupported-backend error |

Internal layering is deliberately **excluded** from DESIGN.md.

**`DEVELOPER.md`** — add: the library module layout and load order; that per-module suites are
discovered automatically and how to filter to one (`scripts/test lib/vcs`); and `TT_VERBOSE=1`, with
an example of its output and the note that it never changes stdout or exit status.

**Module headers** were written with their modules in Phases A and B; in this step, verify each states
both its responsibility and its public surface, and that the surface matches reality.

---

### 5.19 Definition of done

Mapped to requirements §11. Each is a mechanical check where possible.

| # | Criterion | Verified by |
| --- | --- | --- |
| 1 | No file outside `lib/vcs/` invokes `jj`; no file outside `lib/` calls `_vcs_*` | C8 grep AC1a / AC1b |
| 2 | No revset or template outside `lib/vcs/jj.sh` | C8 grep AC2 |
| 3 | Every library function follows the naming convention and lives in its namespace's module | C8 grep AC3 |
| 4 | `common.sh` contains only `source` directives | C8 grep AC4 (also gated at A5) |
| 5 | All file-content mutations are bare; the dance and its machinery are gone except in the three documented commands | C8 grep AC5 |
| 6 | Every backend function takes the repo first, honours `TT_VERBOSE`, reports failure by exit status without logging or exiting | C8 review + `jj.test.sh` |
| 7 | `tt worktree sync` exists, is documented and is tested | C7 + D1 |
| 8 | Every module has a test suite; `jj.test.sh` meets the §8.2 coverage bar | file listing + B2/B3 scenario checklist |
| 9 | The full test suite passes, with every changed assertion justified | full parallel run + commit-message audit |
| 10 | `ARCHITECTURE.md` exists and documents layering, naming and the backend contract; DESIGN.md and DEVELOPER.md updated | D1 |

**Final verification before checkin**

```bash
RAMDISK=$(scripts/ramdisk create) && TT_TEST_ROOT=$RAMDISK scripts/test --parallel; \
  scripts/ramdisk destroy $RAMDISK
```

Then re-propagate from `project/bootstrap-cli-d35756ce`, re-run the full suite, and check in with
`tt task checkin`.
