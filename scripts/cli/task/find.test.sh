#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_task_find__working_copy_of_a_task() {
  setup_workspace "find-working-copy"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task find --revision '@' 2>&1) || exit_code=$?
  assert_success "find succeeds" "$exit_code"
  assert_eq "output is the checked-out task" "$output" "$task_id"
}


test_task_find__task_branch_revision() {
  setup_workspace "find-task-branch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "work" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task find --revision "$task_id" 2>&1) || exit_code=$?
  assert_success "find succeeds" "$exit_code"
  assert_eq "output is the task the revision records" "$output" "$task_id"
}


test_task_find__project_branch_revision() {
  setup_workspace "find-project-branch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task find --revision "$proj_id" 2>&1) || exit_code=$?
  assert_success "find succeeds" "$exit_code"
  assert_eq "output is the project the revision records" "$output" "$proj_id"
}


test_task_find__revision_recording_no_task() {
  setup_workspace "find-no-task"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  stdout="" stderr_file="$_TEST_ROOT/find-no-task.stderr" exit_code=0
  stdout=$(run_tt task find --revision 'root()' 2>"$stderr_file") || exit_code=$?
  assert_failure "find fails" "$exit_code"
  assert_eq "nothing on stdout" "$stdout" ''
  assert_eq "error names the revision" "$(cat "$stderr_file")" \
    "Error: Unable to locate task for revision root()"
}


test_task_find__unknown_revision() {
  setup_workspace "find-unknown"
  output="" exit_code=0
  output=$(run_tt task find --revision 'no-such-revision' 2>&1) || exit_code=$?
  assert_failure "find fails" "$exit_code"
  assert_eq "error names the revision" "$output" \
    "Error: Unable to locate task for revision no-such-revision"
}


test_task_find__revision_naming_several_commits() {
  setup_workspace "find-several"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task find --revision '@ | @-' 2>&1) || exit_code=$?
  assert_failure "find fails" "$exit_code"
  assert_eq "error names the revision" "$output" \
    "Error: Unable to locate task for revision @ | @-"
}


test_task_find__revision_naming_no_commits() {
  setup_workspace "find-empty"
  output="" exit_code=0
  output=$(run_tt task find --revision 'none()' 2>&1) || exit_code=$?
  assert_failure "find fails" "$exit_code"
  assert_eq "error names the revision" "$output" \
    "Error: Unable to locate task for revision none()"
}


test_task_find__task_branch_deleted() {
  setup_workspace "find-deleted"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "work" >/dev/null || true
  task_commit=$(get_full_commit_id "$task_id")
  complete_task >/dev/null || true
  checkin_task "$task_id" >/dev/null || true
  run_tt task delete "$task_id" >/dev/null 2>&1 || true
  assert_bookmark_not_exists "the fixture deletes the task branch" "$task_id"

  output="" exit_code=0
  output=$(run_tt task find --revision "$task_commit" 2>&1) || exit_code=$?
  assert_failure "find fails" "$exit_code"
  assert_eq "error names the revision" "$output" \
    "Error: Unable to locate task for revision $task_commit"
}


test_task_find__missing_revision() {
  setup_workspace "find-missing-revision"
  stdout="" stderr_file="$_TEST_ROOT/find-missing-revision.stderr" exit_code=0
  stdout=$(run_tt task find 2>"$stderr_file") || exit_code=$?
  assert_failure "find fails" "$exit_code"
  assert_eq "nothing on stdout" "$stdout" ''
  assert_usage_command_name "usage on stderr" "$(cat "$stderr_file")" "tt task find"
}


test_task_find__alias() {
  setup_workspace "find-alias"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt find --revision '@' 2>&1) || exit_code=$?
  assert_success "tt find succeeds" "$exit_code"
  assert_eq "output is the checked-out project" "$output" "$proj_id"
}


test_task_find__help() {
  setup_workspace "find-help"
  output="" exit_code=0
  output=$(run_tt task find --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task find"
  assert_required_usage_argument "argument: --revision" "$output" "--revision"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task find"
