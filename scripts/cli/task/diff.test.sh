#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_diff__basic() {
  setup_workspace "diff-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "hello diff" > "$TT_REPO/feature.txt"
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task diff 2>&1) || exit_code=$?
  assert_success "diff succeeds" "$exit_code"
  assert_contains "diff mentions added file" "$output" "feature.txt"
  assert_contains "diff includes file content" "$output" "hello diff"
}


test_task_diff__explicit_task() {
  setup_workspace "diff-explicit"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "explicit content" > "$TT_REPO/explicit.txt"
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task diff --task "$task_id" 2>&1) || exit_code=$?
  assert_success "diff with --task succeeds" "$exit_code"
  assert_contains "diff mentions added file" "$output" "explicit.txt"
}


test_task_diff__includes_trailing_commits() {
  setup_workspace "diff-trailing"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "first commit" >/dev/null || true
  # Create a commit beyond the task bookmark
  echo "trailing content" > "$TT_REPO/trailing.txt"
  jj -R "$TT_REPO" commit -m "trailing commit" >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt task diff 2>&1) || exit_code=$?
  assert_success "diff succeeds with trailing commits" "$exit_code"
  assert_contains "diff includes trailing commit changes" "$output" "trailing.txt"
}


test_task_diff__uncommitted_changes() {
  setup_workspace "diff-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "first commit" >/dev/null || true
  echo "dirty content" > "$TT_REPO/dirty.txt"

  output="" exit_code=0
  output=$(run_tt task diff 2>&1) || exit_code=$?
  assert_success "diff succeeds with dirty wc" "$exit_code"
  assert_contains "diff includes working copy changes" "$output" "dirty.txt"
}


test_task_diff__excludes_metadata_by_default() {
  setup_workspace "diff-metadata-default"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "source content" > "$TT_REPO/source.txt"
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task diff 2>&1) || exit_code=$?
  assert_success "diff succeeds" "$exit_code"
  assert_contains "non-metadata file present" "$output" "source.txt"
  # Match jj's file headers ("Modified regular file .tt/...") rather than the
  # bare path: the TASK.md symlink's *content* is a '.tt/task/...' path, so it
  # legitimately appears in the diff body of a non-metadata file.
  assert_not_contains "metadata dir excluded" "$output" ".tt/"
  # jj reports the root symlink as e.g. "Symlink target changed at TASK.md:";
  # anchor on the trailing colon so symlink *contents* elsewhere don't match.
  assert_not_matches "TASK.md symlink excluded" "$output" "TASK.md"
}


test_task_diff__include_metadata() {
  setup_workspace "diff-metadata-include"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "source content" > "$TT_REPO/source.txt"
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task diff --include-metadata 2>&1) || exit_code=$?
  assert_success "diff with --include-metadata succeeds" "$exit_code"
  assert_contains "non-metadata file present" "$output" "source.txt"
  assert_contains "metadata dir included" "$output" "file .tt/"
  assert_matches "TASK.md symlink included" "$output" '(^|[^/])TASK\.md:'
}


test_task_diff__not_on_task_branch() {
  setup_workspace "diff-no-branch"
  output="" exit_code=0
  output=$(run_tt task diff 2>&1) || exit_code=$?
  assert_failure "diff fails when not on task" "$exit_code"
  assert_contains "error message" "$output" "Error"
}


test_task_diff__nonexistent_task() {
  setup_workspace "diff-nonexistent"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task diff --task "task/does-not-exist-00000000" 2>&1) || exit_code=$?
  assert_failure "diff fails for nonexistent task" "$exit_code"
  assert_contains "error message" "$output" "Error"
}


test_task_diff__alias() {
  setup_workspace "diff-alias"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "alias content" > "$TT_REPO/alias.txt"
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt diff --task "$task_id" 2>&1) || exit_code=$?
  assert_success "alias works" "$exit_code"
  assert_contains "alias output includes file" "$output" "alias.txt"
}


test_task_diff__help() {
  setup_workspace "diff-help"
  output="" exit_code=0
  output=$(run_tt task diff --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task diff"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --include-metadata" "$output" "--include-metadata"
}


run_tests "tt task diff"
