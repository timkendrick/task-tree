#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


# Builds a project branch holding a two-level task tree (task A, with subtask A1
# checked into it) plus a checkpoint recorded directly on the project branch.
# Sets proj_id, task_a and task_a1.
_setup_two_level_tree() {
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_a=$(create_task "a" "Task A") || true
  checkout_task "$task_a" >/dev/null || true
  task_a1=$(create_task "a1" "Task A1") || true
  checkout_task "$task_a1" >/dev/null || true
  echo "a1" > "$TT_REPO/a1.txt"
  checkpoint_task "a1 work" >/dev/null || true
  run_tt task checkin "$task_a1" --complete >/dev/null 2>&1 || true

  checkout_task "$task_a" >/dev/null || true
  run_tt task checkin "$task_a" --complete >/dev/null 2>&1 || true

  checkout_task "$proj_id" >/dev/null || true
  echo "p" > "$TT_REPO/p.txt"
  checkpoint_task "project work" >/dev/null || true
}


test_task_changelog__nested_tree_and_checkpoints() {
  setup_workspace "changelog-nested"
  _setup_two_level_tree

  output="" exit_code=0
  output=$(run_tt task changelog --since main 2>/dev/null) || exit_code=$?
  assert_success "changelog succeeds" "$exit_code"
  assert_matches "task A at top level" "$output" "^- \`${task_a}\` - Task A$"
  assert_matches "task A1 nested below A" "$output" "^  - \`${task_a1}\` - Task A1$"
  assert_matches "checkpoint line with 8-char git id" "$output" '^- `[0-9a-f]{8}` - project work$'
  assert_not_contains "no in-progress markers" "$output" "[IN-PROGRESS]"
  # The checkpoint section follows the tree section directly, with no blank line.
  assert_matches "checkpoint follows the tree immediately" \
    "$(printf '%s\n' "$output" | sed -n '3p')" '^- `[0-9a-f]{8}` - project work$'
  assert_not_matches "no blank line between sections" "$output" '^$'
  assert_line_count "one line per task plus one checkpoint" "$output" 3
}


test_task_changelog__depth_limits_subtask_levels() {
  setup_workspace "changelog-depth"
  _setup_two_level_tree

  depth_0="" depth_1="" depth_2="" unlimited="" exit_code=0
  depth_0=$(run_tt task changelog --since main --depth 0 2>/dev/null) || exit_code=$?
  depth_1=$(run_tt task changelog --since main --depth 1 2>/dev/null) || exit_code=$?
  depth_2=$(run_tt task changelog --since main --depth 2 2>/dev/null) || exit_code=$?
  unlimited=$(run_tt task changelog --since main 2>/dev/null) || exit_code=$?
  assert_success "changelog succeeds at every depth" "$exit_code"

  assert_eq "depth 0 reports checkpoints only" \
    "$depth_0" "$(printf -- '- `%s` - project work' "$(get_bookmark_commit "$proj_id" | cut -c1-8)")"

  assert_matches "depth 1 reports the checked-in task" "$depth_1" "^- \`${task_a}\` - Task A$"
  assert_not_contains "depth 1 omits its subtask" "$depth_1" "$task_a1"
  assert_contains "depth 1 still reports checkpoints" "$depth_1" "project work"

  assert_matches "depth 2 reports the nested subtask" "$depth_2" "^  - \`${task_a1}\` - Task A1$"
  assert_eq "omitted --depth matches the deepest level" "$unlimited" "$depth_2"
}


test_task_changelog__depth_zero_without_checkpoints_is_silent() {
  setup_workspace "changelog-depth-zero"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "work" > "$TT_REPO/work.txt"
  checkpoint_task "t work" >/dev/null || true
  run_tt task checkin "$task_id" --complete >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task changelog --task "$proj_id" --since main --depth 0 2>/dev/null) || exit_code=$?
  assert_success "changelog succeeds" "$exit_code"
  assert_output_empty "no output when only subtask checkins exist" "$output"
}


test_task_changelog__invalid_depth_rejected() {
  setup_workspace "changelog-depth-invalid"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task changelog --depth "abc" 2>&1) || exit_code=$?
  assert_failure "non-numeric depth rejected" "$exit_code"
  assert_contains "usage shown" "$output" "Usage:"

  exit_code=0
  run_tt task changelog --depth "-1" >/dev/null 2>&1 || exit_code=$?
  assert_failure "negative depth rejected" "$exit_code"

  exit_code=0
  run_tt task changelog --depth >/dev/null 2>&1 || exit_code=$?
  assert_failure "missing depth value rejected" "$exit_code"
}


test_task_changelog__checkpoint_ids_are_git_commit_ids() {
  setup_workspace "changelog-commit-ids"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "content" > "$TT_REPO/file.txt"
  checkpoint_task "recorded work" >/dev/null || true

  commit_id=$(get_bookmark_commit "$task_id")
  change_id=$(jj -R "$TT_REPO" log --ignore-working-copy -r "$task_id" --no-graph -T 'change_id.short(8)')

  output="" exit_code=0
  output=$(run_tt task changelog 2>/dev/null) || exit_code=$?
  assert_success "changelog succeeds" "$exit_code"
  assert_eq "checkpoint line uses the git commit id" \
    "$output" "$(printf -- '- `%s` - recorded work' "${commit_id:0:8}")"
  assert_not_contains "jj change id not used" "$output" "$change_id"
}


test_task_changelog__no_work_produces_no_output() {
  setup_workspace "changelog-empty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task changelog 2>/dev/null) || exit_code=$?
  assert_success "changelog succeeds with nothing to report" "$exit_code"
  assert_output_empty "no output" "$output"
}


test_task_changelog__checkins_only() {
  setup_workspace "changelog-checkins-only"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "work" > "$TT_REPO/work.txt"
  checkpoint_task "t work" >/dev/null || true
  run_tt task checkin "$task_id" --complete >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task changelog --task "$proj_id" --since main 2>/dev/null) || exit_code=$?
  assert_success "changelog succeeds" "$exit_code"
  assert_eq "tree section alone" \
    "$output" "$(printf -- '- `%s` - T' "$task_id")"
}


test_task_changelog__partial_checkin_flagged_in_progress() {
  setup_workspace "changelog-partial"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "partial" > "$TT_REPO/partial.txt"
  checkpoint_task "partial work" >/dev/null || true
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task changelog --task "$proj_id" --since main 2>/dev/null) || exit_code=$?
  assert_success "changelog succeeds" "$exit_code"
  assert_eq "in-progress task flagged" \
    "$output" "$(printf -- '- `%s` [IN-PROGRESS] - T' "$task_id")"
}


test_task_changelog__repeat_checkin_deduplicated() {
  setup_workspace "changelog-dedupe"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # First task is checked in once, before the repeatedly checked-in task exists,
  # so it establishes the expected ordering of the entries.
  first_id=$(create_task "first" "First") || true
  checkout_task "$first_id" >/dev/null || true
  echo "first" > "$TT_REPO/first.txt"
  checkpoint_task "first work" >/dev/null || true
  run_tt task checkin "$first_id" --complete >/dev/null 2>&1 || true

  checkout_task "$proj_id" >/dev/null || true
  repeat_id=$(create_task "repeat" "Repeat") || true
  checkout_task "$repeat_id" >/dev/null || true
  echo "one" > "$TT_REPO/one.txt"
  checkpoint_task "first half" >/dev/null || true
  run_tt task checkin "$repeat_id" >/dev/null 2>&1 || true

  # More work on the same task, then a second (completing) checkin. The rebase
  # picks up the parent tip advanced by the partial checkin.
  checkout_task "$repeat_id" >/dev/null || true
  echo "two" > "$TT_REPO/two.txt"
  checkpoint_task "second half" >/dev/null || true
  run_tt task checkin "$repeat_id" --complete --rebase >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task changelog --task "$proj_id" --since main 2>/dev/null) || exit_code=$?
  assert_success "changelog succeeds" "$exit_code"
  assert_line_count "each task listed once" "$output" 2
  assert_eq "entry keeps its first checkin position" \
    "$(printf '%s\n' "$output" | sed -n '2p')" \
    "$(printf -- '- `%s` - Repeat' "$repeat_id")"
  assert_not_contains "status taken from the latest checkin" "$output" "[IN-PROGRESS]"
}


test_task_changelog__deleted_task_still_listed() {
  setup_workspace "changelog-deleted"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "work" > "$TT_REPO/work.txt"
  checkpoint_task "t work" >/dev/null || true
  run_tt task checkin "$task_id" --complete --delete >/dev/null 2>&1 || true

  # Deletion happens after the checkin, so the checked-in title still resolves.
  output="" exit_code=0
  output=$(run_tt task changelog --task "$proj_id" --since main 2>/dev/null) || exit_code=$?
  assert_success "changelog succeeds" "$exit_code"
  assert_eq "deleted task still listed with its title" \
    "$output" "$(printf -- '- `%s` - T' "$task_id")"
}


test_task_changelog__unreadable_task_file_lists_id_only() {
  setup_workspace "changelog-unreadable"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "work" > "$TT_REPO/work.txt"
  checkpoint_task "t work" >/dev/null || true
  run_tt task checkin "$task_id" --complete >/dev/null 2>&1 || true

  # Drop the task's files from the checkin commit itself, leaving a real checkin
  # whose task file cannot be read at the revision that recorded it.
  jj -R "$TT_REPO" edit "$proj_id" >/dev/null 2>&1
  rm -rf "${TT_REPO:?}/.tt/task/${task_id#*/}"
  jj -R "$TT_REPO" new >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt task changelog --task "$proj_id" --since main 2>/dev/null) || exit_code=$?
  assert_success "changelog succeeds" "$exit_code"
  assert_eq "task listed by id alone" "$output" "$(printf -- '- `%s`' "$task_id")"
}


test_task_changelog__explicit_task() {
  setup_workspace "changelog-explicit"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "task work" >/dev/null || true
  # Switch away so the reported branch is not the current one.
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task changelog --task "$task_id" 2>/dev/null) || exit_code=$?
  assert_success "changelog with --task succeeds" "$exit_code"
  assert_matches "reports the requested branch" "$output" '^- `[0-9a-f]{8}` - task work$'
}


test_task_changelog__since_revision() {
  setup_workspace "changelog-since"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "early work" >/dev/null || true
  boundary=$(get_bookmark_commit "$task_id")
  checkpoint_task "late work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task changelog --since "$boundary" 2>/dev/null) || exit_code=$?
  assert_success "changelog with --since succeeds" "$exit_code"
  assert_contains "includes work after the reference commit" "$output" "late work"
  assert_not_contains "excludes work at or before it" "$output" "early work"
}


test_task_changelog__alias() {
  setup_workspace "changelog-alias"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "aliased work" >/dev/null || true

  canonical="" alias_output="" exit_code=0
  canonical=$(run_tt task changelog 2>/dev/null) || true
  alias_output=$(run_tt changelog 2>/dev/null) || exit_code=$?
  assert_success "alias succeeds" "$exit_code"
  assert_eq "alias output matches canonical command" "$alias_output" "$canonical"
}


test_task_changelog__not_on_task_branch() {
  setup_workspace "changelog-no-branch"

  output="" exit_code=0
  output=$(run_tt task changelog 2>&1) || exit_code=$?
  assert_failure "changelog fails when not on a task" "$exit_code"
  assert_contains "error message" "$output" "Error"
}


test_task_changelog__nonexistent_task() {
  setup_workspace "changelog-nonexistent"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task changelog --task "task/does-not-exist-00000000" 2>&1) || exit_code=$?
  assert_failure "changelog fails for a nonexistent task" "$exit_code"
  assert_contains "error message" "$output" "Error"
}


test_task_changelog__non_task_branch_rejected() {
  setup_workspace "changelog-non-task-branch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task changelog --task "main" 2>&1) || exit_code=$?
  assert_failure "changelog rejects a non-task branch" "$exit_code"
  assert_contains "error names the branch" "$output" "main"
}


test_task_changelog__unresolvable_since() {
  setup_workspace "changelog-bad-since"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task changelog --since "no-such-revision" 2>&1) || exit_code=$?
  assert_failure "changelog fails for an unresolvable revision" "$exit_code"
  assert_contains "error message" "$output" "Error"
}


test_task_changelog__project_branch_without_parent_requires_since() {
  setup_workspace "changelog-no-parent"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "project work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task changelog 2>&1) || exit_code=$?
  assert_failure "changelog fails without a parent branch" "$exit_code"
  assert_contains "error suggests --since" "$output" "--since"
}


run_tests "tt task changelog"
