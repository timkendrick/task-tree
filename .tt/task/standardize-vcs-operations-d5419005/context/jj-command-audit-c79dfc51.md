---
title: "`jj` Command Audit"
created: 2026-08-28T13:54:20Z
updated: 2026-08-28T13:54:20Z
---

## Background: Feasibility of replacing `jj` working copy filesystem manipulations with 'bare' repository operations

Research question: The current project makes heavy use of jj workspaces to perform actions on 'foreign' task branches (e.g. for most command invocations where the `<task-id>` argument is explicitly specified).

The CLI commands typically achieve this by attempting to locate an existing 'canonical' jj workspace for a given task (based on whether a workspace currently has that task checked out, falling back to the current workspace if not), then performing changes on the target workspace's working copy, then (if using the current workspace as a fallback) returning to the original branch.

This is error prone as it the programmatic changes made by the tool can frequently collide with working copy changes the user had on that branch, etc.

It would be much better if the programmatic changes could be made as in-memory 'bare' jj repository operations, rather than manipulating the filesystem directly.

Is this something that is supported by jj? 

Answer: partially — and the gap has known workarounds

**Short version:** jj's *repo* layer is already fully in-memory/bare; the CLI just doesn't expose one operation you need — writing *new* file content into a commit. Everything else tt does can be done with zero working-copy involvement today.

I verified all of the below empirically against `jj 0.43.0` in a scratch repo, plus context7 docs.

---

## 1. What already needs no working copy

These operate on arbitrary revsets and never touch the filesystem. Add `--ignore-working-copy` to also skip snapshotting:

`jj describe -r`, `jj metaedit`, `jj bookmark set/create/move`, `jj new --no-edit -r/-A/-B`, `jj rebase`, `jj abandon`, `jj duplicate`, `jj squash --from X --into Y`, `jj restore --from X --into Y` (whole-file moves between revs), `jj op restore`.

From the explore agent's map, this covers most of `task/move`, `task/delete`, `task/reorder`, `task/propagate`, `history/undo`, and the graph half of `task/checkin` — the workspace dance there is largely unnecessary.

## 2. Editing *existing* files in a foreign commit — supported

`jj diffedit -r <rev> --tool <name>` with a non-interactive merge tool. jj materializes the diff into temp dirs, runs your script, reads back the right side. Verified:

```bash
jj diffedit -r "$task_bookmark" --tool tt \
  --config 'merge-tools.tt.program="/path/to/rewrite.sh"' \
  --config 'merge-tools.tt.edit-args=["$left","$right"]'
```

Result: `TASK.md` frontmatter rewritten in the target commit; the user's uncommitted `dirty.txt` in the current workspace was untouched. `jj fix --tool` is a second variant (stdin→stdout per file, explicitly documented as "without modifying the working copy").

**Verified limitation:** only paths present in the diff are materialized and read back. Creating `newfile.md` in `$right` was silently dropped; passing it as an explicit fileset gave `Warning: No matching entries for paths`. `--from root() --to <rev>` widens the set to the whole tree but still cannot *add*.

## 3. Creating new files — no CLI support, two workarounds

There is no `jj file write`. `jj file` is `annotate/chmod/list/search/show/track/untrack`.

**(a) Git plumbing into the backing store + import.** Your store is the git backend (`.jj/repo/store/type` = `git`). Verified end-to-end, no workspace touched:

```bash
GIT_DIR=<resolved .jj/repo/store/git_target>
blob=$(printf '%s' "$content" | git hash-object -w --stdin)
GIT_INDEX_FILE=$(mktemp -u) git read-tree "$parent_commit" \
  && git update-index --add --cacheinfo 100644,"$blob",.tt/task/new/TASK.md \
  && tree=$(git write-tree)
new=$(git commit-tree "$tree" -p "$parent_commit" -m "tt: write task file")
git update-ref refs/heads/tt-tmp "$new"
jj git import
jj squash --from tt-tmp --into "$task" --use-destination-message
jj bookmark forget tt-tmp
```

The file landed in the task commit, change ID preserved, user's dirty working copy intact. Caveats: git-backend-only, needs a temp ref, and the imported commit gets a throwaway change ID (hence the squash).

**(b) A tt-owned workspace.** `jj workspace add --sparse-patterns=empty` then `jj sparse set .tt/` gives a private working copy that materializes only task files. Still filesystem, but structurally immune to colliding with user edits — much safer than borrowing the user's workspace, and far less code than (a).

## 4. For the eventual Rust CLI

`jj-lib` is the real answer: `Transaction`/`MutableRepo`, `MergedTreeBuilder`, `CommitBuilder`, `Store::write_file` — build trees and commits entirely in memory, no `WorkingCopy` instantiated at all. jj's own docs state the tradeoff plainly: using jj-lib "avoids parsing command output and simplifies error handling, but its API is unstable."

## 5. Caveat that no approach removes

Rewriting a commit still rebases descendants, and if the target is another workspace's `@`, that workspace goes **stale** (`jj workspace update-stale`) and disk files under it change. That's inherent to the data model, not to the technique. What the bare approach *does* eliminate is the `jj edit`-and-restore round trip and the risk of committing the user's unrelated dirty files into a task commit.

---

# Audit: tt commands → jj commands

**Method:** static analysis of `scripts/cli/**` (excluding `*.test.sh`), parsing `lib/common.sh` into functions, resolving `tt` command → common.sh function → `jj` invocation transitively. Comments and heredoc/usage bodies stripped; `jj "${jj_opts[@]}" …` splat forms and the `trap 'tt_rollback_transaction …' ERR` edge resolved. Full JSON at `/tmp/audit.json`; script at `/tmp/tt_audit.py`.

## 1. The only 25 functions in `common.sh` that touch jj

| Function | jj command | Line |
|---|---|---|
| `jj_show_at_revision` | `file show` (`--ignore-working-copy`) | 14 |
| `jj_show_at_op` | `file show` (`--at-operation`) | 36 |
| `get_jj_op_id` | `op log` | 27 |
| `count_revs_in_revset` | `log` | 399 |
| `get_commit_description` | `log` | 406 |
| `is_wc_clean` | `log` | 414 |
| `has_conflicts` | `log` | 617 |
| `find_parent_branch` | `log` | 633 |
| `get_task_range_context` | `log` | 697 |
| `resolve_task_fork_point` | `log` | 747 |
| `get_full_task_range_records` | `log` | 919 |
| `_full_range_resolve_commit` | `log` | 947 |
| `_full_range_creation_boundary` | `log` | 974 |
| `_full_range_query_waypoints` | `log` | 996 |
| `_full_range_symlink_diff` | `log` | 1006 |
| `mainline_commit_records` | `log` | 1057 |
| `find_branch_for_task` | `log` | 1095 |
| `get_worktree_current_rev` | `log` | 1134 |
| `resolve_current_worktree` | `workspace root` | 1141 |
| `jj_workspace_list` | `workspace list` | 1187 |
| `resolve_current` | `log` | 1305 |
| `check_bookmark_up_to_date` | `log` | 1430 |
| `forget_worktree` | `workspace forget` | 1418 |
| `tt_rollback_transaction` | `op restore` | 1938 |
| **`write_and_commit_on_branch`** | **`log`, `edit`, `new`, `commit`, `bookmark set`** | 1224–1237 |

Everything else in the 2025-line file is pure string/file manipulation. **`write_and_commit_on_branch` is the only mutating function in the library** — every other jj-touching helper is read-only.

## 2. Command matrix

`*` = reached only transitively through `lib/common.sh`.

**Mutation-free (19 of 36):**

| Command | jj used |
|---|---|
| `task/changelog`, `task/current`, `task/parent`, `task/prompt`, `task/revset`, `task/select`, `task/tree`, `task/context/get`, `task/context/list` | `log`, `file show` |
| `task/diff` | `diff`, `log`, `file show` |
| `task/show` | `log`, `file show`, `workspace list` |
| `worktree/list`, `worktree/show`, `worktree/switch` | `workspace list`, `workspace root`, `log` |
| `history/unlock` | `op log` |
| `workspace/repo`, `workspace/root`, `worktree/active`, `tt` | none |

`worktree/switch` mutates only the `.tt/workspace` symlink (`perform_workspace_switch`) — no jj write.

**Mutating (17 of 36):**

| Command | mutating jj commands |
|---|---|
| `task/create` | `new`, `edit`, `describe`, `bookmark set`, `op restore*` |
| `task/edit` | `edit*`, `new*`, `commit*`, `bookmark set*`, `op restore*` |
| `task/context/add` | `edit*`, `new*`, `commit*`, `bookmark set*`, `op restore*` |
| `task/context/delete` | `edit*`, `new*`, `commit*`, `bookmark set*`, `op restore*` |
| `task/checkpoint` | `new`, `commit`, `squash`, `bookmark set`, `op restore*` |
| `task/checkin` | `new`, `commit`, `describe`, `bookmark set`, `workspace forget*`, `op restore*` |
| `task/checkout` | `workspace add`, `new`, `describe`, `bookmark set`, `op restore*` |
| `task/complete` | `new`, `commit`, `bookmark set`, `op restore*` |
| `task/publish` | `new`, `commit`, `describe`, `bookmark set`, `op restore*` |
| `task/delete` | `new`, `commit`, `bookmark set`, `bookmark delete`, `workspace forget`, `op restore*` |
| `task/move` | `new`, `describe`, `rebase`, `bookmark set`, `op restore*` |
| `task/propagate` | `new`, `edit`, `rebase`, `bookmark set`, `op restore*` |
| `task/rename` | `edit`, `new`, `commit`, `bookmark rename`, `bookmark set`, `op restore*` |
| `task/reorder` | `new`, `commit`, `bookmark set`, `op restore*` |
| `workspace/init` | `commit` |
| `worktree/delete` | `workspace forget*`, `op restore*` |
| `history/undo` | `op restore` |

Distinct jj surface used across the whole CLI (15 commands): `log`, `file show`, `file list`, `diff`, `op log`, `op restore`, `new`, `edit`, `commit`, `describe`, `squash`, `rebase`, `bookmark set/delete/rename`, `workspace add/forget/list/root`.

## 3. Central finding

Every file-content mutation in the CLI is the same five-step working-copy dance:

```
jj edit <bookmark>        # or: jj new <bookmark>
<write files on disk>
jj commit -m <msg>
jj bookmark set <bookmark> -r '@-'
jj new -r <original_rev>  # restore, cross-branch case only
```

It exists in **one library copy** (`common.sh:1215–1240`, used by `task/edit`, `task/context/add`, `task/context/delete`) and **eight hand-rolled duplicates**: `task/create:410–486`, `task/checkin:461–485`, `task/publish:291–319`, `task/complete:171–205`, `task/delete:272–319`, `task/reorder:253–362`, `task/rename:225–272`, `task/checkpoint:163–182`.

Two secondary hazards the audit surfaced:

- **`jj bookmark set` without `-r`** — `task/move:256,283`, `task/propagate:175,216`, `task/checkout:365`. Implicitly targets `@`, so correctness depends on the working copy sitting exactly where the previous step left it.
- **Best-effort restore** — `jj edit "$original_rev" 2>/dev/null || true` at `task/propagate:184,217,387` and `task/create:486`. The restore step is allowed to fail silently, leaving the user parked on a foreign branch.

Workspace resolution feeds this: `resolve_task_worktree` (6 callers) and `find_worktrees_for_branch` (6 callers) exist purely to decide *whose* working copy to hijack.

## 4. Audit summary

| Group | Commands | Bare feasibility |
|---|---|---|
| Already bare | all 19 read-only commands, `history/undo`, `worktree/delete` | done — add `--ignore-working-copy` where missing |
| Graph-only mutations | `task/move`, `task/propagate` (minus their `jj edit` restores), `bookmark set/rename/delete`, `describe` | **fully bare today** — needs `-r <rev>` on every `bookmark set`, then the `jj edit`/`jj new` restore steps disappear entirely |
| Content edits to existing files | `task/edit`, `task/context/delete`, `task/rename`, `task/reorder`, frontmatter updates in `checkin`/`complete`/`delete`/`publish` | **`jj diffedit -r --tool`** (verified working, no WC) |
| New-file creation | `task/create`, `task/context/add`, handoff files in `task/checkin` | no CLI support — needs git-plumbing + `jj squash --from/--into` (verified), a tt-owned sparse workspace, or jj-lib |
| Genuinely WC-bound | `task/checkpoint` (snapshots real user work), `task/checkout`, `workspace/init` | must stay as-is |

Roughly: 19 commands need no change, ~5 could be performed as 'bare' operations with a `-r` flag alone, ~7 need `diffedit`, and 3 need the new-file mechanism.

