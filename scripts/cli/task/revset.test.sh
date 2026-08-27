#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_revset__basic_jj_revset() {
  setup_workspace "revset-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task revset 2>&1) || exit_code=$?
  assert_success "revset succeeds" "$exit_code"
  assert_contains "output contains parent bookmark" "$output" "$proj_id"
  assert_matches "output is a range" "$output" '\.\.@-$'
}


test_task_revset__explicit_task() {
  setup_workspace "revset-explicit"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task revset --task "$task_id" 2>&1) || exit_code=$?
  assert_success "revset with --task succeeds" "$exit_code"
  assert_eq "output is parent..task" "$output" "${proj_id}..${task_id}"
}


test_task_revset__trailing_commits_empty_wc() {
  setup_workspace "revset-trailing-empty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "first commit" >/dev/null || true
  # Create a commit beyond the bookmark
  jj -R "$TT_REPO" new -m "trailing commit" >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt task revset 2>&1) || exit_code=$?
  assert_success "revset succeeds with trailing commits" "$exit_code"
  # Upper bound should be @- since working copy is empty
  assert_matches "upper bound is @-" "$output" '\.\.@-$'
}


test_task_revset__trailing_commits_nonempty_wc() {
  setup_workspace "revset-trailing-nonempty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "first commit" >/dev/null || true
  # Make working copy non-empty
  echo "change" > "$TT_REPO/dirty.txt"

  output="" exit_code=0
  output=$(run_tt task revset 2>&1) || exit_code=$?
  assert_success "revset succeeds with dirty wc" "$exit_code"
  assert_matches "upper bound is @" "$output" '\.\.@$'
}


test_task_revset__git_mode() {
  setup_workspace "revset-git"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task revset --task "$task_id" --git 2>&1) || exit_code=$?
  assert_success "revset --git succeeds" "$exit_code"
  # Should be two 40-char hex commit IDs separated by ..
  assert_matches "git range format" "$output" '^[0-9a-f]{40}\.\.[0-9a-f]{40}$'
}


test_task_revset__not_on_task_branch() {
  setup_workspace "revset-no-branch"
  output="" exit_code=0
  output=$(run_tt task revset 2>&1) || exit_code=$?
  assert_failure "revset fails when not on task" "$exit_code"
  assert_contains "error message" "$output" "Error"
}


test_task_revset__nonexistent_task() {
  setup_workspace "revset-nonexistent"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task revset --task "task/does-not-exist-00000000" 2>&1) || exit_code=$?
  assert_failure "revset fails for nonexistent task" "$exit_code"
  assert_contains "error message" "$output" "Error"
}


test_task_revset__alias() {
  setup_workspace "revset-alias"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt revset --task "$task_id" 2>&1) || exit_code=$?
  assert_success "alias works" "$exit_code"
  assert_eq "alias output matches" "$output" "${proj_id}..${task_id}"
}


test_task_revset__all_current_only() {
  setup_workspace "revset-all-current-only"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "first commit" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task revset --task "$task_id" --all 2>&1) || exit_code=$?
  assert_success "revset --all succeeds" "$exit_code"
  assert_eq "single current component, jj union of one range" \
    "$output" "(${proj_id}..${task_id})"
}

test_task_revset__all_includes_historical_and_current() {
  setup_workspace "revset-all-historical-and-current"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo w1 > "$TT_REPO/w1.txt"
  checkpoint_task "w1" >/dev/null || true
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  checkout_task "$task_id" >/dev/null || true
  echo w2 > "$TT_REPO/w2.txt"
  checkpoint_task "w2" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task revset --task "$task_id" --all 2>&1) || exit_code=$?
  assert_success "revset --all succeeds" "$exit_code"
  assert_contains "joins two components with a union" "$output" " | "
  assert_matches "jj union of two parenthesized ranges" "$output" '^\([0-9a-f]+\.\.[0-9a-f]+\) \| \(.+\.\.task/t-.+\)$'
}

test_task_revset__all_git_mode_multiple_lines() {
  setup_workspace "revset-all-git"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo w1 > "$TT_REPO/w1.txt"
  checkpoint_task "w1" >/dev/null || true
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true

  checkout_task "$task_id" >/dev/null || true
  echo w2 > "$TT_REPO/w2.txt"
  checkpoint_task "w2" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task revset --task "$task_id" --all --git 2>&1) || exit_code=$?
  assert_success "revset --all --git succeeds" "$exit_code"
  assert_line_count "one immutable range per component" "$output" 2
  assert_matches "first line is a 40-char hex git range" \
    "$(printf '%s\n' "$output" | sed -n '1p')" '^[0-9a-f]{40}\.\.[0-9a-f]{40}$'
  assert_matches "second line is a 40-char hex git range" \
    "$(printf '%s\n' "$output" | sed -n '2p')" '^[0-9a-f]{40}\.\.[0-9a-f]{40}$'
}

test_task_revset__all_rejects_project_branch() {
  setup_workspace "revset-all-project-rejected"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "project work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task revset --task "$proj_id" --all 2>&1) || exit_code=$?
  assert_failure "revset --all rejects a project branch" "$exit_code"
  assert_contains "error message" "$output" "Error"
}

test_task_revset__all_help() {
  setup_workspace "revset-all-help"
  output="" exit_code=0
  output=$(run_tt task revset --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_required_usage_argument "argument: --all" "$output" "--all"
}

test_task_revset__all_alias() {
  setup_workspace "revset-all-alias"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "first commit" >/dev/null || true

  canonical="" alias_output="" exit_code=0
  canonical=$(run_tt task revset --task "$task_id" --all 2>&1) || true
  alias_output=$(run_tt revset --task "$task_id" --all 2>&1) || exit_code=$?
  assert_success "alias --all succeeds" "$exit_code"
  assert_eq "alias output matches canonical command" "$alias_output" "$canonical"
}

test_task_revset__help() {
  setup_workspace "revset-help"
  output="" exit_code=0
  output=$(run_tt task revset --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task revset"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --git" "$output" "--git"
}


run_tests "tt task revset"
