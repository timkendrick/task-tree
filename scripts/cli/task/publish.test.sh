#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


# Build a project branch holding task A, with subtask A1 checked into it, plus a
# checkpoint recorded directly on the project branch.
# Sets proj_id, task_a and task_a1.
_setup_two_level_tree() {
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  task_a=$(create_task "a" "Task A") || true
  checkout_task "$task_a" >/dev/null || true
  task_a1=$(create_task "a1" "Task A1") || true
  checkout_task "$task_a1" >/dev/null || true
  edit_file "a1.txt" "a1"
  checkpoint_task "a1 work" >/dev/null || true
  checkin_task "$task_a1" --complete >/dev/null 2>&1 || true

  checkout_task "$task_a" >/dev/null || true
  checkin_task "$task_a" --complete >/dev/null 2>&1 || true

  checkout_task "$proj_id" >/dev/null || true
  edit_file "p.txt" "p"
  checkpoint_task "project work" >/dev/null || true
}


test_task_publish__basic_publish_to_target() {
  setup_workspace "pub-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  edit_file "src/main.sh" "echo hello"
  checkpoint_task "Work" >/dev/null || true

  main_before=$(get_bookmark_commit "main")

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "main" -m "Ship it" 2>&1) || exit_code=$?
  assert_success "publish succeeds" "$exit_code"

  main_after=$(get_bookmark_commit "main")
  assert_neq "main advanced" "$main_before" "$main_after"
  assert_file_on_branch "scaffolding removed from main" "main" "src/main.sh"
  assert_file_not_on_branch ".tt/task NOT on main" "main" ".tt/task"
}


test_task_publish__non_project_branch_rejected() {
  setup_workspace "pub-notproject"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task publish "$task_id" --target "main" -m "Ship it" 2>&1) || exit_code=$?
  assert_failure "non-project publish rejected" "$exit_code"
  assert_contains "suggests checkin" "$output" "checkin"
}


test_task_publish__without_target_rejected() {
  setup_workspace "pub-notarget"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" 2>&1) || exit_code=$?
  assert_failure "missing target rejected" "$exit_code"
  assert_contains "error about target" "$output" "--target"
}


test_task_publish__non_existent_target_rejected() {
  setup_workspace "pub-badtarget"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "nonexistent" -m "Ship it" 2>&1) || exit_code=$?
  assert_failure "non-existent target rejected" "$exit_code"
}


test_task_publish__dirty_wc_rejected() {
  setup_workspace "pub-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  edit_file "dirty.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "main" -m "Ship it" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
}


test_task_publish__wc_stays_on_project_after_publish() {
  setup_workspace "pub-wc"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  run_tt task publish "$proj_id" --target "main" -m "Ship it" >/dev/null 2>&1 || true

  # After publish, WC should still be on the project branch
  assert_current_task "WC stays on project branch after publish" "$proj_id"
  assert_wc_clean "WC is clean after publish"
}


test_task_publish__records_transaction() {
  setup_workspace "pub-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task publish "$proj_id" --target "main" -m "Ship it" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after publish"
}


test_task_publish__help() {
  setup_workspace "publish-help"
  output="" exit_code=0
  output=$(run_tt task publish --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task publish"
  assert_required_usage_argument "argument: --target" "$output" "--target"
  assert_optional_usage_argument "argument: --force" "$output" "--force"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
  assert_optional_usage_argument "argument: --message" "$output" "--message" "-m"
  assert_optional_usage_argument "argument: --changelog" "$output" "--changelog"
  assert_optional_usage_argument "argument: --changelog-depth" "$output" "--changelog-depth"
}


test_task_publish__message_describes_publish_commit() {
  setup_workspace "pub-message"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  edit_file "src/main.sh" "echo hello"
  checkpoint_task "Work" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "main" -m "Ship the widget" 2>&1) || exit_code=$?
  assert_success "publish succeeds" "$exit_code"

  assert_eq "publish commit carries the message" \
    "$(get_commit_message_first_line "main")" \
    "[tt:task:${proj_id}:publish] Ship the widget"
  # The handoff commit is one of the merge's two parents; it keeps the project
  # title rather than the user's message.
  parent_messages=$(jj -R "$REPO" log -r 'main-' --no-graph \
    -T 'description.first_line() ++ "\n"' 2>/dev/null)
  assert_contains "handoff commit keeps the project title" \
    "$parent_messages" "[tt:task:${proj_id}:handoff] Project"
}


test_task_publish__empty_message_rejected() {
  setup_workspace "pub-empty-message"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  main_before=$(get_bookmark_commit "main")

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "main" -m "" 2>&1) || exit_code=$?
  assert_failure "empty message rejected" "$exit_code"
  assert_contains "reports the cancellation" "$output" "Publish cancelled."
  assert_eq "main did not advance" "$(get_bookmark_commit "main")" "$main_before"
}


test_task_publish__changelog_summarizes_work_since_target() {
  setup_workspace "pub-changelog"
  _setup_two_level_tree

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "main" -m "Ship it" --changelog 2>&1) || exit_code=$?
  assert_success "publish succeeds" "$exit_code"

  body=$(get_commit_message "main")
  assert_matches "message line is preserved" "$body" "^\[tt:task:${proj_id}:publish\] Ship it$"
  assert_matches "change summary header" "$body" '^Change summary:$'
  assert_matches "checked-in task reported" "$body" "^- \`${task_a}\` - Task A$"
  assert_matches "nested subtask keeps its indentation" "$body" "^  - \`${task_a1}\` - Task A1$"
  assert_matches "project checkpoint reported" "$body" '^- `[0-9a-f]{8}` - project work$'
  assert_not_contains "no placeholder when work exists" "$body" "No code changes"
}


test_task_publish__changelog_placeholder_when_no_work() {
  setup_workspace "pub-changelog-empty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "main" -m "Ship it" --changelog 2>&1) || exit_code=$?
  assert_success "publish succeeds" "$exit_code"

  body=$(get_commit_message "main")
  assert_matches "change summary header" "$body" '^Change summary:$'
  assert_matches "placeholder stands in for the changelog" "$body" '^No code changes$'
}


test_task_publish__changelog_covers_history_before_first_publish() {
  setup_workspace "pub-changelog-first"
  _setup_two_level_tree

  exit_code=0
  run_tt task publish "$proj_id" --target "main" -m "First" --changelog >/dev/null 2>&1 || exit_code=$?
  assert_success "first publish succeeds" "$exit_code"

  first_body=$(get_commit_message "main")
  assert_matches "first publish reports the whole project history" \
    "$first_body" "^- \`${task_a}\` - Task A$"
  assert_matches "first publish reports the project checkpoint" \
    "$first_body" '^- `[0-9a-f]{8}` - project work$'

  # A second publish measures from the first one, so it reports only newer work.
  checkout_task "$proj_id" >/dev/null || true
  edit_file "later.txt" "later"
  checkpoint_task "later work" >/dev/null || true

  exit_code=0
  run_tt task publish "$proj_id" --target "main" -m "Second" --changelog >/dev/null 2>&1 || exit_code=$?
  assert_success "second publish succeeds" "$exit_code"

  second_body=$(get_commit_message "main")
  assert_matches "second publish reports the new checkpoint" \
    "$second_body" '^- `[0-9a-f]{8}` - later work$'
  assert_not_contains "second publish omits already-published work" "$second_body" "$task_a"
  assert_not_contains "second publish omits the earlier checkpoint" "$second_body" "project work"
}


test_task_publish__changelog_depth_limits_levels() {
  setup_workspace "pub-changelog-depth"
  _setup_two_level_tree

  exit_code=0
  run_tt task publish "$proj_id" --target "main" -m "Ship it" \
    --changelog --changelog-depth 1 >/dev/null 2>&1 || exit_code=$?
  assert_success "publish succeeds" "$exit_code"

  body=$(get_commit_message "main")
  assert_matches "checked-in task reported" "$body" "^- \`${task_a}\` - Task A$"
  assert_not_contains "nested subtask omitted at depth 1" "$body" "$task_a1"
}


test_task_publish__changelog_depth_requires_changelog() {
  setup_workspace "pub-changelog-depth-alone"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "Work" >/dev/null || true

  main_before=$(get_bookmark_commit "main")

  output="" exit_code=0
  output=$(run_tt task publish "$proj_id" --target "main" -m "Ship it" \
    --changelog-depth 1 2>&1) || exit_code=$?
  assert_failure "depth without --changelog rejected" "$exit_code"
  assert_contains "usage shown" "$output" "Usage:"
  assert_eq "main did not advance" "$(get_bookmark_commit "main")" "$main_before"

  exit_code=0
  run_tt task publish "$proj_id" --target "main" -m "Ship it" \
    --changelog --changelog-depth "abc" >/dev/null 2>&1 || exit_code=$?
  assert_failure "non-numeric depth rejected" "$exit_code"
}


run_tests "tt task publish"
