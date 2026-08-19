#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"

test_task_checkin__basic_checkin_of_completed_task() {
  setup_workspace "ci-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task checkin "$task_id" 2>&1) || exit_code=$?
  assert_success "checkin succeeds" "$exit_code"
  assert_subtask_entry "parent [x]" "$proj_id" "$task_id" "[x]"
  assert_current_task "WC on parent" "$proj_id"
  assert_no_conflicts "no conflicts"
  assert_history_integrity "history after checkin"
}


test_task_checkin__parent_body_fence_preserved() {
  setup_workspace "ci-body-fence"
  # Parent's body documents a subtask entry inside a fenced code block. The
  # rewrite of the parent's real frontmatter must leave that body line intact.
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

  output="" exit_code=0
  output=$(run_tt task checkin "$task_id" 2>&1) || exit_code=$?
  assert_success "checkin succeeds" "$exit_code"
  assert_subtask_entry "real entry flipped to [x]" "$proj_id" "$task_id" "[x]"

  parent_content=$(read_task_file "$proj_id" "$proj_id")
  assert_contains "body fence subtask line unchanged" "$parent_content" \
    'subtask: [ ] task/fake-99999999 Fake'
  assert_no_conflicts "no conflicts"
}


test_task_checkin__partial_in_progress() {
  setup_workspace "ci-partial"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Partial" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task checkin "$task_id" 2>&1) || exit_code=$?
  assert_success "partial checkin" "$exit_code"
  assert_subtask_entry "parent [-]" "$proj_id" "$task_id" "[-]"
}


test_task_checkin__with_complete() {
  setup_workspace "ci-complete"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  run_tt task checkin --complete "$task_id" >/dev/null 2>&1 || true
  assert_task_status "DONE" "$task_id" "DONE"
  assert_subtask_entry "parent [x]" "$proj_id" "$task_id" "[x]"
}


test_task_checkin__with_delete() {
  setup_workspace "ci-delete"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  run_tt task checkin --delete "$task_id" >/dev/null 2>&1 || true
  assert_bookmark_not_exists "bookmark deleted" "$task_id"
  assert_no_subtask_entry "no subtask entry" "$proj_id" "$task_id"
}


test_task_checkin__with_complete_and_delete() {
  # --delete requires DONE, but --complete marks the task DONE as part of the same
  # command, so the two flags must work together.
  setup_workspace "ci-complete-delete"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task checkin --complete --delete "$task_id" 2>&1) || exit_code=$?
  assert_success "checkin --complete --delete succeeds" "$exit_code"
  assert_bookmark_not_exists "bookmark deleted" "$task_id"
  assert_no_subtask_entry "no subtask entry" "$proj_id" "$task_id"
}


test_task_checkin__delete_without_complete_rejected() {
  setup_workspace "ci-delete-not-done"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task checkin --delete "$task_id" 2>&1) || exit_code=$?
  assert_failure "--delete on non-DONE task rejected" "$exit_code"
  assert_contains "error mentions DONE requirement" "$output" "--delete requires task status to be DONE"
  assert_bookmark_exists "bookmark retained" "$task_id"
}


test_task_checkin__project_branch_rejected() {
  setup_workspace "ci-project"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task checkin "$proj_id" 2>&1) || exit_code=$?
  assert_failure "project checkin rejected" "$exit_code"
  assert_contains "suggests publish" "$output" "publish"
}


test_task_checkin__not_on_task_branch_without_id_fails() {
  # Use a fresh workspace with no task checkouts so resolve_current finds no task ancestor
  setup_workspace "ci-notask"
  output="" exit_code=0
  output=$(run_tt task checkin 2>&1) || exit_code=$?
  assert_failure "checkin with no tasks fails" "$exit_code"
}


test_task_checkin__single_transaction() {
  setup_workspace "ci-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after checkin"
}


test_task_checkin__head_no_symlink_loop_when_working_from_head_directory() {
  # Regression: when the user works from inside the HEAD-linked directory
  # (e.g. their editor opens /virtual/HEAD which symlinks to a real worktree),
  # find_repo_root resolves $repo to the symlink path /virtual/HEAD via `pwd`
  # rather than the real worktree path. This causes find_worktrees_for_branch
  # to fall back to $repo (= /virtual/HEAD) as target_ws, and
  # perform_workspace_switch then sets HEAD -> /virtual/HEAD, a self-referential
  # loop that breaks all subsequent tt commands.
  setup_workspace "ci-symlink-loop"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # Create a sibling task so --propagate has work to do after checkin
  create_task "sibling" "Sibling" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  # Create the task under test
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  # Run checkin from inside the HEAD symlink directory, without TT_REPO set,
  # so find_repo_root resolves $repo via `pwd` to the symlink path.
  local head_path="$VIRTUAL/HEAD"
  output="" exit_code=0
  output=$(cd "$head_path" && unset TT_REPO && "$TT" task checkin --complete --propagate --switch "$task_id" 2>&1) || exit_code=$?
  assert_success "checkin --complete --propagate --switch succeeds" "$exit_code"

  local head_target
  head_target="$(readlink "$VIRTUAL/HEAD")"
  assert_neq "HEAD does not point to itself" "$head_target" "$head_path"
}


test_task_checkin__head_symlink_is_absolute() {
  setup_workspace "ci-head-abs"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  run_tt task checkin --switch "$task_id" >/dev/null 2>&1 || true

  local head_target
  head_target="$(readlink "$VIRTUAL/HEAD")"
  assert_eq "HEAD is absolute" "${head_target:0:1}" "/"
}


test_task_checkin__head_symlink_updated_from_worktree() {
  # With --switch, running `tt task checkin` from inside a task's dedicated
  # worktree updates HEAD to point at the parent's workspace, rather than
  # leaving it pointing at the task worktree.
  setup_workspace "ci-head-wt-switch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  # Checkout with a dedicated worktree and switch HEAD to it
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"

  # Checkpoint from within the worktree
  run_tt_in_worktree "$worktree_path" task checkpoint -m "work" >/dev/null 2>&1 || true

  # HEAD currently points to the task worktree
  local head_before
  head_before="$(readlink "$VIRTUAL/HEAD")"
  assert_contains "HEAD points to task worktree before checkin" "$head_before" "$task_id"

  # Run checkin FROM WITHIN the worktree (no TT_REPO set)
  local exit_code=0
  output=$(run_tt_in_worktree "$worktree_path" task checkin --complete --switch 2>&1) || exit_code=$?

  assert_success "checkin from worktree succeeds" "$exit_code"

  local head_after
  head_after="$(readlink "$VIRTUAL/HEAD")"
  assert_not_contains "HEAD no longer points to task worktree" "$head_after" "$task_id"
  assert_neq "HEAD was updated from task worktree" "$head_after" "$head_before"
  assert_file_exists "HEAD target exists" "$head_after"
  assert_file_exists "child worktree retained without --delete" "$worktree_path"
}


test_task_checkin__switch_targets_repo_root_when_parent_has_no_worktree() {
  # Regression: a checkin that deletes the task, run with --switch from the
  # child's own dedicated worktree while the parent task is not checked out
  # anywhere, used to point HEAD at the child worktree (because $repo resolves
  # to it) and then delete that worktree, leaving a dangling HEAD symlink.
  # HEAD must instead fall back to the canonical repository root.
  setup_workspace "ci-switch-no-parent-wt"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  # Give the task a dedicated worktree and point HEAD at it
  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"
  run_tt_in_worktree "$worktree_path" task checkpoint -m "work" >/dev/null 2>&1 || true

  # Move the main workspace off the project branch so the parent task is not
  # checked out in any worktree.
  jj -R "$REPO" new main >/dev/null 2>&1 || true

  local exit_code=0
  output=$(run_tt_in_worktree "$worktree_path" task checkin --complete --delete --switch 2>&1) || exit_code=$?
  assert_success "checkin with --delete --switch succeeds" "$exit_code"

  assert_file_not_exists "child worktree deleted" "$worktree_path"

  local head_after
  head_after="$(readlink "$VIRTUAL/HEAD")"
  assert_eq "HEAD points at canonical repo root" "$head_after" "$REPO"
  assert_file_exists "HEAD is not dangling" "$VIRTUAL/HEAD"
}


test_task_checkin__head_not_switched_without_switch_flag() {
  # Without --switch, checkin must leave the HEAD symlink exactly as it was,
  # even when HEAD points at the task being checked in.
  setup_workspace "ci-head-no-flag"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  run_tt task checkout "$task_id" --worktree --switch >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"
  run_tt_in_worktree "$worktree_path" task checkpoint -m "work" >/dev/null 2>&1 || true

  local head_before
  head_before="$(readlink "$VIRTUAL/HEAD")"

  # Partial checkin, so the worktree survives and HEAD stays resolvable
  local exit_code=0
  output=$(run_tt_in_worktree "$worktree_path" task checkin 2>&1) || exit_code=$?
  assert_success "checkin without --switch succeeds" "$exit_code"

  local head_after
  head_after="$(readlink "$VIRTUAL/HEAD")"
  assert_eq "HEAD unchanged without --switch" "$head_after" "$head_before"
}


test_task_checkin__worktree_retained_after_complete_checkin() {
  # A complete (DONE) checkin must NOT remove the task's dedicated worktree:
  # tearing down a worktree is an explicit step, requested with --delete.
  setup_workspace "ci-wt-cleanup"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  # Create a dedicated worktree (no --switch; HEAD stays on proj)
  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"
  assert_file_exists "worktree exists before checkin" "$worktree_path"

  # Checkpoint from the worktree
  run_tt_in_worktree "$worktree_path" task checkpoint -m "work" >/dev/null 2>&1 || true

  # Complete checkin (from main repo, with explicit task_id)
  run_tt task checkin --complete "$task_id" >/dev/null 2>&1 || true

  assert_file_exists "worktree retained after complete checkin" "$worktree_path"
  local ws_list
  ws_list="$(jj -R "$REPO" workspace list --no-pager -T 'name ++ "\n"' 2>/dev/null)" || ws_list=''
  assert_contains "jj workspace still registered" "$ws_list" "$task_id"
}


test_task_checkin__worktree_deleted_with_delete() {
  # With --delete the task is removed from the repository, so its dedicated
  # worktree is forgotten from jj and its files deleted from disk.
  setup_workspace "ci-wt-delete"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"
  assert_file_exists "worktree exists before checkin" "$worktree_path"

  run_tt_in_worktree "$worktree_path" task checkpoint -m "work" >/dev/null 2>&1 || true

  local exit_code=0
  output=$(run_tt task checkin --complete --delete "$task_id" 2>&1) || exit_code=$?
  assert_success "checkin --complete --delete succeeds" "$exit_code"

  assert_file_not_exists "worktree deleted with --delete" "$worktree_path"
  local ws_list
  ws_list="$(jj -R "$REPO" workspace list --no-pager -T 'name ++ "\n"' 2>/dev/null)" || ws_list=''
  assert_not_contains "jj workspace forgotten" "$ws_list" "$task_id"
}


test_task_checkin__retain_worktree_flag() {
  # --retain-worktree suppresses the worktree removal that --delete performs.
  setup_workspace "ci-retain-wt"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"
  assert_file_exists "worktree exists before checkin" "$worktree_path"

  run_tt_in_worktree "$worktree_path" task checkpoint -m "work" >/dev/null 2>&1 || true

  # Checkin with --delete --retain-worktree
  run_tt task checkin --complete --delete --retain-worktree "$task_id" >/dev/null 2>&1 || true

  # Worktree files should still exist
  assert_file_exists "worktree retained with --retain-worktree" "$worktree_path"
}


test_task_checkin__worktree_not_deleted_after_partial_checkin() {
  # A partial (IN-PROGRESS) checkin should NOT delete the worktree.
  setup_workspace "ci-partial-wt"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  run_tt task checkout "$task_id" --worktree >/dev/null 2>&1 || true
  local worktree_path="$VIRTUAL/$task_id"

  run_tt_in_worktree "$worktree_path" task checkpoint -m "work" >/dev/null 2>&1 || true

  # Partial checkin (IN-PROGRESS, not complete)
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  assert_file_exists "worktree retained after partial checkin" "$worktree_path"
}


test_task_checkin__cwd_outside_repo() {
  # Regression: jj file show resolves paths relative to CWD, not the repo root.
  # tt commands must use root: prefix so checkin works when CWD is outside the repo
  # (e.g. when -R receives the canonical path but CWD is a symlinked or parent path).
  setup_workspace "ci-cwd"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true

  # Run checkin from /tmp (completely outside the repo) using the canonical repo path.
  local canonical_repo
  canonical_repo="$(cd "$REPO" && pwd -P)"

  output="" exit_code=0
  output=$(cd /tmp && TT_REPO="$canonical_repo" "$TT" task checkin "$task_id" 2>&1) || exit_code=$?
  assert_success "checkin from outside repo (canonical path) succeeds" "$exit_code"
}


test_task_checkin__help() {
  setup_workspace "checkin-help"
  output="" exit_code=0
  output=$(run_tt task checkin --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task checkin"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
  assert_optional_usage_argument "argument: --force" "$output" "--force"
  assert_optional_usage_argument "argument: --delete" "$output" "--delete"
}


# ---------------------------------------------------------------------------
# Bookmark positioning after checkin
# ---------------------------------------------------------------------------

# After an INCOMPLETE checkin the task bookmark should still point to the last
# commit on the task branch (e.g. the checkpoint commit).  That commit is
# already in the parent's ancestry via the handoff/merge, so propagate will
# later create a resume commit on the parent tip when the parent advances.
test_task_checkin__incomplete_bookmark_stays_at_last_commit() {
  setup_workspace "ci-bm-incomplete"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  edit_file "work.txt" "some work"
  checkpoint_task "Work" >/dev/null || true
  # Record where the bookmark is before checkin.
  local commit_before
  commit_before=$(get_bookmark_commit "$task_id")

  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  local commit_after
  commit_after=$(get_bookmark_commit "$task_id")
  assert_eq "incomplete: bookmark unchanged after checkin" "$commit_after" "$commit_before"
  assert_commit_message_first_line "incomplete: bookmark still points to checkpoint" "$task_id" "[tt:task:$task_id:checkpoint] Work"
}


# After a COMPLETE checkin the task bookmark should still point to the
# "Complete task:" commit — its natural resting place after `tt task complete`.
# That commit is in the parent's ancestry (via handoff → merge), so a
# subsequent `propagate` should leave it alone entirely.
test_task_checkin__complete_bookmark_stays_at_complete_commit() {
  setup_workspace "ci-bm-complete"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  edit_file "work.txt" "some work"
  checkpoint_task "Work" >/dev/null || true
  complete_task >/dev/null || true
  # Record where the bookmark is before checkin.
  local commit_before
  commit_before=$(get_bookmark_commit "$task_id")

  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  local commit_after
  commit_after=$(get_bookmark_commit "$task_id")
  assert_eq "complete: bookmark unchanged after checkin" "$commit_after" "$commit_before"
  assert_commit_message "complete: bookmark still points to complete commit" "$task_id" "[tt:task:$task_id:complete] T"
}


# When --propagate is added to a complete checkin the task bookmark must still
# end up at the "Complete task:" commit — propagate must not create a resume
# commit for a DONE task and must not rebase it.
test_task_checkin__complete_with_propagate_bookmark_unchanged() {
  setup_workspace "ci-bm-prop"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  edit_file "work.txt" "some work"
  checkpoint_task "Work" >/dev/null || true
  # Use --complete --propagate to exercise both code paths together.
  run_tt task checkin --complete --propagate "$task_id" >/dev/null 2>&1 || true

  # The bookmark should be at the "Complete task:" commit, not a child of it.
  assert_commit_message "bookmark at complete commit after checkin+propagate" "$task_id" "[tt:task:$task_id:complete] T"
}


test_task_checkin__context_before_subtask_in_parent() {
  setup_workspace "checkin-ctx-order"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "parent" "Parent") || true
  checkout_task "$task_id" >/dev/null || true

  # Create two children so parent has multiple subtask: entries
  child_a=$(create_task_under "$task_id" "ca" "Child A") || true
  child_b=$(create_task_under "$task_id" "cb" "Child B") || true

  # Check in child_a with --context (adds context: entry to parent)
  checkout_task "$child_a" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true
  run_tt task checkin --complete --context "Handoff notes" "$child_a" >/dev/null 2>&1 || true

  # Read parent task file and verify canonical ordering
  content="$(read_task_file "$task_id")"
  assert_frontmatter_order "valid order after checkin with --context" "$content"
}

test_task_checkin__head_not_switched_when_checkin_non_active_task() {
  # Without --switch, checking in a task that is NOT the active task (HEAD
  # points to a different task) leaves HEAD untouched.
  setup_workspace "ci-head-no-switch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "Task A") || true
  task_b=$(create_task "b" "Task B") || true

  # Propagate parent to task A so it has task B's subtask entry (avoids conflict)
  run_tt task propagate --from "$proj_id" --to "$task_a" >/dev/null 2>&1 || true

  # Give both tasks dedicated worktrees so that target_ws != current_worktree
  run_tt task checkout "$task_a" --worktree --switch >/dev/null 2>&1 || true
  local worktree_a="$VIRTUAL/$task_a"
  run_tt_in_worktree "$worktree_a" task checkpoint -m "Work on A" >/dev/null 2>&1 || true
  run_tt_in_worktree "$worktree_a" task complete >/dev/null 2>&1 || true

  # Give task B its own worktree and switch HEAD to it
  run_tt task checkout "$task_b" --worktree --switch >/dev/null 2>&1 || true
  local worktree_b="$VIRTUAL/$task_b"

  local head_before
  head_before="$(readlink "$VIRTUAL/HEAD")"

  # Checkin task A by explicit ID from task B's worktree (we are NOT on task A)
  local exit_code=0
  output=$(run_tt_in_worktree "$worktree_b" task checkin "$task_a" 2>&1) || exit_code=$?
  assert_success "checkin of non-active task succeeds" "$exit_code"

  # HEAD should still point to wherever it was before (task B's context)
  local head_after
  head_after="$(readlink "$VIRTUAL/HEAD")"
  assert_eq "HEAD unchanged after checkin of non-active task" "$head_after" "$head_before"
}


test_task_checkin__switch_applies_when_checkin_non_active_task() {
  # --switch is unconditional: it moves HEAD to the parent worktree even when
  # HEAD currently points at an unrelated task.
  setup_workspace "ci-head-switch-non-active"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "a" "Task A") || true
  task_b=$(create_task "b" "Task B") || true

  # Propagate parent to task A so it has task B's subtask entry (avoids conflict)
  run_tt task propagate --from "$proj_id" --to "$task_a" >/dev/null 2>&1 || true

  run_tt task checkout "$task_a" --worktree --switch >/dev/null 2>&1 || true
  local worktree_a="$VIRTUAL/$task_a"
  run_tt_in_worktree "$worktree_a" task checkpoint -m "Work on A" >/dev/null 2>&1 || true
  run_tt_in_worktree "$worktree_a" task complete >/dev/null 2>&1 || true

  # Give task B its own worktree and switch HEAD to it
  run_tt task checkout "$task_b" --worktree --switch >/dev/null 2>&1 || true
  local worktree_b="$VIRTUAL/$task_b"

  local head_before
  head_before="$(readlink "$VIRTUAL/HEAD")"

  # Checkin task A by explicit ID from task B's worktree (we are NOT on task A)
  local exit_code=0
  output=$(run_tt_in_worktree "$worktree_b" task checkin --switch "$task_a" 2>&1) || exit_code=$?
  assert_success "checkin of non-active task with --switch succeeds" "$exit_code"

  # HEAD should have moved to the parent (project) worktree
  local head_after
  head_after="$(readlink "$VIRTUAL/HEAD")"
  assert_neq "HEAD moved with --switch" "$head_after" "$head_before"
  assert_eq "HEAD points at parent worktree" "$head_after" "$REPO"
}

test_task_checkin__context_from_stdin() {
  setup_workspace "checkin-ctx-stdin"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "parent" "Parent") || true
  checkout_task "$task_id" >/dev/null || true
  child_id=$(create_task_under "$task_id" "child" "Child") || true
  checkout_task "$child_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  # Pass --context - to read from stdin
  echo "Context from stdin" | run_tt task checkin --complete --context - "$child_id" >/dev/null 2>&1 || true

  # Verify context file was created on the parent task
  ctx_list="$(run_tt task context list "$task_id" 2>/dev/null)" || true
  assert_contains "context file created via stdin" "$ctx_list" "context/"

  # Verify context file body
  ctx_body="$(run_tt task context get --task "$task_id" 2>/dev/null)" || true
  assert_contains "context body from stdin" "$ctx_body" "Context from stdin"
}

test_task_checkin__context_empty_stdin_skips_context() {
  setup_workspace "checkin-ctx-empty-stdin"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "parent" "Parent") || true
  checkout_task "$task_id" >/dev/null || true
  child_id=$(create_task_under "$task_id" "child" "Child") || true
  checkout_task "$child_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  # Pass --context - with empty stdin
  echo -n "" | run_tt task checkin --complete --context - "$child_id" >/dev/null 2>&1 || true

  # Verify no context file was created
  ctx_list="$(run_tt task context list "$task_id" 2>/dev/null)" || true
  assert_eq "no context file for empty stdin" "$ctx_list" ""
}

run_tests "tt task checkin"
