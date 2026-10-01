#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_task_create__create_project() {
  setup_workspace "create-project"
  proj_id=$(create_project "myproj" "My Project") || true
  assert_success "create project succeeds" "$?"
  assert_matches "project ID format" "$proj_id" "project/%myproj%"
  assert_bookmark_exists "project bookmark exists" "$proj_id"
  assert_task_status "project status is TODO" "$proj_id" "TODO"
  assert_task_title "project title" "$proj_id" "My Project"
}


test_task_create__create_task_under_project() {
  setup_workspace "create-under-project"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_id=$(create_task "child" "Child Task" "Task body") || true
  assert_success "create task succeeds" "$?"
  assert_matches "task ID format" "$task_id" "task/%child%"
  assert_bookmark_exists "child bookmark exists" "$task_id"
  assert_task_status "child status TODO" "$task_id" "TODO"
  assert_task_title "child title" "$task_id" "Child Task"
  assert_task_body_contains "child body" "$task_id" "Task body"

  assert_subtask_entry "parent has subtask entry" "$proj_id" "$task_id" "[ ]"
  assert_is_ancestor "child descends from parent" "$proj_id" "$task_id"
  assert_current_task "WC on parent" "$proj_id"
}


test_task_create__create_with_checkout() {
  setup_workspace "create-checkout"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_id=$(run_tt task create --slug "mytask" --title "My Task" --checkout <<< "" 2>/dev/null | tail -1) || true
  assert_success "create with --checkout succeeds" "$?"
  assert_matches "task ID format" "$task_id" "task/%mytask%"
  assert_wc_on_branch_matches "WC on new task" "task/%mytask%"
  assert_task_status "status is IN-PROGRESS" "$task_id" "IN-PROGRESS"
}


test_task_create__create_with_labels() {
  setup_workspace "create-labels"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_id=$(run_tt task create --slug "lbl" --title "Labeled" --label "bug" --label "urgent" <<< "" 2>/dev/null | tail -1) || true
  assert_task_label "has bug label" "$task_id" "bug"
  assert_task_label "has urgent label" "$task_id" "urgent"
}


test_task_create__reopens_completed_parent() {
  setup_workspace "create-completed-parent"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "parent" "Parent Task") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true
  assert_task_status "parent DONE before create" "$task_id" "DONE"

  parent_before=$(get_bookmark_commit "$task_id")

  child_id=$(create_task_under "$task_id" "child" "Child") || true
  assert_matches "child task created" "$child_id" "^task/child-"
  assert_task_status "parent reopened" "$task_id" "IN-PROGRESS"
  assert_neq "parent bookmark advanced" "$(get_bookmark_commit "$task_id")" "$parent_before"
  assert_subtask_entry "child registered on parent" "$task_id" "$child_id" "[ ]"
  assert_task_status "child is TODO" "$child_id" "TODO"
}


test_task_create__invalid_slug_rejected() {
  setup_workspace "create-invalid-slug"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task create --slug "UPPERCASE" --title "Bad" <<< "" 2>&1) || exit_code=$?
  assert_failure "UPPERCASE slug rejected" "$exit_code"
}


test_task_create__no_task_checked_out_rejected() {
  # A task needs a parent, and with nothing checked out nothing records which
  # one it should be: the command says so rather than forking a parentless task
  # from whichever bookmark happens to lie below the working copy.
  setup_workspace "create-no-current"
  output="" exit_code=0
  output=$(run_tt task create --slug "orphan" --title "Orphan" <<< "" 2>&1) || exit_code=$?
  assert_failure "create with nothing checked out rejected" "$exit_code"
  assert_contains "error explains the branch requirement" "$output" "Not on a task or project branch"
  assert_contains "error offers --parent" "$output" "--parent"
  assert_contains "error offers --project" "$output" "--project"
  assert_revset_count "no branch was created" 'bookmarks()' 1
}


test_task_create__project_with_parent_rejected() {
  setup_workspace "create-exclusive"
  output="" exit_code=0
  output=$(run_tt task create --project --parent "task/x-00000000" --slug "x" --title "X" <<< "" 2>&1) || exit_code=$?
  assert_failure "--project + --parent rejected" "$exit_code"
}


test_task_create__wc_position_preserved_without_checkout() {
  setup_workspace "create-wc-preserve"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_id=$(create_task "child" "Child") || true
  assert_current_task "WC still on parent" "$proj_id"
}


test_task_create__refuses_bookmark_on_working_copy() {
  setup_workspace "create-bm-refusal"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # Clean working copy carrying the parent's own bookmark
  jj -R "$REPO" bookmark set "$proj_id" -r '@' >/dev/null 2>&1
  output="" exit_code=0
  output=$(run_tt task create --slug "blocked" --title "Blocked" <<< "" 2>&1) || exit_code=$?
  assert_failure "parent bookmark on @ refused" "$exit_code"
  assert_contains "error names the bookmark" "$output" "tip of bookmark"
  assert_no_subtask_entry "no subtask entry added" "$proj_id" "task/blocked"

  # Bookmark unrelated to the parent being written (explicit --parent, so the
  # working-copy guard itself is what refuses)
  jj -R "$REPO" bookmark set "$proj_id" -r '@-' --allow-backwards >/dev/null 2>&1
  jj -R "$REPO" bookmark set unrelated -r '@' >/dev/null 2>&1
  exit_code=0
  output=$(run_tt task create --parent "$proj_id" --slug "blocked" --title "Blocked" <<< "" 2>&1) || exit_code=$?
  assert_failure "unrelated bookmark on @ refused" "$exit_code"
  assert_contains "error names the unrelated bookmark" "$output" "unrelated"
}


test_task_create__dirty_wc_preserved_not_absorbed() {
  setup_workspace "create-dirty-keep"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # Dirty WC: the branch writes must neither reject nor absorb it
  edit_file "scratch.txt" "uncommitted scratch"

  task_id=$(create_task "child" "Child" "Body") || true
  assert_matches "task created with dirty WC" "$task_id" "task/%child%"
  assert_subtask_entry "subtask registered on parent" "$proj_id" "$task_id" "[ ]"
  assert_file_exists "dirty file still on disk" "$REPO/scratch.txt"
  assert_wc_dirty "WC still dirty"
  assert_file_not_on_branch "dirty file not on parent branch" "$proj_id" "scratch.txt"
  assert_file_not_on_branch "dirty file not on child branch" "$task_id" "scratch.txt"
}


test_task_create__working_copy_commit_stays_put() {
  setup_workspace "create-wc-stays"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # With @ sitting on the parent branch's line, a create keeps @ attached to
  # the advanced parent tip: same change ID, parent is the create commit.
  change_before=$(get_wc_change_id)
  task_a=$(create_task "ta" "Task A") || true
  change_after=$(get_wc_change_id)
  assert_eq "same WC change after create on current branch" "$change_after" "$change_before"
  parent_commit=$(jj -R "$REPO" log -r '@-' --no-graph -T 'commit_id.short(8)' 2>/dev/null)
  assert_eq "@ parent is new parent tip" "$parent_commit" "$(get_bookmark_commit "$proj_id")"
  assert_current_task "WC still on parent" "$proj_id"
}


test_task_create__wc_untouched_when_other_branch_checked_out() {
  setup_workspace "create-wc-other-branch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true

  # Creating under a branch that is not in @'s ancestry line must leave @
  # entirely untouched (identical commit ID — nothing moved, so nothing was
  # restored either).
  wc_before=$(get_wc_commit)
  task_c=$(create_task_under "$proj_id" "tc" "Task C") || true
  wc_after=$(get_wc_commit)
  assert_eq "@ commit unchanged after cross-branch create" "$wc_after" "$wc_before"
  assert_matches "task created" "$task_c" "task/%tc%"
  assert_subtask_entry "subtask registered on parent" "$proj_id" "$task_c" "[ ]"
  assert_current_task "WC still on task A" "$task_a"
}


test_task_create__single_transaction_recorded() {
  setup_workspace "create-txn"
  get_history_lines
  hc_before="${#HISTORY_LINES[@]}"

  proj_id=$(create_project "proj" "Project") || true

  get_history_lines
  hc_after="${#HISTORY_LINES[@]}"
  assert_eq "one new history entry" "$((hc_after - hc_before))" "1"
  assert_history_integrity "history integrity after create"
}


test_task_create__project_with_target() {
  setup_workspace "create-project-target"
  proj_id=$(run_tt task create --project --slug "proj" --title "Proj" --target "main" <<< "" 2>/dev/null | tail -1) || true
  assert_success "project with --target succeeds" "$?"
  assert_is_ancestor "main is ancestor of project" "main" "$proj_id"
}


test_task_create__propagate() {
  setup_workspace "create-propagate"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child_a=$(create_task "child-a" "Child A") || true
  checkout_task "$proj_id" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true
  child_b=$(run_tt task create --slug "child-b" --title "Child B" --propagate <<< "" 2>/dev/null | tail -1) || true
  assert_matches "child B created" "$child_b" "task/%child-b%"
  assert_is_ancestor "child A descends from parent" "$proj_id" "$child_a"
  assert_is_ancestor "child B descends from parent" "$proj_id" "$child_b"
}


test_task_create__help() {
  setup_workspace "create-help"
  output="" exit_code=0
  output=$(run_tt task create --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task create"
  assert_optional_usage_argument "argument: --title" "$output" "--title"
  assert_optional_usage_argument "argument: --slug" "$output" "--slug"
  assert_optional_usage_argument "argument: --parent" "$output" "--parent"
  assert_optional_usage_argument "argument: --project" "$output" "--project"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
  assert_optional_usage_argument "argument: --force" "$output" "--force"
}


test_task_create__switch_without_checkout_rejected() {
  setup_workspace "create-switch-no-checkout"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task create --slug "mytask" --title "My Task" --switch <<< "" 2>&1) || exit_code=$?
  assert_failure "--switch without --checkout rejected" "$exit_code"
}


test_task_create__switch_without_worktree_rejected() {
  setup_workspace "create-switch-no-worktree"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task create --slug "mytask" --title "My Task" --checkout --switch <<< "" 2>&1) || exit_code=$?
  assert_failure "--switch without --worktree rejected" "$exit_code"
}


test_task_create__checkout_worktree_switch() {
  setup_workspace "create-checkout-wt-switch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_id=$(run_tt task create --slug "mytask" --title "My Task" --checkout --worktree --switch <<< "" 2>/dev/null | tail -1) || true
  assert_success "create with --checkout --worktree --switch succeeds" "$?"
  assert_matches "task ID format" "$task_id" "task/%mytask%"

  # HEAD symlink should point to the worktree directory
  local head_target
  head_target="$(readlink "$VIRTUAL/HEAD")"
  assert_eq "HEAD is absolute" "${head_target:0:1}" "/"
}


test_task_create__subtask_after_existing_context() {
  setup_workspace "create-subtask-order"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "parent" "Parent") || true
  checkout_task "$task_id" >/dev/null || true

  # Add a context to the parent first
  echo "Body" | run_tt task context add --title "Research" --slug "research" >/dev/null 2>&1 || true

  # Now create a child — the subtask entry must appear after the context entry
  create_task_under "$task_id" "child" "Child" >/dev/null || true

  content="$(read_task_file "$task_id")"
  assert_frontmatter_order "canonical order after subtask added to parent with context" "$content"
}

test_task_create__refuses_when_the_canonical_workspace_is_stale() {
  setup_workspace "create-stale-canonical"
  setup_stale_canonical "created"

  assert_refuses_stale_canonical "$STALE_WORKTREE" \
    task create --slug "child" --title "Child"
}

test_task_create__ancestor_write_leaves_the_worktree_on_its_task() {
  setup_workspace "create-ancestor-worktree"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
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
  run_tt_in_worktree "$task_wt" task create --parent "$proj_id" --slug "sibling" \
    --title "Sibling" <<< "" >/dev/null 2>&1 || exit_code=$?
  assert_success "create succeeds" "$exit_code"
  assert_neq "the project branch advanced" "$(get_bookmark_commit "$proj_id")" "$proj_before"
  assert_eq "the worktree is still on its task" \
    "$(run_tt_in_worktree "$task_wt" task current 2>/dev/null)" "$task_id"
  assert_eq "the worktree has not moved" \
    "$(jj -R "$task_wt" --ignore-working-copy log -r '@-' --no-graph -T 'commit_id' 2>/dev/null)" \
    "$wt_parent_before"
}

run_tests "tt task create"
