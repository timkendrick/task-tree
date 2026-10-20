#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


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
  assert_task_symlink_at_rev "the child still points TASK.md at itself" "$child" "$child"
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

  # The child tip is now a two-parent merge. The order is part of the contract:
  # the receiving branch — here the child — is always the first parent and the
  # incoming line the second, which is what tells a branch built on top of
  # another from one merged into it.
  assert_eq "child tip is a merge" "$(parent_count "$child")" "2"
  merge_parents=$(jj -R "$REPO" log -r "$child" --no-graph \
    -T 'parents.map(|c| c.commit_id()).join(" ")' 2>/dev/null)
  assert_eq "the receiving child branch is the first parent" \
    "${merge_parents%% *}" "$child_tip_before"
  assert_eq "the incoming parent tip is the second parent" \
    "${merge_parents##* }" "$parent_tip_before"
  assert_commit_message_first_line "the merge is labelled as a propagate of the parent" \
    "$child" "[tt:task:$proj_id:propagate] Project"
  assert_task_symlink_at_rev "the merge points TASK.md at the child" "$child" "$child"
  assert_is_ancestor "parent tip is an ancestor of the child" "$proj_id" "$child"
  assert_eq "parent tip did not move" "$(get_full_commit_id "$proj_id")" "$parent_tip_before"
  assert_file_on_branch "child kept its own work" "$child" "child-work.txt"
  assert_file_on_branch "child received the parent's change" "$child" "parent-file.txt"
  assert_no_conflicts "no conflicts after merge propagation"
}


# Propagation reparents every sibling branch onto the tip a check-in has just
# created, so each sibling ends up descending from the fork point of a worktree
# parked on the receiving branch's previous tip. That worktree is behind the
# branch it was always on, and must be reported as such rather than as sitting
# on whichever sibling moved last.
test_task_propagate__parent_worktree_keeps_its_branch() {
  setup_workspace "prop-parent-worktree"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  sibling=$(create_task "sib" "Sibling") || true
  incoming=$(create_task "incoming" "Incoming") || true

  # The sibling needs work of its own, so propagation has a range to reparent.
  checkout_task "$sibling" >/dev/null 2>&1 || true
  edit_file "sibling-work.txt" "work"
  checkpoint_task "Sibling work" >/dev/null || true

  # The project's worktree is parked above the project tip: this is the
  # worktree the check-in below leaves behind. The canonical repository is
  # parked there too, and is left behind without being reported.
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  proj_wt=$(create_task_worktree "$proj_id")

  wt=$(create_task_worktree "$incoming")
  printf 'work\n' > "$wt/incoming-work.txt"
  run_tt_in_worktree "$wt" task checkpoint -m "Incoming work" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_tt_in_worktree "$wt" task checkin --complete --propagate 2>&1) || exit_code=$?
  assert_success "checkin with propagation succeeds" "$exit_code"
  assert_is_ancestor "the sibling was reparented onto the new project tip" \
    "$proj_id" "$sibling"

  assert_contains "the project worktree is reported behind its own branch" \
    "$output" "$proj_wt ($proj_id)"
  assert_not_contains "the project worktree is not attributed to the sibling" \
    "$output" "$proj_wt ($sibling)"
  assert_not_contains "the project worktree is not attributed to the checked-in task" \
    "$output" "$proj_wt ($incoming)"
  assert_not_contains "the canonical repository is not reported" "$output" "$REPO ("
}


# ---------------------------------------------------------------------------
# TASK.md on the child's line
# ---------------------------------------------------------------------------

# Project PROJ with child CHILD. The child records one checkpoint
# ("Child work"), and is then checked in while still IN-PROGRESS, so its whole
# history is in the project's. The working copy is left on the project.
_setup_partial_checkin() {
  PROJ=$(create_project "proj" "Project") || true
  checkout_task "$PROJ" >/dev/null || true
  CHILD=$(create_task "c" "Child") || true
  checkout_task "$CHILD" >/dev/null || true
  edit_file "$REPO/child-work.txt" "work"
  checkpoint_task "Child work" >/dev/null || true
  run_tt task checkin "$CHILD" >/dev/null 2>&1 || true
  checkout_task "$PROJ" >/dev/null || true
}

# Adds a checkpoint to the current task, writing FILE.
# Usage: _add_work FILE MESSAGE
_add_work() {
  edit_file "$REPO/$1" "$2"
  checkpoint_task "$2" >/dev/null || true
}

# Asserts that every commit in REVSET points TASK.md at TASK_ID.
# Usage: _assert_range_symlink LABEL REVSET TASK_ID
_assert_range_symlink() {
  local label="$1" revset="$2" task_id="$3"
  local commits commit wrong=''
  commits="$(jj -R "$REPO" log -r "$revset" --no-graph -T 'commit_id ++ "\n"' 2>/dev/null)"
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    [[ "$(get_symlink_target_at_rev "$commit" TASK.md)" == ".tt/task/${task_id#*/}/TASK.md" ]] \
      || wrong+="${commit:0:8} "
  done <<< "$commits"
  assert_output_not_empty "$label (range is not empty)" "$commits"
  assert_eq "$label" "$wrong" ""
}

# Asserts that CHILD's tip is a fork commit of CHILD sitting directly on
# PARENT's tip, and points TASK.md at CHILD.
# Usage: _assert_forked_onto LABEL CHILD PARENT TITLE
_assert_forked_onto() {
  local label="$1" child="$2" parent="$3" title="$4"
  assert_commit_message_first_line "$label: the child tip is a fork commit" \
    "$child" "[tt:task:$child:fork] $title"
  assert_eq "$label: the fork commit sits on the parent tip" \
    "$(get_full_commit_id "${child}-")" "$(get_full_commit_id "$parent")"
  assert_task_symlink_at_rev "$label: TASK.md points at the child" "$child" "$child"
}

test_task_propagate__up_to_date_in_progress_child_forks_rebase() {
  setup_workspace "prop-fork-rebase"
  _setup_partial_checkin

  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  assert_contains "the fork commit is announced" "$output" "creating fork commit"
  _assert_forked_onto "rebase" "$CHILD" "$PROJ" "Child"
  assert_task_status "the status does not change" "$CHILD" "IN-PROGRESS"
}

test_task_propagate__up_to_date_in_progress_child_forks_merge() {
  setup_workspace "prop-fork-merge"
  _setup_partial_checkin

  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" --merge 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  _assert_forked_onto "merge" "$CHILD" "$PROJ" "Child"
  assert_eq "the fork commit is not a merge" "$(parent_count "$CHILD")" "1"
  assert_task_status "the status does not change" "$CHILD" "IN-PROGRESS"
}

test_task_propagate__up_to_date_done_child_untouched() {
  setup_workspace "prop-fork-done"
  PROJ=$(create_project "proj" "Project") || true
  checkout_task "$PROJ" >/dev/null || true
  CHILD=$(create_task "c" "Child") || true
  checkout_task "$CHILD" >/dev/null || true
  _add_work "child-work.txt" "Child work"
  run_tt task checkin "$CHILD" --complete >/dev/null 2>&1 || true
  checkout_task "$PROJ" >/dev/null || true

  bm_before=$(get_bookmark_commit "$CHILD")
  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  assert_contains "the child is reported up to date" "$output" "$CHILD: already up to date"
  assert_eq "the child bookmark does not move" "$(get_bookmark_commit "$CHILD")" "$bm_before"
}

test_task_propagate__unreadable_child_task_file_counts_as_done() {
  setup_workspace "prop-fork-unreadable"
  PROJ=$(create_project "proj" "Project") || true
  checkout_task "$PROJ" >/dev/null || true
  local before_child
  before_child=$(get_bookmark_commit "$PROJ")
  CHILD=$(create_task "c" "Child") || true

  # Park the child on a project commit that predates its task file: its whole
  # history is in the project's, and its task file cannot be read at its tip.
  jj -R "$REPO" bookmark set "$CHILD" -r "$before_child" --allow-backwards >/dev/null 2>&1
  assert_eq "the fixture leaves the child's task file unreadable" \
    "$(jj -R "$REPO" file show -r "$CHILD" ".tt/task/${CHILD#task/}/TASK.md" 2>/dev/null)" ""

  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  assert_contains "the child is reported up to date" "$output" "$CHILD: already up to date"
  assert_not_contains "no fork commit is created" "$output" "creating fork commit"
  assert_eq "the child bookmark does not move" "$(get_bookmark_commit "$CHILD")" "$before_child"
}

test_task_propagate__checkin_propagate_forks_the_checked_in_child() {
  setup_workspace "prop-fork-checkin"
  PROJ=$(create_project "proj" "Project") || true
  checkout_task "$PROJ" >/dev/null || true
  CHILD=$(create_task "c" "Child") || true
  checkout_task "$CHILD" >/dev/null || true
  _add_work "child-work.txt" "Child work"

  output="" exit_code=0
  output=$(run_tt task checkin "$CHILD" --propagate 2>&1) || exit_code=$?
  assert_success "partial checkin with propagation succeeds" "$exit_code"
  _assert_forked_onto "checkin --propagate" "$CHILD" "$PROJ" "Child"
  assert_task_status "the child is still in progress" "$CHILD" "IN-PROGRESS"
}

test_task_propagate__rebase_after_partial_checkin_forks_underneath() {
  setup_workspace "prop-fork-rebase-more-work"
  _setup_partial_checkin
  checkout_task "$CHILD" >/dev/null || true
  _add_work "more-work.txt" "More work"
  checkout_task "$PROJ" >/dev/null || true
  _add_work "parent-file.txt" "Parent update"

  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  assert_commit_message_first_line "the fork commit is the root of the range" \
    "roots(${PROJ}..${CHILD})" "[tt:task:$CHILD:fork] Child"
  assert_eq "the fork commit sits on the parent tip" \
    "$(get_full_commit_id "roots(${PROJ}..${CHILD})-")" "$(get_full_commit_id "$PROJ")"
  assert_revset_count "the range is the fork commit and the new work" "${PROJ}..${CHILD}" "2"
  _assert_range_symlink "every commit on the child's line points at the child" \
    "${PROJ}..${CHILD}" "$CHILD"
  assert_file_on_branch "the child received the parent's change" "$CHILD" "parent-file.txt"
  assert_no_conflicts "no conflicts" "${PROJ}..${CHILD}"

  # A second propagation without a new checkin hangs the range off the
  # parent's old tip, which points at the parent: no second fork commit.
  _add_work "parent-file-2.txt" "Parent update 2"
  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" 2>&1) || exit_code=$?
  assert_success "second propagate succeeds" "$exit_code"
  assert_revset_count "no second fork commit" "${PROJ}..${CHILD}" "2"
  assert_commit_message_first_line "the existing fork commit is still the root" \
    "roots(${PROJ}..${CHILD})" "[tt:task:$CHILD:fork] Child"
  _assert_range_symlink "the child's line still points at the child" \
    "${PROJ}..${CHILD}" "$CHILD"
}

test_task_propagate__rebase_done_child_after_partial_checkin_forks() {
  setup_workspace "prop-fork-rebase-done"
  _setup_partial_checkin
  checkout_task "$CHILD" >/dev/null || true
  _add_work "more-work.txt" "More work"
  complete_task >/dev/null || true
  checkout_task "$PROJ" >/dev/null || true
  _add_work "parent-file.txt" "Parent update"

  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  assert_commit_message_first_line "the fork commit is the root of the range" \
    "roots(${PROJ}..${CHILD})" "[tt:task:$CHILD:fork] Child"
  assert_revset_count "fork commit, new work and completion" "${PROJ}..${CHILD}" "3"
  _assert_range_symlink "every commit on the child's line points at the child" \
    "${PROJ}..${CHILD}" "$CHILD"
  assert_task_status "the child stays DONE" "$CHILD" "DONE"
}

# The grandchild was checked into the child after the child's own partial
# checkin. Without a fork commit underneath, the grandchild's fork commit
# would conflict on TASK.md once moved onto the project's tip.
test_task_propagate__rebase_nested_grandchild_has_no_conflicts() {
  setup_workspace "prop-fork-nested"
  _setup_partial_checkin
  GRANDCHILD=$(create_task_under "$CHILD" "g" "Grandchild") || true
  checkout_task "$GRANDCHILD" >/dev/null || true
  _add_work "grandchild-work.txt" "Grandchild work"
  run_tt task checkin "$GRANDCHILD" --complete >/dev/null 2>&1 || true
  checkout_task "$PROJ" >/dev/null || true
  _add_work "parent-file.txt" "Parent update"

  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  assert_no_conflicts "no conflicts on the child's line" "${PROJ}..${CHILD}"
  assert_commit_message_first_line "the fork commit is the root of the range" \
    "roots(${PROJ}..${CHILD})" "[tt:task:$CHILD:fork] Child"
  _assert_range_symlink "the child's own line points at the child" \
    "first_ancestors(${CHILD}) ~ ::${PROJ}" "$CHILD"
  _assert_range_symlink "the grandchild's commits point at the grandchild" \
    "(${PROJ}..${GRANDCHILD}) ~ first_ancestors(${CHILD})" "$GRANDCHILD"
  assert_task_symlink_at_rev "the grandchild tip points at the grandchild" \
    "$GRANDCHILD" "$GRANDCHILD"
}

test_task_propagate__merge_after_partial_checkin_keeps_child_symlink() {
  setup_workspace "prop-merge-partial"
  _setup_partial_checkin
  checkout_task "$CHILD" >/dev/null || true
  _add_work "more-work.txt" "More work"
  checkout_task "$PROJ" >/dev/null || true
  _add_work "parent-file.txt" "Parent update"

  child_tip_before=$(get_full_commit_id "$CHILD")
  parent_tip_before=$(get_full_commit_id "$PROJ")

  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" --merge 2>&1) || exit_code=$?
  assert_success "merge propagate succeeds" "$exit_code"

  # The merge base points TASK.md at the child, and the project's side points
  # it back at the project in the partial checkin's handoff.
  assert_eq "the child tip is a merge" "$(parent_count "$CHILD")" "2"
  merge_parents=$(jj -R "$REPO" log -r "$CHILD" --no-graph \
    -T 'parents.map(|c| c.commit_id()).join(" ")' 2>/dev/null)
  assert_eq "the child's old tip is the first parent" "${merge_parents%% *}" "$child_tip_before"
  assert_eq "the parent tip is the second parent" "${merge_parents##* }" "$parent_tip_before"
  assert_commit_message_first_line "the merge is labelled as a propagate of the parent" \
    "$CHILD" "[tt:task:$PROJ:propagate] Project"
  assert_task_symlink_at_rev "the merge points TASK.md at the child" "$CHILD" "$CHILD"
  assert_revset_count "the new work and the merge, no extra commit" "${PROJ}..${CHILD}" "2"
  assert_no_conflicts "no conflicts" "$CHILD"
}

test_task_propagate__dry_run_names_fork_and_merge() {
  setup_workspace "prop-dry-run-names"
  _setup_partial_checkin

  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" --dry-run 2>&1) || exit_code=$?
  assert_success "dry-run succeeds" "$exit_code"
  assert_contains "the up-to-date fork is named" "$output" "[dry-run] fork $CHILD onto $PROJ"

  checkout_task "$CHILD" >/dev/null || true
  _add_work "more-work.txt" "More work"
  checkout_task "$PROJ" >/dev/null || true
  bm_before=$(get_bookmark_commit "$CHILD")

  output=$(run_tt task propagate --from "$PROJ" --dry-run 2>&1) || true
  assert_contains "the rebase fork is named" "$output" \
    "[dry-run] fork $CHILD onto $PROJ, then rebase $CHILD onto the fork commit"
  output=$(run_tt task propagate --from "$PROJ" --merge --dry-run 2>&1) || true
  assert_contains "the merge label is named" "$output" \
    "[dry-run] merge $PROJ into $CHILD as [tt:task:$PROJ:propagate]"
  assert_eq "the child bookmark does not move" "$(get_bookmark_commit "$CHILD")" "$bm_before"
}

# A worktree on the child, behind after a partial checkin, reports the child
# as its current task once it is synced onto the propagated branch.
test_task_propagate__synced_child_worktree_reports_the_child() {
  setup_workspace "prop-fork-worktree"
  PROJ=$(create_project "proj" "Project") || true
  checkout_task "$PROJ" >/dev/null || true
  CHILD=$(create_task "c" "Child") || true
  wt=$(create_task_worktree "$CHILD")
  printf 'work\n' > "$wt/child-work.txt"
  run_tt_in_worktree "$wt" task checkpoint -m "Child work" >/dev/null 2>&1 || true
  run_tt_in_worktree "$wt" task checkin >/dev/null 2>&1 || true

  checkout_task "$PROJ" >/dev/null || true
  _add_work "parent-file.txt" "Parent update"

  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" 2>&1) || exit_code=$?
  assert_success "propagate succeeds" "$exit_code"
  assert_contains "the child worktree is reported behind" "$output" "$wt ($CHILD)"

  exit_code=0
  run_tt_in_worktree "$wt" worktree sync >/dev/null 2>&1 || exit_code=$?
  assert_success "sync succeeds" "$exit_code"
  current=$(run_tt_in_worktree "$wt" task current 2>/dev/null) || true
  assert_eq "the child worktree reports the child" "$current" "$CHILD"
  assert_file_exists "the worktree received the parent's change" "$wt/parent-file.txt"
}

# Project PROJ with child CHILD, set up so that rebasing CHILD onto PROJ
# conflicts on f.txt in a commit below CHILD's tip, while the tip itself is
# clean: the child's second commit reverts its first, which cancels the
# conflict. The conflict check covers the whole moved range.
_setup_conflict_below_tip() {
  PROJ=$(create_project "proj" "Project") || true
  checkout_task "$PROJ" >/dev/null || true
  _add_work "f.txt" "a"
  CHILD=$(create_task "c" "Child") || true
  checkout_task "$CHILD" >/dev/null || true
  _add_work "f.txt" "b"
  _add_work "f.txt" "a"
  checkout_task "$PROJ" >/dev/null || true
  _add_work "f.txt" "p"
}

test_task_propagate__rebase_refuses_conflict_below_the_tip() {
  setup_workspace "prop-conflict-below-tip"
  _setup_conflict_below_tip

  bm_before=$(get_bookmark_commit "$CHILD")
  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" 2>&1) || exit_code=$?
  assert_failure "propagate refuses" "$exit_code"
  assert_contains "the conflict is reported" "$output" "Conflicts detected in $CHILD"
  assert_eq "the child bookmark does not move" "$(get_bookmark_commit "$CHILD")" "$bm_before"
}

test_task_propagate__rebase_force_accepts_conflict_below_the_tip() {
  setup_workspace "prop-conflict-below-tip-force"
  _setup_conflict_below_tip

  output="" exit_code=0
  output=$(run_tt task propagate --from "$PROJ" --force 2>&1) || exit_code=$?
  assert_success "--force proceeds" "$exit_code"
  assert_is_ancestor "the child was rebased" "$PROJ" "$CHILD"
  assert_eq "the conflict is below the tip" \
    "$(has_conflicts "$CHILD" && echo tip || echo clean)" "clean"
  assert_eq "the moved range carries the conflict" \
    "$(has_conflicts "${PROJ}..${CHILD}" && echo conflicted || echo clean)" "conflicted"
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


test_task_propagate__refuses_when_the_canonical_workspace_is_stale() {
  setup_workspace "propagate-stale-canonical"
  setup_stale_canonical "propagated"

  assert_refuses_stale_canonical "$STALE_WORKTREE" \
    task propagate --from "$STALE_PROJ_ID"
}

run_tests "tt task propagate"
