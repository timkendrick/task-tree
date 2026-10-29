#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_task_delete__delete_completed_task() {
  setup_workspace "del-done"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true
  checkin_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$task_id" 2>&1) || exit_code=$?
  assert_success "delete succeeds" "$exit_code"
  assert_bookmark_not_exists "bookmark deleted" "$task_id"
  assert_no_subtask_entry "no subtask entry" "$proj_id" "$task_id"
}


test_task_delete__parent_body_fence_preserved() {
  setup_workspace "del-body-fence"
  # Parent's body documents a subtask entry inside a fenced code block. Removing
  # the deleted task's real frontmatter entry must not touch that body line.
  body=$(printf '%s\n' \
    'Subtask entries look like:' \
    '' \
    '```markdown' \
    '---' \
    'subtask: [ ] task/fake-99999999 Fake' \
    '---' \
    '```')
  proj_id=$(create_project "proj" "Project" "$body") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true
  checkin_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$task_id" 2>&1) || exit_code=$?
  assert_success "delete succeeds" "$exit_code"
  assert_bookmark_not_exists "bookmark deleted" "$task_id"

  parent_content=$(read_task_file "$proj_id" "$proj_id")
  assert_not_contains "real entry removed" "$parent_content" "subtask: [x] $task_id"
  assert_contains "body fence subtask line unchanged" "$parent_content" \
    'subtask: [ ] task/fake-99999999 Fake'
}


test_task_delete__delete_task_with_descendants() {
  setup_workspace "del-tree"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  parent=$(create_task "parent" "P") || true
  checkout_task "$parent" >/dev/null || true
  child=$(create_task "child" "C") || true
  checkout_task "$child" >/dev/null || true
  grandchild=$(create_task "gc" "GC") || true

  # Complete all leaf-first (checkout each before completing)
  checkout_task "$grandchild" >/dev/null || true
  complete_task >/dev/null || true
  checkout_task "$child" >/dev/null || true
  complete_task --force >/dev/null || true
  checkout_task "$parent" >/dev/null || true
  complete_task --force >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$parent" 2>&1) || exit_code=$?
  assert_success "delete with descendants" "$exit_code"
  assert_bookmark_not_exists "parent bookmark deleted" "$parent"
  assert_bookmark_not_exists "child bookmark deleted" "$child"
  assert_bookmark_not_exists "grandchild bookmark deleted" "$grandchild"
}


test_task_delete__non_done_task_fails() {
  setup_workspace "del-notdone"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$task_id" 2>&1) || exit_code=$?
  assert_failure "non-DONE delete rejected" "$exit_code"
}


test_task_delete__non_done_with_force_succeeds() {
  setup_workspace "del-force"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$task_id" --force 2>&1) || exit_code=$?
  assert_success "--force delete succeeds" "$exit_code"
  assert_bookmark_not_exists "bookmark deleted" "$task_id"
}


test_task_delete__dirty_wc_preserved_not_absorbed() {
  setup_workspace "del-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true

  # Dirty WC: the bare branch write must neither reject nor absorb it
  edit_file "dirty-file.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt task delete "$task_id" 2>&1) || exit_code=$?
  assert_success "delete succeeds with dirty WC" "$exit_code"
  assert_bookmark_not_exists "bookmark deleted" "$task_id"
  assert_no_subtask_entry "no subtask entry" "$proj_id" "$task_id"
  assert_file_exists "dirty file still on disk" "$REPO/dirty-file.txt"
  assert_wc_dirty "WC still dirty"
  assert_file_not_on_branch "dirty file not on parent branch" "$proj_id" "dirty-file.txt"
}


test_task_delete__refuses_bookmark_on_working_copy() {
  setup_workspace "del-bm-refusal"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true

  # Clean working copy carrying the task's own bookmark
  jj -R "$REPO" bookmark set "$task_id" -r '@' >/dev/null 2>&1
  output="" exit_code=0
  output=$(run_tt task delete "$task_id" 2>&1) || exit_code=$?
  assert_failure "own bookmark on @ refused" "$exit_code"
  assert_contains "error names the bookmark" "$output" "tip of bookmark"
  assert_bookmark_exists "bookmark not deleted" "$task_id"

  # Bookmark unrelated to the branches involved in the deletion
  jj -R "$REPO" bookmark set "$task_id" -r '@-' --allow-backwards >/dev/null 2>&1
  jj -R "$REPO" bookmark set unrelated -r '@' >/dev/null 2>&1
  exit_code=0
  output=$(run_tt task delete "$task_id" 2>&1) || exit_code=$?
  assert_failure "unrelated bookmark on @ refused" "$exit_code"
  assert_contains "error names the unrelated bookmark" "$output" "unrelated"
  assert_bookmark_exists "bookmark still not deleted" "$task_id"
}


test_task_delete__working_copy_commit_stays_put() {
  setup_workspace "del-wc-stays"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true

  # Deleting task_b writes to the parent branch, which is not in @'s ancestry
  # line: @ must be entirely untouched (identical commit ID).
  wc_before=$(get_wc_commit)
  run_tt task delete "$task_b" --force >/dev/null 2>&1 || true
  wc_after=$(get_wc_commit)
  assert_eq "@ commit unchanged after cross-branch delete" "$wc_after" "$wc_before"
  assert_bookmark_not_exists "deleted bookmark gone" "$task_b"
  assert_no_subtask_entry "no subtask entry for deleted task" "$proj_id" "$task_b"
}


test_task_delete__parentless_task_fails() {
  setup_workspace "del-parentless"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task delete "$proj_id" 2>&1) || exit_code=$?
  assert_failure "parentless delete rejected" "$exit_code"
}


test_task_delete__records_transaction() {
  setup_workspace "del-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true
  checkin_task "$task_id" >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task delete "$task_id" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after delete"
}


test_task_delete__help() {
  setup_workspace "delete-help"
  output="" exit_code=0
  output=$(run_tt task delete --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task delete"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_required_usage_argument "argument: --force" "$output" "--force"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


test_task_delete__refuses_when_the_canonical_workspace_is_stale() {
  setup_workspace "delete-stale-canonical"
  setup_stale_canonical "deleted"

  assert_refuses_stale_canonical "$STALE_WORKTREE" \
    task delete "$STALE_TASK_ID" --force
}

test_task_delete__ancestor_write_leaves_the_worktree_on_its_task() {
  setup_workspace "delete-ancestor-worktree"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  sibling_id=$(create_task "sib" "Sibling") || true
  task_id=$(create_task "t" "T") || true
  local task_wt
  task_wt=$(create_task_worktree "$task_id")

  local fork_status=0
  is_vcs_ancestor "$proj_id" "$task_id" || fork_status=$?
  assert_success "the project tip is an ancestor of the task worktree" "$fork_status"
  local wt_parent_before proj_before
  wt_parent_before="$(jj -R "$task_wt" --ignore-working-copy log -r '@-' --no-graph -T 'commit_id' 2>/dev/null)"
  proj_before="$(get_bookmark_commit "$proj_id")"

  local exit_code=0
  run_tt_in_worktree "$task_wt" task delete "$sibling_id" --force \
    >/dev/null 2>&1 || exit_code=$?
  assert_success "delete succeeds" "$exit_code"
  assert_neq "the project branch advanced" "$(get_bookmark_commit "$proj_id")" "$proj_before"
  assert_eq "the worktree is still on its task" \
    "$(run_tt_in_worktree "$task_wt" task current 2>/dev/null)" "$task_id"
  assert_eq "the worktree has not moved" \
    "$(jj -R "$task_wt" --ignore-working-copy log -r '@-' --no-graph -T 'commit_id' 2>/dev/null)" \
    "$wt_parent_before"
}


# ---------------------------------------------------------------------------
# Working-copy guards
# ---------------------------------------------------------------------------

test_task_delete__refuses_uncheckpointed_commits_for_the_current_task() {
  setup_workspace "delete-guard-uncp"
  setup_working_copy_guard_fixture
  commit_uncheckpointed_work

  assert_refuses_without_writing "implicit task, even with --force" \
    "has commits after the task bookmark '$GUARD_TASK_ID'" \
    task delete --force
}

test_task_delete__explicit_task_id_skips_the_uncheckpointed_commits_check() {
  setup_workspace "delete-guard-uncp-explicit"
  setup_working_copy_guard_fixture
  commit_uncheckpointed_work

  local exit_code=0
  run_tt task delete "$GUARD_TASK_ID" --force >/dev/null 2>&1 || exit_code=$?
  assert_success "explicit task ID proceeds" "$exit_code"
  assert_subtask_count "task removed from parent" "$GUARD_PROJ_ID" 0
}

test_task_delete__refuses_uncommitted_task_metadata_edits() {
  setup_workspace "delete-guard-meta"
  setup_working_copy_guard_fixture
  complete_task >/dev/null 2>&1 || true
  edit_task_file "$GUARD_TASK_ID"

  assert_refuses_without_writing "task file edited by hand" \
    "has uncommitted changes to task metadata" \
    task delete "$GUARD_TASK_ID"
}

test_task_delete__force_skips_the_task_metadata_check() {
  setup_workspace "delete-guard-meta-force"
  setup_working_copy_guard_fixture
  edit_task_file "$GUARD_TASK_ID"

  local exit_code=0
  run_tt task delete "$GUARD_TASK_ID" --force >/dev/null 2>&1 || exit_code=$?
  assert_success "--force proceeds" "$exit_code"
  assert_subtask_count "task removed from parent" "$GUARD_PROJ_ID" 0
}

run_tests "tt task delete"
