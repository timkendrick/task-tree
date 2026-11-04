#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_task_tree__basic_tree_output() {
  setup_workspace "tree-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child_a=$(create_task "ca" "Child A") || true
  checkout_task "$proj_id" >/dev/null || true
  child_b=$(create_task "cb" "Child B") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task tree 2>&1) || exit_code=$?
  assert_success "tree succeeds" "$exit_code"
  assert_contains "project in output" "$output" "project/proj-"
  assert_contains "child A in output" "$output" "Child A"
  assert_contains "child B in output" "$output" "Child B"
}


test_task_tree__focus_shows_current_chain() {
  setup_workspace "tree-focus"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child") || true
  checkout_task "$child" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task tree --focus 2>&1) || exit_code=$?
  assert_success "focus succeeds" "$exit_code"
  assert_contains "project in chain" "$output" "project/proj-"
  assert_contains "child in chain" "$output" "Child"
  # Current task is bold-formatted
  assert_contains "current task bold" "$output" "**"
}


test_task_tree__project_filter() {
  setup_workspace "tree-filter"
  proj_a=$(create_project "a" "Proj A") || true
  proj_b=$(create_project "b" "Proj B") || true

  output="" exit_code=0
  output=$(run_tt task tree --project "$proj_a" 2>&1) || exit_code=$?
  assert_success "filter succeeds" "$exit_code"
  assert_contains "proj A shown" "$output" "Proj A"
  assert_not_contains "proj B hidden" "$output" "Proj B"
}


test_task_tree__completed_subtask_with_x() {
  setup_workspace "tree-done"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "Task") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task tree 2>&1) || exit_code=$?
  assert_success "tree succeeds" "$exit_code"
  assert_contains "completed checkbox [x]" "$output" "[x]"
}


test_task_tree__body_with_frontmatter_fence() {
  setup_workspace "tree-body-fence"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  # Body documents frontmatter layout inside a fenced code block. The '---',
  # 'title:' and 'status:' lines within it must not be parsed as frontmatter.
  body=$(printf '%s\n' \
    'Frontmatter should look like:' \
    '' \
    '```markdown' \
    '---' \
    'title:' \
    'status:' \
    '---' \
    '```')
  task_id=$(create_task "fenced" "Fenced Body Task" "$body") || true
  checkout_task "$task_id" >/dev/null || true
  complete_task >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task tree 2>&1) || exit_code=$?
  assert_success "tree succeeds" "$exit_code"
  assert_contains "real title shown" "$output" "Fenced Body Task"
  assert_not_contains "no unknown-status checkbox" "$output" "[?]"
  assert_not_contains "title not lost" "$output" "(no title)"
  assert_matches "completed checkbox on fenced task" "$output" \
    '\[x\].*Fenced Body Task'
}


test_task_tree__empty_project_no_subtasks() {
  setup_workspace "tree-empty"
  proj_id=$(create_project "proj" "Project") || true

  output="" exit_code=0
  output=$(run_tt task tree 2>&1) || exit_code=$?
  assert_success "tree succeeds" "$exit_code"
  assert_contains "project in output" "$output" "project/proj-"
}


test_task_tree__focus_with_no_current_branch_fails() {
  setup_workspace "tree-nofocus"
  # On main by default
  output="" exit_code=0
  output=$(run_tt task tree --focus 2>&1) || exit_code=$?
  assert_failure "focus without current fails" "$exit_code"
}


test_task_tree__checked_in_task_read_from_parent() {
  setup_workspace "tree-merged"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Original Title") || true
  checkout_task "$task_id" || true
  checkin_task --complete >/dev/null || true
  checkout_task "$proj_id" || true
  run_tt task edit "$task_id" --title "Edited On Own Branch" >/dev/null 2>&1 || true

  output=""
  output=$(run_tt task tree 2>&1) || true
  assert_contains "title from the parent copy" "$output" \
    "   - [x] [$task_id](.tt/task/${task_id#*/}/TASK.md) Original Title"
  assert_not_contains "own branch title not shown" "$output" "Edited On Own Branch"
}


test_task_tree__orphaned_subtree_shown_once() {
  setup_workspace "tree-orphans"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  parent_id=$(create_task "parent" "Orphan Parent") || true
  checkout_task "$parent_id" || true
  child_id=$(create_task "child" "Orphan Child") || true
  checkout_task "$proj_id" || true
  other_proj=$(create_project "other" "Other Project") || true
  jj -R "$REPO" bookmark delete "$proj_id" >/dev/null 2>&1

  output=""
  output=$(run_tt task tree 2>/dev/null) || true
  assert_not_contains "orphans hidden by default" "$output" "Orphan Parent"

  output=$(run_tt task tree --all 2>/dev/null) || true
  assert_contains "orphan section" "$output" "Orphaned tasks:"
  assert_contains "unlisted orphan starts a subtree" "$output" \
    "$(printf -- '- [ ] [%s](.tt/task/%s/TASK.md) Orphan Parent\n   - [ ] [%s](.tt/task/%s/TASK.md) Orphan Child' \
      "$parent_id" "${parent_id#*/}" "$child_id" "${child_id#*/}")"
  assert_eq "listed orphan shown once" \
    "$(printf '%s\n' "$output" | grep -c "Orphan Child")" "1"
}


test_task_tree__project_filter_keeps_other_projects_tasks_out_of_orphans() {
  setup_workspace "tree-filter-detached"
  proj_a=$(create_project "a" "Proj A") || true
  proj_b=$(create_project "b" "Proj B") || true
  checkout_task "$proj_b" || true
  task_b=$(create_task "tb" "Task Under B") || true

  output=""
  output=$(run_tt task tree --project "$proj_a" --detached 2>/dev/null) || true
  assert_contains "proj A shown" "$output" "Proj A"
  assert_not_contains "task under B is not an orphan" "$output" "Task Under B"
  assert_not_contains "no orphan section" "$output" "Orphaned tasks:"
}


test_task_tree__focus_hides_siblings_and_shows_descendants() {
  setup_workspace "tree-focus-nested"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  sibling=$(create_task "sibling" "Sibling Task") || true
  checkout_task "$proj_id" || true
  current=$(create_task "current" "Current Task") || true
  checkout_task "$current" || true
  child=$(create_task "child" "Child Task") || true
  checkout_task "$current" || true

  output="" exit_code=0
  output=$(run_tt task tree --focus 2>/dev/null) || exit_code=$?
  assert_success "focus succeeds" "$exit_code"
  assert_not_contains "sibling hidden" "$output" "Sibling Task"
  assert_eq "chain with current bold and its subtree" "$output" "$(printf '%s\n' \
    "- [-] [$proj_id](.tt/task/${proj_id#*/}/TASK.md) Project" \
    "   - [-] **[$current](.tt/task/${current#*/}/TASK.md) Current Task**" \
    "      - [ ] [$child](.tt/task/${child#*/}/TASK.md) Child Task")"
}


test_task_tree__help() {
  setup_workspace "tree-help"
  output="" exit_code=0
  output=$(run_tt task tree --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task tree"
  assert_optional_usage_argument "argument: --project" "$output" "--project"
  assert_optional_usage_argument "argument: --detached" "$output" "--detached"
  assert_optional_usage_argument "argument: --all" "$output" "--all"
  assert_optional_usage_argument "argument: --focus" "$output" "--focus"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task tree"
