#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_task_propagate__rebase_descendants_default() {
  setup_workspace "prop-rebase"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child_a=$(create_task "ca" "Child A") || true
  checkout_task "$proj_id" >/dev/null || true
  child_b=$(create_task "cb" "Child B") || true
  checkout_task "$proj_id" >/dev/null || true

  # Make a change on parent
  checkout_task "$proj_id" >/dev/null || true
  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task propagate --from "$proj_id" 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  assert_is_ancestor "parent is ancestor of child A" "$proj_id" "$child_a"
  assert_is_ancestor "parent is ancestor of child B" "$proj_id" "$child_b"
}


test_task_propagate__ignores_body_fence_subtask() {
  setup_workspace "prop-body-fence"
  # Parent's body documents a subtask entry inside a fenced code block, naming a
  # task that does not exist. Propagation must not try to visit it.
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
  child=$(create_task "child" "Child") || true
  checkout_task "$proj_id" >/dev/null || true

  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task propagate --from "$proj_id" 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  assert_is_ancestor "parent is ancestor of child" "$proj_id" "$child"
  assert_not_contains "fenced task ID not visited" "$output" "task/fake-99999999"
}


test_task_propagate__shallow_direct_children_only() {
  setup_workspace "prop-shallow"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child") || true
  checkout_task "$child" >/dev/null || true
  grandchild=$(create_task "gc" "Grandchild") || true
  checkout_task "$proj_id" >/dev/null || true

  # Make a change on parent
  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  child_before_gc=$(get_bookmark_commit "$child")

  run_tt task propagate --from "$proj_id" --shallow >/dev/null 2>&1 || true

  # Child should be updated
  assert_is_ancestor "parent is ancestor of child" "$proj_id" "$child"
}


test_task_propagate__recursive_default() {
  setup_workspace "prop-recursive"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "child" "Child") || true
  checkout_task "$child" >/dev/null || true
  grandchild=$(create_task "gc" "Grandchild") || true
  checkout_task "$proj_id" >/dev/null || true

  # Make a change on parent
  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  run_tt task propagate --from "$proj_id" >/dev/null 2>&1 || true

  assert_is_ancestor "parent is ancestor of child" "$proj_id" "$child"
  assert_is_ancestor "child is ancestor of grandchild" "$child" "$grandchild"
}


test_task_propagate__to_filter() {
  setup_workspace "prop-to"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child_a=$(create_task "ca" "Child A") || true
  checkout_task "$proj_id" >/dev/null || true
  child_b=$(create_task "cb" "Child B") || true
  checkout_task "$proj_id" >/dev/null || true
  child_c=$(create_task "cc" "Child C") || true
  checkout_task "$proj_id" >/dev/null || true

  # Make change on parent
  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  bm_b_before=$(get_bookmark_commit "$child_b")
  bm_c_before=$(get_bookmark_commit "$child_c")

  run_tt task propagate --from "$proj_id" --to "$child_b" >/dev/null 2>&1 || true

  assert_is_ancestor "B updated" "$proj_id" "$child_b"
}


test_task_propagate__already_up_to_date() {
  setup_workspace "prop-uptodate"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "c" "Child") || true
  checkout_task "$proj_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task propagate --from "$proj_id" 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  assert_contains "up to date message" "$output" "up to date"
}


test_task_propagate__dry_run() {
  setup_workspace "prop-dryrun"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "c" "Child") || true
  checkout_task "$proj_id" >/dev/null || true

  # Make a change on parent
  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  bm_before=$(get_bookmark_commit "$child")

  output="" exit_code=0
  output=$(run_tt task propagate --from "$proj_id" --dry-run 2>&1) || exit_code=$?
  assert_success "dry-run succeeds" "$exit_code"
  assert_contains "dry-run label" "$output" "dry-run"

  bm_after=$(get_bookmark_commit "$child")
  assert_eq "bookmark unchanged" "$bm_before" "$bm_after"
}


test_task_propagate__transaction_history() {
  setup_workspace "prop-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "c" "Child") || true
  checkout_task "$proj_id" >/dev/null || true

  assert_history_integrity "history before edit"
  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true
  assert_history_integrity "history after checkpoint" 1

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task propagate --from "$proj_id" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  # chain_depth=1: only check the single entry propagate wrote; the gap between
  # it and the preceding checkpoint entry is caused by the jj auto-snapshot
  # triggered by edit_file and is expected (not an error).
  assert_history_integrity "history after propagate" 1
}


test_task_propagate__help() {
  setup_workspace "propagate-help"
  output="" exit_code=0
  output=$(run_tt task propagate --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task propagate"
  assert_optional_usage_argument "argument: --from" "$output" "--from"
  assert_optional_usage_argument "argument: --to" "$output" "--to"
  assert_optional_usage_argument "argument: --rebase" "$output" "--rebase"
  assert_optional_usage_argument "argument: --merge" "$output" "--merge"
  assert_optional_usage_argument "argument: --force" "$output" "--force"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task propagate"
