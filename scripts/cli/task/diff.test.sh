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


test_task_diff__git_output_format() {
  setup_workspace "diff-git-format"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "hello diff" > "$TT_REPO/feature.txt"
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task diff 2>&1) || exit_code=$?
  assert_success "diff succeeds" "$exit_code"
  assert_matches "git diff header" "$output" '^diff --git a/feature\.txt b/feature\.txt'
  assert_contains "git new file mode" "$output" "new file mode"
  assert_matches "unified hunk header" "$output" '^@@ '
  assert_matches "added line" "$output" '^\+hello diff'
  # jj's native format would use "Added regular file ..." headers instead.
  assert_not_contains "not jj native format" "$output" "Added regular file"
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
  # Both metadata files are excluded, so neither their Git diff headers nor
  # their bodies (the TASK.md symlink's content is a '.tt/task/...' path)
  # appear anywhere in the output.
  assert_not_contains "metadata dir excluded" "$output" ".tt/"
  assert_not_contains "TASK.md symlink excluded" "$output" "TASK.md"
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
  assert_contains "metadata dir included" "$output" "diff --git a/.tt/"
  assert_matches "TASK.md symlink included" "$output" '^diff --git a/TASK\.md'
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


test_task_diff__all_alias() {
  setup_workspace "diff-all-alias"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "alias content" > "$TT_REPO/alias.txt"
  checkpoint_task "first commit" >/dev/null || true

  canonical="" alias_output="" exit_code=0
  canonical=$(run_tt task diff --task "$task_id" --all 2>&1) || true
  alias_output=$(run_tt diff --task "$task_id" --all 2>&1) || exit_code=$?
  assert_success "alias --all succeeds" "$exit_code"
  assert_eq "alias output matches canonical command" "$alias_output" "$canonical"
}

test_task_diff__all_current_only() {
  setup_workspace "diff-all-current-only"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "only change" > "$TT_REPO/only.txt"
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task diff --task "$task_id" --all 2>&1) || exit_code=$?
  assert_success "diff --all succeeds" "$exit_code"
  assert_contains "reports the only file" "$output" "only.txt"
}

test_task_diff__all_concatenates_historical_and_current() {
  setup_workspace "diff-all-concat"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "historical" > "$TT_REPO/historical.txt"
  checkpoint_task "w1" >/dev/null || true
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  checkout_task "$task_id" >/dev/null || true
  echo "current" > "$TT_REPO/current.txt"
  checkpoint_task "w2" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task diff --task "$task_id" --all 2>&1) || exit_code=$?
  assert_success "diff --all succeeds" "$exit_code"
  assert_contains "reports the historical component's file" "$output" "historical.txt"
  assert_contains "reports the current component's file" "$output" "current.txt"
  # The historical section should appear before the current one, oldest first.
  historical_pos=$(printf '%s\n' "$output" | grep -n 'historical.txt' | head -1 | cut -d: -f1)
  current_pos=$(printf '%s\n' "$output" | grep -n 'current.txt' | head -1 | cut -d: -f1)
  assert_eq "historical section precedes current section" \
    "$([[ "$historical_pos" -lt "$current_pos" ]] && echo yes || echo no)" "yes"
}

test_task_diff__all_excludes_metadata_by_default() {
  setup_workspace "diff-all-metadata-default"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "source" > "$TT_REPO/source.txt"
  checkpoint_task "w1" >/dev/null || true
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task diff --task "$task_id" --all 2>&1) || exit_code=$?
  assert_success "diff --all succeeds" "$exit_code"
  assert_contains "non-metadata file present" "$output" "source.txt"
  assert_not_contains "metadata dir excluded" "$output" ".tt/"
}

test_task_diff__all_include_metadata() {
  setup_workspace "diff-all-metadata-include"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo "source" > "$TT_REPO/source.txt"
  checkpoint_task "w1" >/dev/null || true
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt task diff --task "$task_id" --all --include-metadata 2>&1) || exit_code=$?
  assert_success "diff --all --include-metadata succeeds" "$exit_code"
  assert_contains "metadata dir included" "$output" "diff --git a/.tt/"
}

test_task_diff__all_rejects_project_branch() {
  setup_workspace "diff-all-project-rejected"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "project work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task diff --task "$proj_id" --all 2>&1) || exit_code=$?
  assert_failure "diff --all rejects a project branch" "$exit_code"
  assert_contains "error message" "$output" "Error"
}

test_task_diff__all_help() {
  setup_workspace "diff-all-help"
  output="" exit_code=0
  output=$(run_tt task diff --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_required_usage_argument "argument: --all" "$output" "--all"
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
