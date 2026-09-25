#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_task_move__basic_reparenting() {
  setup_workspace "move-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "Task A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "Task B") || true
  checkout_task "$proj_id" >/dev/null || true

  # Move B under A
  output="" exit_code=0
  output=$(run_tt task move --task "$task_b" --parent "$task_a" 2>&1) || exit_code=$?
  assert_success "move succeeds" "$exit_code"

  # Old parent (project) no longer has B
  assert_no_subtask_entry "old parent loses subtask" "$proj_id" "$task_b"
  # New parent (A) now has B
  assert_subtask_entry "new parent gains subtask" "$task_a" "$task_b" "[ ]"
  # B is VCS descendant of A
  assert_is_ancestor "B descends from A" "$task_a" "$task_b"
}


test_task_move__cycle_detection() {
  setup_workspace "move-cycle"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  parent=$(create_task "p" "Parent") || true
  checkout_task "$parent" >/dev/null || true
  child=$(create_task "c" "Child") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task move --task "$parent" --parent "$child" 2>&1) || exit_code=$?
  assert_failure "cycle detected" "$exit_code"
}


test_task_move__same_parent_is_error() {
  setup_workspace "move-same"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task move --task "$task_id" --parent "$proj_id" 2>&1) || exit_code=$?
  assert_failure "same parent rejected" "$exit_code"
}


test_task_move__parentless_task_cannot_be_moved() {
  setup_workspace "move-parentless"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt task move --task "$proj_id" --parent "main" 2>&1) || exit_code=$?
  assert_failure "parentless move rejected" "$exit_code"
}


test_task_move__dirty_wc_rejected() {
  setup_workspace "move-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  checkout_task "$proj_id" >/dev/null || true
  edit_file "dirty.txt" "dirty"

  bm_before=$(get_bookmark_commit "$proj_id")

  output="" exit_code=0
  output=$(run_tt task move --task "$task_b" --parent "$task_a" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
  # Unlike the other branch writers, move keeps its clean-working-copy
  # precondition: it rebases the task's own line and the working copy may be
  # riding on it.
  assert_contains "clean working copy demanded" "$output" "Working copy has uncommitted changes"
  assert_file_exists "dirty file still on disk" "$REPO/dirty.txt"
  assert_wc_dirty "WC still dirty"
  bm_after=$(get_bookmark_commit "$proj_id")
  assert_eq "old parent bookmark unmoved" "$bm_after" "$bm_before"
  assert_subtask_entry "old parent keeps subtask" "$proj_id" "$task_b" "[ ]"
}


test_task_move__refuses_bookmark_on_working_copy() {
  setup_workspace "move-bm-refusal"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  checkout_task "$proj_id" >/dev/null || true

  # Clean working copy carrying a bookmark unrelated to either parent
  jj -R "$REPO" bookmark set unrelated -r '@' >/dev/null 2>&1

  bm_before=$(get_bookmark_commit "$proj_id")
  output="" exit_code=0
  output=$(run_tt task move --task "$task_b" --parent "$task_a" 2>&1) || exit_code=$?
  assert_failure "bookmark on @ refused" "$exit_code"
  assert_contains "error names the bookmark" "$output" "unrelated"
  bm_after=$(get_bookmark_commit "$proj_id")
  assert_eq "old parent bookmark unmoved" "$bm_after" "$bm_before"
  assert_subtask_entry "old parent keeps subtask" "$proj_id" "$task_b" "[ ]"
}


test_task_move__wc_on_moved_task_carries_through() {
  setup_workspace "move-wc-carry"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  checkout_task "$task_b" >/dev/null || true

  # @ sits on the branch being moved: the rebase of the task's unmerged range
  # carries it across to the new parent rather than leaving it behind.
  run_tt task move --task "$task_b" --parent "$task_a" >/dev/null 2>&1 || true

  assert_current_task "WC still on the moved task" "$task_b"
  assert_is_ancestor "moved task descends from new parent" "$task_a" "$task_b"
  assert_wc_clean "WC clean after carry-through"
  # The on-disk working copy must have travelled with the commits, not been
  # left pointing at the pre-rebase tree.
  output="" exit_code=0
  output=$(jj -R "$REPO" status 2>&1) || exit_code=$?
  assert_success "working copy is usable after move" "$exit_code"
  assert_not_contains "working copy not stale" "$output" "stale"
}


test_task_move__graph_shape() {
  setup_workspace "move-graph"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true

  # Give B a commit of its own so the reparented range is more than its stub.
  checkout_task "$task_b" >/dev/null || true
  edit_file "$REPO/b-work.txt" "work"
  checkpoint_task "B work" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  old_parent_before=$(get_full_commit_id "$proj_id")
  new_parent_before=$(get_full_commit_id "$task_a")
  b_range_before=$(count_commits "${old_parent_before}..${task_b}")

  run_tt task move --task "$task_b" --parent "$task_a" >/dev/null 2>&1 || true

  # Exactly one new commit on each parent branch.
  assert_revset_count "old parent gained one commit" \
    "${old_parent_before}::${proj_id}" 2
  assert_revset_count "new parent gained one commit" \
    "${new_parent_before}::${task_a}" 2

  # ...carrying the expected file changes.
  task_file=".tt/task/${task_b#task/}/TASK.md"
  proj_file=".tt/task/${proj_id#project/}/TASK.md"
  a_file=".tt/task/${task_a#task/}/TASK.md"
  assert_eq "old parent commit touches its own task file and the stub" \
    "$(get_modified_files "$proj_id" | sort | tr '\n' ' ')" \
    "$(printf '%s\n%s\n' "$proj_file" "$task_file" | sort | tr '\n' ' ')"
  assert_eq "new parent commit touches its own task file and the stub" \
    "$(get_modified_files "$task_a" | sort | tr '\n' ' ')" \
    "$(printf '%s\n%s\n' "$a_file" "$task_file" | sort | tr '\n' ' ')"
  assert_file_not_on_branch "stub gone from old parent" "$proj_id" "$task_file"
  assert_file_on_branch "stub present on new parent" "$task_a" "$task_file"

  # The task's range is intact and now hangs off the new parent's tip.
  assert_revset_count "range preserved onto new parent" \
    "${task_a}..${task_b}" "$b_range_before"
  assert_is_ancestor "new parent tip is an ancestor of the task" "$task_a" "$task_b"
  assert_not_ancestor "old parent tip is not an ancestor of the task" \
    "$proj_id" "$task_b"
  assert_no_conflicts "no conflicts after reparenting"
}


test_task_move__wc_on_old_parent_stays_on_old_parent() {
  setup_workspace "move-wc-old"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  checkout_task "$proj_id" >/dev/null || true

  run_tt task move --task "$task_b" --parent "$task_a" >/dev/null 2>&1 || true
  assert_current_task "WC on old parent" "$proj_id"
}


test_task_move__records_transaction() {
  setup_workspace "move-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  checkout_task "$proj_id" >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task move --task "$task_b" --parent "$task_a" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after move"
}


test_task_move__no_conflicts_after_reparent() {
  setup_workspace "move-noconflict"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  checkout_task "$proj_id" >/dev/null || true

  run_tt task move --task "$task_b" --parent "$task_a" >/dev/null 2>&1 || true
  assert_no_conflicts "no conflicts after move"
}


test_task_move__help() {
  setup_workspace "move-help"
  output="" exit_code=0
  output=$(run_tt task move --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task move"
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --parent" "$output" "--parent"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


test_task_move__refuses_when_the_canonical_workspace_is_stale() {
  setup_workspace "move-stale-canonical"
  # A move to the parent the task already has is rejected before any
  # precondition runs, so the task needs somewhere else to go.
  local other_proj
  other_proj="$(create_project "other-moved" "Other project")"
  setup_stale_canonical "moved"

  assert_refuses_stale_canonical "$STALE_WORKTREE" \
    task move --task "$STALE_TASK_ID" --parent "$other_proj"
}

run_tests "tt task move"
