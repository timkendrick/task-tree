#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_task_show__show_current_task() {
  setup_workspace "show-current"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "My Task" "Task description") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "task ID in output" "$output" "task/t-"
  assert_contains "title in output" "$output" "My Task"
  assert_contains "body in output" "$output" "Task description"
}


test_task_show__title_with_newline_is_one_line() {
  setup_workspace "show-newline-title"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" $'Line one\nline two') || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_matches "the header title is on one line" "$output" '^title: +Line one line two$'
  assert_matches "the header status is intact" "$output" '^status: +IN-PROGRESS$'
}


# A write issued from another worktree advances this worktree's branch without
# moving its working copy, so the bookmark ends up on a sibling of the
# working-copy commit and the nearest bookmarked ancestor is the project the
# task forked from. Show must still report the task checked out here.
test_task_show__after_the_branch_advanced_elsewhere() {
  setup_workspace "show-advanced-elsewhere"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "mine" "My Task" "Task description") || true
  other_id=$(create_task "other" "Other") || true
  other_wt=$(create_task_worktree "$other_id")
  checkout_task "$task_id" >/dev/null || true

  run_tt_in_worktree "$other_wt" task edit "$task_id" --title "My Task, advanced" >/dev/null 2>&1 || true
  assert_not_ancestor "this worktree is left behind its branch" "$task_id" '@'
  assert_task_symlink "the worktree still records the task it checked out" "$task_id"

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "the task checked out here is shown" "$output" "task:   $task_id"
  assert_contains "its metadata is read from the advanced branch" "$output" "My Task, advanced"
}


# A task checked out in a worktree of its own is also, until something else is
# checked out there, under the workspace that was parked above its tip: two
# worktrees then sit on one branch, which must not disturb the command.
test_task_show__task_checked_out_in_several_worktrees() {
  setup_workspace "show-two-worktrees"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "My Task" "Task description") || true
  create_task_worktree "$task_id" >/dev/null
  # The repo workspace is parked above the task's tip as well.
  jj -R "$REPO" new "$task_id" >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds with two worktrees on the branch" "$exit_code"
  assert_contains "title in output" "$output" "My Task"
  assert_contains "body in output" "$output" "Task description"
}


test_task_show__explicit_task_id() {
  setup_workspace "show-explicit"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show "$task_a" 2>&1) || exit_code=$?
  assert_success "show explicit succeeds" "$exit_code"
  assert_contains "shows Task A" "$output" "Task A"
  assert_not_contains "does not show Task B title" "$output" "Task B"
}


test_task_show__task_with_subtasks() {
  setup_workspace "show-subs"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child Task") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show "$proj_id" 2>&1) || exit_code=$?
  assert_success "show with subtasks" "$exit_code"
  assert_contains "subtask listed" "$output" "child"
}


# Rewrite the subtask entries of the project file checked out in $REPO with
# the awk PROGRAM, and record the result on PROJ_ID.
# Usage: _edit_project_entries PROJ_ID PROGRAM
_edit_project_entries() {
  local proj_id="$1" program="$2"
  local file="$REPO/.tt/task/${proj_id#project/}/TASK.md"
  awk "$program" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  jj -R "$REPO" commit -m "edit subtask entries" >/dev/null 2>&1
  jj -R "$REPO" bookmark set "$proj_id" -r '@-' >/dev/null 2>&1
}

test_task_show__subtask_status_and_title_from_canonical_branch() {
  setup_workspace "show-sub-status"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  done_id=$(create_task "done" "Done Task") || true
  checkout_task "$done_id" >/dev/null || true
  checkin_task --complete >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true
  todo_id=$(create_task "todo" "Todo Task") || true
  # The merged task is read from the project's copy of its file.
  jj -R "$REPO" bookmark delete "$done_id" >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt task show "$proj_id" 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "subtasks in entry order with status and title" "$output" \
    "$(printf 'Subtasks:\n- [x] %s  Done Task\n- [ ] %s  Todo Task\n' "$done_id" "$todo_id")"
}

test_task_show__titled_subtask_entry_resolves() {
  setup_workspace "show-titled-entry"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child Task") || true
  _edit_project_entries "$proj_id" '/^subtask: / { $0 = $0 " Entry title" } { print }'

  output="" exit_code=0
  output=$(run_tt task show "$proj_id" 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "the fixture titles the entry" \
    "$(cat "$REPO/.tt/task/${proj_id#project/}/TASK.md")" "subtask: [ ] $child Entry title"
  assert_contains "title read from the subtask file" "$output" "- [ ] $child  Child Task"
  assert_not_contains "entry title not shown" "$output" "Entry title"
}

test_task_show__malformed_subtask_entry_skipped_with_warning() {
  setup_workspace "show-malformed-entry"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child Task") || true
  _edit_project_entries "$proj_id" '/^subtask: / { print "subtask: not-an-entry" } { print }'

  local err="$_TEST_ROOT/show-err.txt" output="" exit_code=0
  output=$(run_tt task show "$proj_id" 2>"$err") || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "well-formed entry listed" "$output" "- [ ] $child  Child Task"
  assert_not_contains "malformed entry not listed" "$output" "not-an-entry"
  assert_eq "warning names the entry and the task" "$(cat "$err")" \
    "Warning: Ignoring a malformed subtask entry 'not-an-entry' in the task file of '$proj_id'."
}

test_task_show__only_malformed_subtask_entries() {
  setup_workspace "show-only-malformed"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child Task") || true
  _edit_project_entries "$proj_id" '/^subtask: / { $0 = "subtask: not-an-entry" } { print }'

  output="" exit_code=0
  output=$(run_tt task show "$proj_id" 2>/dev/null) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "no subtasks message" "$output" "[No subtasks]"
  assert_not_contains "no subtasks heading" "$output" "Subtasks:"
}


test_task_show__untitled_subtask_on_one_line() {
  setup_workspace "show-untitled-sub"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child Task") || true
  # Without a branch the subtask's title cannot be read.
  jj -R "$REPO" bookmark delete "$child" >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt task show "$proj_id" 2>&1) || exit_code=$?
  assert_success "show with an untitled subtask" "$exit_code"
  assert_contains "checkbox and ID share one line" "$output" "- [ ] $child"
}

test_task_show__task_with_no_subtasks() {
  setup_workspace "show-nosub"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "no subtasks message" "$output" "No subtasks"
}


test_task_show__task_with_no_body() {
  setup_workspace "show-nobody"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T" "") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "no description message" "$output" "No description"
}


test_task_show__task_with_context() {
  setup_workspace "show-ctx"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "Context body" | run_tt task context add --title "My Ctx" --slug "ctx" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show with context" "$exit_code"
  assert_contains "context in output" "$output" "context/ctx-"
  assert_matches "context title before its ID" "$output" '^- My Ctx \(context/%x%\)$'
}


test_task_show__expand_context_shows_content() {
  setup_workspace "show-expand"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "Expanded body text" | run_tt task context add --title "Ctx" --slug "ctx" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task show --expand-context 2>&1) || exit_code=$?
  assert_success "expand-context succeeds" "$exit_code"
  assert_contains "context body expanded" "$output" "Expanded body text"
}


test_task_show__expand_context_reencodes_an_escaped_title() {
  setup_workspace "show-expand-escaped"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "Body" | run_tt task context add --title 'Say "hi" \ there' --slug "ctx" \
    >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task show --expand-context 2>&1) || exit_code=$?
  assert_success "expand-context succeeds" "$exit_code"
  assert_contains "the expanded title is a quoted frontmatter string" "$output" \
    'title: "Say \"hi\" \\ there"'
}


test_task_show__not_on_task_branch_fails() {
  setup_workspace "show-notask"
  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_failure "show on non-task fails" "$exit_code"
}


test_task_show__shows_parent() {
  setup_workspace "show-parent"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "parent shown" "$output" "project/proj-"
}


test_task_show__cwd_outside_repo() {
  # Regression: jj file show resolves paths relative to CWD, not the repo root.
  # tt commands must use the root: prefix so they work regardless of CWD.
  setup_workspace "show-cwd"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "My Task" "Task description") || true
  checkout_task "$task_id" >/dev/null || true

  # Run tt show from a directory completely outside the repo, with TT_REPO
  # pointing to the canonical path. This triggers the bug where jj file show
  # fails because paths are not relative to CWD.
  local canonical_repo
  canonical_repo="$(cd "$REPO" && pwd -P)"

  output="" exit_code=0
  output=$(cd /tmp && TT_REPO="$canonical_repo" "$TT" task show "$task_id" 2>&1) || exit_code=$?
  assert_success "show from outside repo (canonical path) succeeds" "$exit_code"
  assert_contains "title in output" "$output" "My Task"
  assert_contains "body in output" "$output" "Task description"
}


test_task_show__shows_labels() {
  setup_workspace "show-labels"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(run_tt task create --slug "t" --title "T" --label "bug" --label "urgent" <<< "" 2>/dev/null | tail -1) || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task show 2>&1) || exit_code=$?
  assert_success "show succeeds" "$exit_code"
  assert_contains "bug label shown" "$output" "bug"
  assert_contains "urgent label shown" "$output" "urgent"
}


test_task_show__help() {
  setup_workspace "show-help"
  output="" exit_code=0
  output=$(run_tt task show --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task show"
  assert_required_usage_argument "argument: <task-id>" "$output" "<task-id>"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
  assert_required_usage_argument "argument: --expand-context" "$output" "--expand-context"
}


run_tests "tt task show"
