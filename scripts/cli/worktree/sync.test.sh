#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"

# ---------------------------------------------------------------------------
# Fixtures
#
# Every test needs the same starting position: a task checked out in its own
# worktree, and then a write to that task's branch made from somewhere else, so
# the worktree is left sitting on an older tip of the branch it is on. The
# write is `tt task context add`, which commits directly onto the named branch
# without touching any working copy — exactly the situation `tt worktree sync`
# exists to repair.
# ---------------------------------------------------------------------------

# Usage: advance_branch TASK_ID SLUG
# Adds a context file to TASK_ID's branch from outside its worktree. The branch
# bookmark advances by one commit that adds context/<SLUG>-<hex>.md and modifies
# the task's TASK.md, leaving every worktree on the branch behind.
advance_branch() {
  local task_id="$1" slug="$2"
  run_tt task context add "$task_id" --title "$slug" --slug "$slug" \
    <<< "context body" >/dev/null 2>&1
}

# Usage: worktree_parent WORKTREE
# Prints the full commit ID of the commit WORKTREE's working copy sits on,
# without disturbing the working copy itself.
worktree_parent() {
  jj -R "$1" --ignore-working-copy log -r '@-' --no-graph -T 'commit_id' 2>/dev/null
}

# Usage: task_dir WORKTREE TASK_ID
# Prints the path of TASK_ID's task directory inside WORKTREE.
task_dir() {
  printf '%s/.tt/task/%s' "$1" "${2#*/}"
}


test_worktree_sync__brings_behind_worktree_forward() {
  setup_workspace "sync-forward"
  local proj_id task_id wt
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_id=$(create_task "my-task" "My Task") || true
  wt=$(create_task_worktree "$task_id")

  # Uncommitted work in the worktree: an edit to a tracked file, plus a file
  # the repository has never seen. Both must survive the move.
  printf 'edited\n' > "$wt/README.md"
  printf 'fresh\n' > "$wt/untracked.txt"

  advance_branch "$task_id" "notes"

  local out exit_code=0
  out=$(run_tt worktree sync "$wt" 2>&1) || exit_code=$?
  assert_success "sync succeeds" "$exit_code"
  assert_contains "reports the sync" "$out" "Synced"
  assert_contains "names the branch" "$out" "$task_id"

  assert_eq "worktree now sits on the branch head" \
    "$(worktree_parent "$wt")" "$(get_full_commit_id "$task_id")"
  assert_file_exists "branch content materialized in the worktree" \
    "$(task_dir "$wt" "$task_id")/context"

  assert_eq "tracked-file edit preserved" "$(cat "$wt/README.md")" "edited"
  assert_file_exists "never-snapshotted file preserved" "$wt/untracked.txt"
  assert_eq "never-snapshotted content preserved" "$(cat "$wt/untracked.txt")" "fresh"
}


test_worktree_sync__reports_changed_files() {
  setup_workspace "sync-report"
  local proj_id task_id wt
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_id=$(create_task "my-task" "My Task") || true
  wt=$(create_task_worktree "$task_id")

  advance_branch "$task_id" "notes"

  local out exit_code=0
  out=$(run_tt worktree sync "$wt" 2>&1) || exit_code=$?
  assert_success "sync succeeds" "$exit_code"
  assert_contains "lists the added context file" "$out" "+ .tt/task/${task_id#*/}/context/notes-"
  assert_contains "lists the modified task file" "$out" "~ .tt/task/${task_id#*/}/TASK.md"
  assert_contains "summarizes the file counts" "$out" "1 added, 1 modified, 0 removed"
}


test_worktree_sync__second_sync_is_up_to_date() {
  setup_workspace "sync-uptodate"
  local proj_id task_id wt
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_id=$(create_task "my-task" "My Task") || true
  wt=$(create_task_worktree "$task_id")

  advance_branch "$task_id" "notes"
  run_tt worktree sync "$wt" >/dev/null 2>&1 || true

  get_history_lines; local hc_before="${#HISTORY_LINES[@]}"
  local out exit_code=0
  out=$(run_tt worktree sync "$wt" 2>&1) || exit_code=$?
  assert_success "second sync succeeds" "$exit_code"
  assert_contains "reports it was already current" "$out" "Already up to date"
  assert_not_contains "does not claim to have moved anything" "$out" "Synced"

  # Moving nothing records nothing: an undo entry here would revert to the
  # state the repository is already in, pushing the user's real previous
  # action one step further back in the undo history.
  get_history_lines
  assert_eq "no transaction recorded" "$((${#HISTORY_LINES[@]} - hc_before))" "0"
  assert_history_integrity "history after a no-op sync"
}


# A check-in followed by propagation leaves the receiving branch's worktree
# behind a merge, with every reparented sibling branch descending from that
# worktree's fork point. A sync must carry it onto its own branch's tip and not
# onto a sibling's, which would import unrelated work into it.
test_worktree_sync__parent_worktree_lands_on_its_own_branch() {
  setup_workspace "sync-after-propagate"
  local proj_id sibling incoming wt out exit_code=0
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  sibling=$(create_task "sib" "Sibling") || true
  incoming=$(create_task "incoming" "Incoming") || true

  checkout_task "$sibling" >/dev/null 2>&1 || true
  printf 'work\n' > "$REPO/sibling-work.txt"
  checkpoint_task "Sibling work" >/dev/null 2>&1 || true

  # The default workspace is left on the project branch, parked above its tip.
  checkout_task "$proj_id" >/dev/null 2>&1 || true

  wt=$(create_task_worktree "$incoming")
  printf 'work\n' > "$wt/incoming-work.txt"
  run_tt_in_worktree "$wt" task checkpoint -m "Incoming work" >/dev/null 2>&1 || true
  run_tt_in_worktree "$wt" task checkin --complete --propagate >/dev/null 2>&1 || true

  out=$(run_tt worktree sync "$REPO" 2>&1) || exit_code=$?
  assert_success "sync succeeds" "$exit_code"
  assert_contains "names the project branch" "$out" "$proj_id"
  assert_not_contains "does not name the sibling branch" "$out" "$sibling"
  assert_eq "project worktree sits on the project tip" \
    "$(worktree_parent "$REPO")" "$(get_full_commit_id "$proj_id")"
  assert_file_not_exists "the sibling's work was not imported" "$REPO/sibling-work.txt"
}


test_worktree_sync__all_synchronizes_every_behind_worktree() {
  setup_workspace "sync-all"
  local proj_id wt_a wt_b task_a task_b
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true

  task_a=$(create_task "task-a" "Task A") || true
  wt_a=$(create_task_worktree "$task_a")
  task_b=$(create_task "task-b" "Task B") || true
  wt_b=$(create_task_worktree "$task_b")

  advance_branch "$task_a" "notes-a"
  advance_branch "$task_b" "notes-b"

  local out exit_code=0
  out=$(run_tt worktree sync --all 2>&1) || exit_code=$?
  assert_success "--all succeeds" "$exit_code"
  assert_eq "first worktree on its branch head" \
    "$(worktree_parent "$wt_a")" "$(get_full_commit_id "$task_a")"
  assert_eq "second worktree on its branch head" \
    "$(worktree_parent "$wt_b")" "$(get_full_commit_id "$task_b")"
  assert_contains "reports the first worktree" "$out" "$task_a"
  assert_contains "reports the second worktree" "$out" "$task_b"
}


test_worktree_sync__all_continues_past_a_failure() {
  setup_workspace "sync-all-fail"
  local proj_id wt_a wt_b wt_c task_a task_b task_c
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true

  task_a=$(create_task "task-a" "Task A") || true
  wt_a=$(create_task_worktree "$task_a")
  task_b=$(create_task "task-b" "Task B") || true
  wt_b=$(create_task_worktree "$task_b")
  task_c=$(create_task "task-c" "Task C") || true
  wt_c=$(create_task_worktree "$task_c")

  advance_branch "$task_a" "notes-a"
  advance_branch "$task_b" "notes-b"
  advance_branch "$task_c" "notes-c"

  # Make one worktree impossible to snapshot without disturbing how it reads:
  # its position and branch are still resolvable (those reads never load the
  # working copy), so it is still listed as out of sync, but capturing its
  # on-disk state fails on the unreadable directory.
  mkdir -p "$wt_b/blocked"
  printf 'x\n' > "$wt_b/blocked/x.txt"
  chmod 000 "$wt_b/blocked"

  local out exit_code=0
  out=$(run_tt worktree sync --all 2>&1) || exit_code=$?
  chmod 755 "$wt_b/blocked"

  assert_failure "--all exits non-zero when a worktree fails" "$exit_code"
  assert_contains "names the failing worktree" "$out" "$wt_b"
  assert_eq "the worktree before the failure was still synced" \
    "$(worktree_parent "$wt_a")" "$(get_full_commit_id "$task_a")"
  assert_eq "the worktree after the failure was still synced" \
    "$(worktree_parent "$wt_c")" "$(get_full_commit_id "$task_c")"
}


test_worktree_sync__all_with_nothing_to_do() {
  setup_workspace "sync-all-clean"
  local proj_id
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true

  local out exit_code=0
  out=$(run_tt worktree sync --all 2>&1) || exit_code=$?
  assert_success "--all succeeds with nothing to sync" "$exit_code"
  assert_contains "reports that everything is current" "$out" "All worktrees are up to date"
}


test_worktree_sync__defaults_to_current_worktree() {
  setup_workspace "sync-default-cwd"
  local proj_id task_id wt
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_id=$(create_task "my-task" "My Task") || true
  wt=$(create_task_worktree "$task_id")

  advance_branch "$task_id" "notes"

  local out exit_code=0
  out=$(run_tt_in_worktree "$wt" worktree sync 2>&1) || exit_code=$?
  assert_success "sync with no argument succeeds inside a worktree" "$exit_code"
  assert_eq "the worktree containing the CWD was synced" \
    "$(worktree_parent "$wt")" "$(get_full_commit_id "$task_id")"
}


test_worktree_sync__no_argument_outside_worktree_fails() {
  setup_workspace "sync-no-arg-outside"
  local out exit_code=0
  out=$(run_tt_in_worktree "/tmp" worktree sync 2>&1) || exit_code=$?
  assert_failure "sync with no argument outside a worktree fails" "$exit_code"
  assert_contains "error message" "$out" "could not detect current worktree"
}


test_worktree_sync__unknown_path_rejected() {
  setup_workspace "sync-unknown-path"
  local out exit_code=0
  out=$(run_tt worktree sync "/tmp/nonexistent-worktree-path" 2>&1) || exit_code=$?
  assert_failure "unknown path rejected" "$exit_code"
  assert_contains "error mentions the worktree" "$out" "is not a worktree in this repository"
}


test_worktree_sync__all_with_path_is_a_usage_error() {
  setup_workspace "sync-all-and-path"
  local out exit_code=0
  out=$(run_tt worktree sync "$REPO" --all 2>&1) || exit_code=$?
  assert_failure "--all with a path rejected" "$exit_code"
  assert_contains "explains the conflict" "$out" "--all cannot be combined with a worktree path"
  assert_contains "shows usage" "$out" "Usage:"
}


test_worktree_sync__transaction_integrity() {
  setup_workspace "sync-transaction"
  local proj_id task_id wt
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_id=$(create_task "my-task" "My Task") || true
  wt=$(create_task_worktree "$task_id")

  advance_branch "$task_id" "notes"

  get_history_lines
  local before="${#HISTORY_LINES[@]}"

  local exit_code=0
  run_tt worktree sync "$wt" >/dev/null 2>&1 || exit_code=$?
  assert_success "sync succeeds" "$exit_code"

  assert_history_count "sync records exactly one transaction" $((before + 1))
  assert_history_integrity "history integrity after sync"
}


test_worktree_sync__help() {
  setup_workspace "sync-help"
  local out exit_code=0
  out=$(run_tt worktree sync --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$out" "tt worktree sync"
  assert_required_usage_argument "argument: [<worktree-path>]" "$out" "[<worktree-path>]"
  assert_required_usage_argument "argument: --all" "$out" "--all"
  assert_required_usage_argument "argument: --repo" "$out" "--repo"
}


# ---------------------------------------------------------------------------
# Staleness screening
# ---------------------------------------------------------------------------

test_worktree_sync__refuses_a_stale_target() {
  setup_workspace "sync-stale-target"
  local proj_id task_id wt
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_id=$(create_task "staletarget" "Stale target") || true
  wt=$(create_task_worktree "$task_id")
  advance_branch "$task_id" "notes"
  make_worktree_stale "$wt"

  local before_op
  before_op="$(get_jj_op_bare)"

  local out exit_code=0
  out=$(run_tt worktree sync "$wt" 2>&1) || exit_code=$?

  assert_failure "a stale target is refused" "$exit_code"
  assert_contains "the refusal names the stale worktree" "$out" \
    "Error: The workspace is stale: $wt"
  assert_contains "the refusal names the recovery command" "$out" "tt worktree refresh"
  assert_eq "nothing was synchronized" "$(get_jj_op_bare)" "$before_op"
}

test_worktree_sync__all_refuses_the_whole_run_when_any_target_is_stale() {
  setup_workspace "sync-all-stale"
  local proj_id task_ok task_bad wt_ok wt_bad
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_ok=$(create_task "healthy" "Healthy") || true
  wt_ok=$(create_task_worktree "$task_ok")
  task_bad=$(create_task "stale" "Stale") || true
  wt_bad=$(create_task_worktree "$task_bad")

  # Both worktrees are behind, so both are targets; only one is stale.
  advance_branch "$task_ok" "notes-ok"
  advance_branch "$task_bad" "notes-bad"
  local ok_parent_before
  ok_parent_before="$(worktree_parent "$wt_ok")"
  make_worktree_stale "$wt_bad"

  local out exit_code=0
  out=$(run_tt worktree sync --all 2>&1) || exit_code=$?

  assert_failure "--all refuses when any target is stale" "$exit_code"
  assert_contains "the refusal names the stale worktree" "$out" \
    "Error: The workspace is stale: $wt_bad"
  assert_contains "the run reports that nothing was synchronized" "$out" \
    "nothing was synchronized"
  assert_eq "the healthy worktree was NOT synced" \
    "$(worktree_parent "$wt_ok")" "$ok_parent_before"
}

test_worktree_sync__all_ignores_a_stale_worktree_that_is_not_behind() {
  setup_workspace "sync-all-stale-not-behind"
  local proj_id task_ok task_idle wt_ok wt_idle
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_ok=$(create_task "healthy" "Healthy") || true
  wt_ok=$(create_task_worktree "$task_ok")
  task_idle=$(create_task "idle" "Idle") || true
  wt_idle=$(create_task_worktree "$task_idle")

  # Only the healthy worktree is behind. The stale one never advanced, so it
  # is not a sync target and must neither block the run nor be reported.
  advance_branch "$task_ok" "notes-ok"
  make_worktree_stale "$wt_idle"

  local out exit_code=0
  out=$(run_tt worktree sync --all 2>&1) || exit_code=$?

  assert_success "a stale non-target does not block the run" "$exit_code"
  assert_not_contains "the stale non-target is not reported" "$out" "$wt_idle"
  assert_contains "the behind worktree was synced" "$out" "Synced $wt_ok"
}

run_tests "tt worktree sync"
