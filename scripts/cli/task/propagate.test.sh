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


# Usage: parent_count REV — number of parents of REV.
parent_count() {
  jj -R "$REPO" log -r "$1" --no-graph \
    -T 'parents.map(|p| p.commit_id().short(8)).join(" ") ++ "\n"' 2>/dev/null \
    | tr ' ' '\n' | grep -c . | tr -d ' '
}


test_task_propagate__refuses_bookmark_on_working_copy() {
  setup_workspace "prop-bm-refusal"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "c" "Child") || true
  checkout_task "$proj_id" >/dev/null || true

  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  # Clean working copy carrying a bookmark unrelated to the propagation
  jj -R "$REPO" bookmark set unrelated -r '@' >/dev/null 2>&1

  bm_before=$(get_bookmark_commit "$child")
  output="" exit_code=0
  output=$(run_tt task propagate --from "$proj_id" 2>&1) || exit_code=$?
  assert_failure "bookmark on @ refused" "$exit_code"
  assert_contains "error names the bookmark" "$output" "unrelated"
  bm_after=$(get_bookmark_commit "$child")
  assert_eq "child bookmark unmoved" "$bm_after" "$bm_before"
}


test_task_propagate__dirty_wc_preserved_not_absorbed() {
  setup_workspace "prop-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "c" "Child") || true
  checkout_task "$proj_id" >/dev/null || true

  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  # Dirty WC: propagation must neither reject it nor fold it into any branch
  edit_file "$REPO/dirty-file.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt task propagate --from "$proj_id" 2>&1) || exit_code=$?
  assert_success "propagate succeeds with dirty WC" "$exit_code"
  assert_is_ancestor "child updated" "$proj_id" "$child"
  assert_file_exists "dirty file still on disk" "$REPO/dirty-file.txt"
  assert_wc_dirty "WC still dirty"
  assert_file_not_on_branch "dirty file not on parent branch" "$proj_id" "dirty-file.txt"
  assert_file_not_on_branch "dirty file not on child branch" "$child" "dirty-file.txt"
}


test_task_propagate__working_copy_not_moved() {
  setup_workspace "prop-wc-stays"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "c" "Child") || true
  checkout_task "$proj_id" >/dev/null || true

  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  # @ sits on the branch being propagated FROM, not on anything being
  # rewritten: it must be left exactly where it is.
  wc_before=$(get_wc_commit)
  run_tt task propagate --from "$proj_id" >/dev/null 2>&1 || true
  wc_after=$(get_wc_commit)
  assert_eq "@ commit unchanged" "$wc_after" "$wc_before"
  assert_current_task "still on the source branch" "$proj_id"
  assert_is_ancestor "child updated anyway" "$proj_id" "$child"
}


test_task_propagate__rebase_graph_shape() {
  setup_workspace "prop-graph-rebase"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "c" "Child") || true

  # Give the child a commit of its own so the rebased range is more than a stub.
  checkout_task "$child" >/dev/null || true
  edit_file "$REPO/child-work.txt" "work"
  checkpoint_task "Child work" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  parent_tip_before=$(get_full_commit_id "$proj_id")
  range_before=$(count_commits "${proj_id}..${child}")

  run_tt task propagate --from "$proj_id" >/dev/null 2>&1 || true

  # Linear result: the child's own commits now sit directly on the parent tip,
  # unchanged in number, with no merge commit anywhere in the range.
  assert_eq "parent tip did not move" "$(get_full_commit_id "$proj_id")" "$parent_tip_before"
  assert_is_ancestor "parent tip is an ancestor of the child" "$proj_id" "$child"
  assert_revset_count "range length preserved" "${proj_id}..${child}" "$range_before"
  assert_eq "child tip has a single parent" "$(parent_count "$child")" "1"
  assert_eq "range root hangs off the parent tip" \
    "$(get_full_commit_id "roots(${proj_id}..${child})-")" "$parent_tip_before"
  assert_file_on_branch "child kept its own work" "$child" "child-work.txt"
  assert_file_on_branch "child received the parent's change" "$child" "parent-file.txt"
  assert_no_conflicts "no conflicts after rebase propagation"
}


test_task_propagate__merge_graph_shape() {
  setup_workspace "prop-graph-merge"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child=$(create_task "c" "Child") || true

  checkout_task "$child" >/dev/null || true
  edit_file "$REPO/child-work.txt" "work"
  checkpoint_task "Child work" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true

  edit_file "parent-file.txt" "change"
  checkpoint_task "Parent update" >/dev/null || true

  child_tip_before=$(get_full_commit_id "$child")
  parent_tip_before=$(get_full_commit_id "$proj_id")

  output="" exit_code=0
  output=$(run_tt task propagate --from "$proj_id" --merge 2>&1) || exit_code=$?
  assert_success "merge propagate succeeds" "$exit_code"

  # The child tip is now a two-parent merge: its own former tip first, the
  # parent tip second.
  assert_eq "child tip is a merge" "$(parent_count "$child")" "2"
  assert_revset_count "the child's former tip is a parent of the merge" \
    "${child}- & ${child_tip_before}" 1
  assert_revset_count "the source branch tip is a parent of the merge" \
    "${child}- & ${parent_tip_before}" 1
  assert_is_ancestor "parent tip is an ancestor of the child" "$proj_id" "$child"
  assert_eq "parent tip did not move" "$(get_full_commit_id "$proj_id")" "$parent_tip_before"
  assert_file_on_branch "child kept its own work" "$child" "child-work.txt"
  assert_file_on_branch "child received the parent's change" "$child" "parent-file.txt"
  assert_no_conflicts "no conflicts after merge propagation"
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
