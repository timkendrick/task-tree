#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for the task model facade in lib/task.sh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _task__write_stub (via task/create)
# ---------------------------------------------------------------------------

test__task__write_stub__has_placeholder_title() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  local suffix="my-stub-abc12345"
  _task__write_stub "$dir" "$suffix" 2>/dev/null

  local file="$dir/.tt/task/$suffix/TASK.md"
  local content
  content="$(cat "$file")"
  assert_contains "placeholder title line" "$content" 'title: ""'
  assert_contains "status TODO" "$content" 'status: TODO'
}

# ---------------------------------------------------------------------------
# _task__build_index
# ---------------------------------------------------------------------------

# Build the task index of $REPO. Usage: _build_index
_build_index() {
  _task__build_index "$REPO" "$(_workspace__get_task_prefix "$REPO")" \
    "$(_workspace__get_project_prefix "$REPO")"
}

# Print FIELD (1-based, after the row type) of the task row for ID in INDEX.
# Usage: _index_task_field INDEX ID FIELD
_index_task_field() {
  printf '%s\n' "$1" | awk -F'\t' -v id="$2" -v field="$3" \
    '$1 == "task" && $2 == id { print $(field + 1) }'
}

# Print the "CHECKBOX SUBTASK_ID" subtask rows of ID in INDEX, one per line.
# Usage: _index_subtasks INDEX ID
_index_subtasks() {
  printf '%s\n' "$1" | awk -F'\t' -v id="$2" \
    '$1 == "subtask" && $2 == id { print $3 " " $4 }'
}

test__task__build_index__lists_bookmarked_tasks_with_records() {
  setup_workspace "index-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_a=$(create_task "a" "Task A") || true
  checkout_task "$proj_id" || true
  task_b=$(create_task "b" "Task B") || true

  local index exit_code=0
  index="$(_build_index 2>/dev/null)" || exit_code=$?
  assert_success "index builds" "$exit_code"
  assert_eq "project kind" "$(_index_task_field "$index" "$proj_id" 2)" "project"
  assert_eq "task kind" "$(_index_task_field "$index" "$task_a" 2)" "task"
  assert_eq "project has a branch" "$(_index_task_field "$index" "$proj_id" 3)" "1"
  assert_eq "task file path" "$(_index_task_field "$index" "$task_a" 4)" \
    ".tt/task/${task_a#*/}/TASK.md"
  assert_eq "task source is its own tip" "$(_index_task_field "$index" "$task_a" 5)" \
    "$(get_full_commit_id "$task_a")"
  assert_eq "task status" "$(_index_task_field "$index" "$task_a" 6)" "TODO"
  assert_eq "task title" "$(_index_task_field "$index" "$task_b" 7)" "Task B"
  assert_eq "subtasks in file order" "$(_index_subtasks "$index" "$proj_id")" \
    "$(printf '[ ] %s\n[ ] %s' "$task_a" "$task_b")"
}

test__task__build_index__reads_checked_in_task_from_parent() {
  setup_workspace "index-merged"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Original Title") || true
  checkout_task "$task_id" || true
  checkin_task --complete >/dev/null || true
  run_tt task edit "$task_id" --title "Edited On Own Branch" >/dev/null 2>&1 || true

  local index
  index="$(_build_index 2>/dev/null)"
  assert_eq "source is the parent tip" "$(_index_task_field "$index" "$task_id" 5)" \
    "$(get_full_commit_id "$proj_id")"
  assert_eq "title from the parent copy" "$(_index_task_field "$index" "$task_id" 7)" \
    "Original Title"
  assert_eq "status from the parent copy" "$(_index_task_field "$index" "$task_id" 6)" \
    "DONE"
}

test__task__build_index__includes_subtasks_without_a_bookmark() {
  setup_workspace "index-no-bookmark"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  merged=$(create_task "merged" "Merged Task") || true
  checkout_task "$merged" || true
  checkin_task --complete >/dev/null || true
  checkout_task "$proj_id" || true
  pending=$(create_task "pending" "Pending Task") || true
  jj -R "$REPO" bookmark delete "$merged" "$pending" >/dev/null 2>&1

  local index err
  err="$_TEST_ROOT/index-err.txt"
  index="$(_build_index 2>"$err")"
  assert_eq "merged task has no branch" "$(_index_task_field "$index" "$merged" 3)" "0"
  assert_eq "merged task read from the parent" "$(_index_task_field "$index" "$merged" 7)" \
    "Merged Task"
  assert_eq "pending task listed" "$(_index_task_field "$index" "$pending" 2)" "task"
  assert_eq "pending task unreadable" "$(_index_task_field "$index" "$pending" 5)" ""
  assert_contains "unreadable task warned" "$(cat "$err")" \
    "Warning: Cannot read the task file of '$pending'."
  assert_not_contains "readable task not warned" "$(cat "$err")" "'$merged'"
}

test__task__build_index__includes_orphaned_bookmarks() {
  setup_workspace "index-orphan"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Orphan") || true
  _task__commit_on_branch "$REPO" "$proj_id" "drop subtask" \
    --modify ".tt/task/${proj_id#*/}/TASK.md" -- _writer_drop_subtasks >/dev/null

  local index
  index="$(_build_index 2>/dev/null)"
  assert_output_empty "project lists no subtasks" "$(_index_subtasks "$index" "$proj_id")"
  assert_eq "orphan listed" "$(_index_task_field "$index" "$task_id" 7)" "Orphan"
}

# Writer: removes every subtask entry from the staged project file.
_writer_drop_subtasks() {
  local file
  file="$(printf '%s\n' "$1"/.tt/task/*/TASK.md)"
  grep -v '^subtask:' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# ---------------------------------------------------------------------------
# _task__list_branch_records and the _task__find_*_in lookups
# ---------------------------------------------------------------------------

test__task__list_branch_records__reads_every_bookmark_tip() {
  setup_workspace "branch-records"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Task") || true
  jj -R "$REPO" bookmark create not-a-task -r @ >/dev/null 2>&1

  local listing proj_commit task_commit
  listing="$(_task__list_branch_records "$REPO" "$(_workspace__get_task_prefix "$REPO")" \
    "$(_workspace__get_project_prefix "$REPO")")"
  proj_commit="$(get_full_commit_id "$proj_id")"
  task_commit="$(get_full_commit_id "$task_id")"
  assert_eq "bookmark rows in alphabetical order" \
    "$(printf '%s\n' "$listing" | awk -F'\t' '$1 == "bookmark"')" \
    "$(printf 'bookmark\t%s\t%s\n' "$proj_id" "$proj_commit" "$task_id" "$task_commit")"
  assert_contains "project file read at its tip" "$listing" \
    "read"$'\t'"$proj_id"$'\t'"$proj_commit"$'\t+\t'
  assert_contains "task file read at its tip" "$listing" \
    "read"$'\t'"$task_id"$'\t'"$task_commit"$'\t+\tTODO\tTask'
  assert_contains "subtask entry of the project" "$listing" \
    "entry"$'\t'"$proj_id"$'\t'"$proj_commit"$'\t[ ]\t'"$task_id"
  assert_not_contains "other bookmarks skipped" "$listing" "not-a-task"
}

test__task__find_lookups__wrappers_use_the_repository() {
  setup_workspace "find-wrappers"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" || true
  task_id=$(create_task "t" "Task") || true

  local task_prefix project_prefix
  task_prefix="$(_workspace__get_task_prefix "$REPO")"
  project_prefix="$(_workspace__get_project_prefix "$REPO")"
  assert_eq "parent branch" \
    "$(_task__find_parent_branch "$REPO" "$task_id" "$task_prefix" "$project_prefix")" "$proj_id"
  assert_eq "ongoing task read from its own branch" \
    "$(_task__find_branch "$REPO" "$task_id" "$task_prefix" "$project_prefix")" "$task_id"
  assert_eq "parent project" \
    "$(_task__find_parent_project "$REPO" "$task_id" "$task_prefix" "$project_prefix")" "$proj_id"
}

# Print a listing in the format of _task__list_branch_records. Each argument
# is "OWNER" for a bookmark without entries, "OWNER=" for a conflicted
# bookmark, or "OWNER:CHECKBOX:SUBTASK_ID[,CHECKBOX:SUBTASK_ID]..." for a
# bookmark whose file lists those entries. CHECKBOX is ' ', '-' or 'x'.
# Usage: _listing SPEC...
_listing() {
  local spec owner entries entry commit
  for spec in "$@"; do
    owner="${spec%%[:=]*}"
    commit="c-$owner"
    [[ "$spec" == *= ]] && commit=''
    printf 'bookmark\t%s\t%s\n' "$owner" "$commit"
  done
  for spec in "$@"; do
    [[ "$spec" == *= ]] && continue
    owner="${spec%%:*}"
    printf 'read\t%s\tc-%s\t+\tTODO\t%s\n' "$owner" "$owner" "$owner"
    [[ "$spec" == *:* ]] || continue
    entries="${spec#*:}"
    while [[ -n "$entries" ]]; do
      entry="${entries%%,*}"
      printf 'entry\t%s\tc-%s\t[%s]\t%s\n' "$owner" "$owner" "${entry%%:*}" "${entry#*:}"
      [[ "$entries" == *,* ]] && entries="${entries#*,}" || entries=''
    done
  done
}

test__task__find_parent_branch_in__one_parent() {
  local listing output exit_code=0
  listing="$(_listing 'project/p-00000001: :task/a-00000002' 'task/a-00000002')"
  output="$(_task__find_parent_branch_in "$listing" task/a-00000002)" || exit_code=$?
  assert_success "parent found" "$exit_code"
  assert_eq "parent printed" "$output" project/p-00000001
}

test__task__find_parent_branch_in__any_checkbox() {
  local listing
  listing="$(_listing 'project/p-00000001:x:task/a-00000002,-:task/b-00000003')"
  assert_eq "parent of a merged task" \
    "$(_task__find_parent_branch_in "$listing" task/a-00000002)" project/p-00000001
  assert_eq "parent of an in-progress task" \
    "$(_task__find_parent_branch_in "$listing" task/b-00000003)" project/p-00000001
}

test__task__find_parent_branch_in__no_parent() {
  local listing output exit_code=0
  listing="$(_listing 'project/p-00000001' 'task/a-00000002:x:task/a-00000002')"
  output="$(_task__find_parent_branch_in "$listing" task/a-00000002 2>&1)" || exit_code=$?
  assert_exit_code "no parent, and the task's own file does not count" "$exit_code" 1
  assert_output_empty "nothing printed" "$output"
}

test__task__find_parent_branch_in__multiple_parents() {
  local listing output exit_code=0 err="$_TEST_ROOT/parents-err.txt"
  listing="$(_listing 'project/p-00000001: :task/a-00000002' \
    'project/q-00000003:x:task/a-00000002' 'task/b-00000004: :task/a-00000002')"
  output="$(_task__find_parent_branch_in "$listing" task/a-00000002 2>"$err")" || exit_code=$?
  assert_exit_code "multiple parents" "$exit_code" 2
  assert_output_empty "nothing printed" "$output"
  assert_eq "error names the first two parents in bookmark order" "$(cat "$err")" \
    "Error: Multiple parent branches found for 'task/a-00000002': 'project/p-00000001' and 'project/q-00000003'."
}

test__task__find_branch_in__merged_task_read_from_first_marking_owner() {
  local listing
  listing="$(_listing 'project/p-00000001: :task/a-00000002' \
    'project/q-00000003:x:task/a-00000002' 'task/a-00000002' \
    'task/b-00000004:x:task/a-00000002')"
  assert_eq "first owner marking the task [x]" \
    "$(_task__find_branch_in "$listing" task/a-00000002)" project/q-00000003
}

test__task__find_branch_in__ongoing_task_read_from_its_bookmark() {
  local listing
  listing="$(_listing 'project/p-00000001:-:task/a-00000002' 'task/a-00000002')"
  assert_eq "own bookmark" "$(_task__find_branch_in "$listing" task/a-00000002)" \
    task/a-00000002
}

test__task__find_branch_in__without_a_usable_bookmark() {
  local listing output exit_code=0
  listing="$(_listing 'project/p-00000001: :task/a-00000002,-:task/b-00000003' \
    'task/b-00000003=')"
  output="$(_task__find_branch_in "$listing" task/a-00000002)" || exit_code=$?
  assert_exit_code "deleted bookmark" "$exit_code" 1
  assert_output_empty "nothing printed for a deleted bookmark" "$output"

  exit_code=0
  output="$(_task__find_branch_in "$listing" task/b-00000003)" || exit_code=$?
  assert_exit_code "conflicted bookmark" "$exit_code" 1
  assert_output_empty "nothing printed for a conflicted bookmark" "$output"
}

test__task__find_parent_project_in__walks_to_the_nearest_project() {
  local listing
  listing="$(_listing 'project/p-00000001: :task/a-00000002' \
    'task/a-00000002: :task/b-00000003' 'task/b-00000003: :task/c-00000004' \
    'task/c-00000004')"
  assert_eq "grandparent project" \
    "$(_task__find_parent_project_in "$listing" task/c-00000004 project/)" project/p-00000001
  assert_eq "parent project" \
    "$(_task__find_parent_project_in "$listing" task/a-00000002 project/)" project/p-00000001
}

test__task__find_parent_project_in__propagates_lookup_failures() {
  local listing output exit_code=0 err="$_TEST_ROOT/project-err.txt"
  listing="$(_listing 'task/a-00000002: :task/b-00000003' 'task/b-00000003')"
  output="$(_task__find_parent_project_in "$listing" task/b-00000003 project/ 2>&1)" \
    || exit_code=$?
  assert_exit_code "no ancestor project" "$exit_code" 1
  assert_output_empty "nothing printed without a project" "$output"

  listing="$(_listing 'project/p-00000001: :task/a-00000002' \
    'project/q-00000003: :task/a-00000002' 'task/a-00000002: :task/b-00000003')"
  exit_code=0
  output="$(_task__find_parent_project_in "$listing" task/b-00000003 project/ 2>"$err")" \
    || exit_code=$?
  assert_exit_code "multiple parents at a higher level" "$exit_code" 2
  assert_contains "error names the ambiguous task" "$(cat "$err")" \
    "Multiple parent branches found for 'task/a-00000002'"
}

test__task__find_parent_project_in__detects_a_cycle() {
  local listing output exit_code=0 err="$_TEST_ROOT/cycle-err.txt"
  listing="$(_listing 'task/a-00000002: :task/b-00000003' 'task/b-00000003: :task/a-00000002')"
  output="$(_task__find_parent_project_in "$listing" task/a-00000002 project/ 2>"$err")" \
    || exit_code=$?
  assert_exit_code "cycle" "$exit_code" 2
  assert_output_empty "nothing printed" "$output"
  assert_eq "error names the revisited task" "$(cat "$err")" \
    "Error: Cycle in the task hierarchy at 'task/a-00000002'."
}

# ---------------------------------------------------------------------------
# _task__get_range_context / _task__resolve_range
# ---------------------------------------------------------------------------

test__task__get_range_context__matches_resolve_range() {
  setup_workspace "range-context-compat"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "work" >/dev/null || true

  local context legacy
  context="$(_task__get_range_context "$REPO" "$task_id")"
  legacy="$(_task__resolve_range "$REPO" "$task_id")"

  local ctx_task ctx_parent ctx_upper
  IFS=$'\t' read -r ctx_task ctx_parent ctx_upper <<< "$context"
  assert_eq "context reports the task id" "$ctx_task" "$task_id"
  assert_eq "_task__resolve_range matches context's parent/upper fields" \
    "$legacy" "$ctx_parent $ctx_upper"
}

# ---------------------------------------------------------------------------
# _task__get_full_range_records
# ---------------------------------------------------------------------------

# Fetches full-range records for TASK_ID via its resolved parent/upper bound,
# printing them tab-separated (one per line) on stdout for the caller to parse.
_full_range_records_for() {
  local task_id="$1"
  local context
  context="$(_task__get_range_context "$REPO" "$task_id")"
  local ctx_task parent_bookmark upper_bound
  IFS=$'\t' read -r ctx_task parent_bookmark upper_bound <<< "$context"
  _task__get_full_range_records "$REPO" "$task_id" "$parent_bookmark" "$upper_bound"
}

test__task__get_full_range_records__current_only_when_never_checked_in() {
  setup_workspace "full-range-current-only"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "work" >/dev/null || true

  local records
  records="$(_full_range_records_for "$task_id")"
  assert_line_count "exactly one component" "$records" 1
  assert_contains "the sole component is the current range" "$records" "$(printf '\tcurrent\t')"
}

test__task__get_full_range_records__excludes_creation_and_wrapper_commits() {
  setup_workspace "full-range-wrappers"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo work > "$REPO/work.txt"
  checkpoint_task "work" >/dev/null || true
  checkpoint_commit=$(_repo__resolve_commit "$REPO" "$task_id")
  run_tt task checkin "$task_id" --complete >/dev/null 2>&1 || true

  local records
  records="$(_full_range_records_for "$task_id")"
  assert_line_count "one historical component, no current component" "$records" 1

  local base tip kind _order _ts
  IFS=$'\t' read -r base tip kind _order _ts <<< "$records"
  assert_eq "component is historical" "$kind" "historical"
  assert_is_ancestor "checkpoint is included" "$base" "$checkpoint_commit"
  assert_is_ancestor "checkpoint is included (tip side)" "$checkpoint_commit" "$tip"

  # The handoff and checkin merge commits must not appear in the component.
  handoff_commit=$(_repo__resolve_commit "$REPO" "description(substring:'${task_id}:handoff]')")
  checkin_commit=$(_repo__resolve_commit "$REPO" "description(substring:'${task_id}:checkin]')")
  local component_commits
  component_commits="$(_repo__list_commits_in_range "$REPO" "$base" "$tip")"
  assert_not_contains "handoff excluded from component" "$component_commits" "$handoff_commit"
  assert_not_contains "checkin merge excluded from component" "$component_commits" "$checkin_commit"
}

test__task__get_full_range_records__historical_plus_current() {
  setup_workspace "full-range-partial-then-current"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo w1 > "$REPO/w1.txt"
  checkpoint_task "w1" >/dev/null || true
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true   # partial checkin

  checkout_task "$task_id" >/dev/null || true
  echo w2 > "$REPO/w2.txt"
  checkpoint_task "w2" >/dev/null || true
  w2_commit=$(_repo__resolve_commit "$REPO" "$task_id")

  local records
  records="$(_full_range_records_for "$task_id")"
  assert_line_count "one historical plus one current component" "$records" 2

  local kinds
  kinds="$(printf '%s\n' "$records" | cut -f3)"
  assert_eq "first component is historical" "$(printf '%s\n' "$kinds" | sed -n '1p')" "historical"
  assert_eq "second (last) component is current" "$(printf '%s\n' "$kinds" | sed -n '2p')" "current"

  local current_line current_base current_tip
  current_line="$(printf '%s\n' "$records" | sed -n '2p')"
  IFS=$'\t' read -r current_base current_tip _ _ _ <<< "$current_line"
  assert_contains "w2 is included in the current component" \
    "$(_repo__list_commits_in_range "$REPO" "$current_base" "$current_tip")" "$w2_commit"
}

test__task__get_full_range_records__multiple_discontiguous_historical_components() {
  setup_workspace "full-range-multi-historical"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo w1 > "$REPO/w1.txt"
  checkpoint_task "w1" >/dev/null || true
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true   # partial checkin #1

  checkout_task "$task_id" >/dev/null || true
  echo w2 > "$REPO/w2.txt"
  checkpoint_task "w2" >/dev/null || true
  w2_commit=$(_repo__resolve_commit "$REPO" "$task_id")
  # --force accepts the parent-side subtask-checkbox conflict a second,
  # unrebased checkin produces here.
  run_tt task checkin "$task_id" --complete --force >/dev/null 2>&1 || true   # completing checkin #2

  local records
  records="$(_full_range_records_for "$task_id")"
  assert_line_count "two historical components, no current component" "$records" 2

  local kinds
  kinds="$(printf '%s\n' "$records" | cut -f3)"
  assert_eq "first component is historical" "$(printf '%s\n' "$kinds" | sed -n '1p')" "historical"
  assert_eq "second component is historical" "$(printf '%s\n' "$kinds" | sed -n '2p')" "historical"

  local second_line second_base second_tip
  second_line="$(printf '%s\n' "$records" | sed -n '2p')"
  IFS=$'\t' read -r second_base second_tip _ _ _ <<< "$second_line"
  assert_contains "w2 is included in the second historical component" \
    "$(_repo__list_commits_in_range "$REPO" "$second_base" "$second_tip")" "$w2_commit"
}

# A repeat checkin with --rebase first propagates the parent into the task.
# The task's new work hangs off its own partially checked-in line, so the
# rebase puts a fork commit underneath it: the second handoff still points
# TASK.md from the task back at the parent, and is classified.
test__task__get_full_range_records__repeat_checkin_after_rebase_propagation() {
  setup_workspace "full-range-rebase-repeat"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo w1 > "$REPO/w1.txt"
  checkpoint_task "w1" >/dev/null || true
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true   # partial checkin #1

  checkout_task "$task_id" >/dev/null || true
  echo w2 > "$REPO/w2.txt"
  checkpoint_task "w2" >/dev/null || true
  local exit_code=0
  run_tt task checkin "$task_id" --complete --rebase >/dev/null 2>&1 || exit_code=$?
  assert_success "rebased checkin #2 succeeds" "$exit_code"
  w2_commit=$(_repo__resolve_commit "$REPO" "description(substring:'${task_id}:checkpoint] w2')")

  local records
  records="$(_full_range_records_for "$task_id")"
  assert_line_count "two historical components, no current component" "$records" 2
  assert_eq "both components are historical" \
    "$(printf '%s\n' "$records" | cut -f3 | sort -u)" "historical"

  local second_line second_base second_tip
  second_line="$(printf '%s\n' "$records" | sed -n '2p')"
  IFS=$'\t' read -r second_base second_tip _ _ _ <<< "$second_line"
  assert_contains "w2 is included in the second historical component" \
    "$(_repo__list_commits_in_range "$REPO" "$second_base" "$second_tip")" "$w2_commit"
}

# A propagate merge joins the parent's tip into the task. Its second parent is
# the parent's tip, which is never a handoff, so the merge is neither a
# historical nor a child component. Only the real partial checkin is.
test__task__get_full_range_records__propagate_merge_not_classified() {
  setup_workspace "full-range-propagate-merge"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo w1 > "$REPO/w1.txt"
  checkpoint_task "w1" >/dev/null || true
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true   # partial checkin
  checkin_commit=$(_repo__resolve_commit "$REPO" "description(substring:'${task_id}:checkin]')")

  checkout_task "$task_id" >/dev/null || true
  echo w2 > "$REPO/w2.txt"
  checkpoint_task "w2" >/dev/null || true
  checkout_task "$proj_id" >/dev/null || true
  echo p1 > "$REPO/p1.txt"
  checkpoint_task "parent work" >/dev/null || true
  run_tt task propagate --from "$proj_id" --merge >/dev/null 2>&1 || true
  propagate_commit=$(_repo__resolve_commit "$REPO" "$task_id")
  assert_commit_message_first_line "the task tip is the propagate merge" "$task_id" \
    "[tt:task:$proj_id:propagate] Project"

  local records
  records="$(_full_range_records_for "$task_id")"
  local kinds
  kinds="$(printf '%s\n' "$records" | cut -f3)"
  assert_eq "one historical component" "$(printf '%s\n' "$kinds" | grep -c '^historical$')" "1"
  assert_eq "no child component" "$(printf '%s\n' "$kinds" | grep -c '^child$' || true)" "0"

  local historical_order
  historical_order="$(printf '%s\n' "$records" | awk -F'\t' '$3 == "historical" { print $4 }')"
  assert_eq "the historical component is the partial checkin" \
    "$historical_order" "$checkin_commit"
  assert_neq "the propagate merge is not a component" \
    "$historical_order" "$propagate_commit"
}

test__task__get_full_range_records__unrelated_project_work_excluded() {
  setup_workspace "full-range-unrelated-excluded"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo w1 > "$REPO/w1.txt"
  checkpoint_task "w1" >/dev/null || true
  run_tt task checkin "$task_id" --complete >/dev/null 2>&1 || true

  # Unrelated work directly on the project branch after the checkin.
  checkout_task "$proj_id" >/dev/null || true
  echo p1 > "$REPO/p1.txt"
  unrelated_commit=$(_repo__resolve_commit "$REPO" "$proj_id")
  checkpoint_task "unrelated project work" >/dev/null || true

  local records
  records="$(_full_range_records_for "$task_id")"
  assert_line_count "only the one historical component" "$records" 1

  local base tip
  IFS=$'\t' read -r base tip _ _ _ <<< "$records"
  assert_not_contains "unrelated project commit excluded" \
    "$(_repo__list_commits_in_range "$REPO" "$base" "$tip")" "$unrelated_commit"
}

test__task__get_full_range_records__project_branch_rejected() {
  setup_workspace "full-range-project-rejected"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "project work" >/dev/null || true

  local exit_code=0
  _task__get_full_range_records "$REPO" "$proj_id" "main" "$proj_id" >/dev/null 2>&1 || exit_code=$?
  assert_failure "full range discovery rejects project branches" "$exit_code"
}

# ---------------------------------------------------------------------------
# _task__commit_on_branch
# ---------------------------------------------------------------------------

# Build a divergent "side" branch off main carrying base.txt, outside.txt and
# two files under prefix/, then park the working copy back on a fresh child of
# main. The side tip is NOT an ancestor of @, so a commit on "side" must leave
# the working copy alone. Sets SIDE_TIP to the branch tip's full commit ID.
_fixture_side_branch() {
  jj -R "$REPO" new main >/dev/null 2>&1
  edit_file base.txt "base"
  edit_file outside.txt "keep"
  edit_file prefix/a.txt "a"
  edit_file prefix/b.txt "b"
  jj -R "$REPO" commit -m "side files" >/dev/null 2>&1
  jj -R "$REPO" bookmark set side -r '@-' >/dev/null 2>&1
  jj -R "$REPO" new main >/dev/null 2>&1
  SIDE_TIP="$(get_full_commit_id side)"
}

# Writer: stages new.txt with the content passed as its second argument
# (exercises ARGS forwarding).
_writer_stage_new_file() {
  local stage="$1" content="$2"
  printf '%s\n' "$content" > "$stage/new.txt"
}

# Writer: verifies base.txt was materialized with the tip's content, then
# appends a line to it.
_writer_edit_base() {
  local stage="$1"
  [[ "$(cat "$stage/base.txt")" == "base" ]] || return 1
  printf 'edited\n' >> "$stage/base.txt"
}

# Writer: stages nothing.
_writer_noop() {
  :
}

# Writer: always fails.
_writer_fail() {
  return 1
}

test__task__commit_on_branch__stages_new_file_without_touching_working_copy() {
  setup_workspace "commit-on-branch-basic"
  _fixture_side_branch
  local wc_before
  wc_before="$(_repo__resolve_commit "$REPO" '@')"

  local commit exit_code=0
  commit="$(_task__commit_on_branch "$REPO" side "stage new file" \
    -- _writer_stage_new_file "hello")" || exit_code=$?
  assert_success "staged commit created" "$exit_code"
  assert_matches "full-length commit ID printed" "$commit" '^[0-9a-f]{40}$'
  assert_eq "bookmark advanced to the printed commit" \
    "$(_repo__resolve_commit "$REPO" side)" "$commit"
  assert_eq "staged file readable at the bookmark" \
    "$(_repo__read_file_at_revision "$REPO" side new.txt)" "hello"
  assert_eq "staged file absent from the working copy" \
    "$([[ -e "$REPO/new.txt" ]] && echo present || echo absent)" "absent"
  assert_eq "@ did not move" "$(_repo__resolve_commit "$REPO" '@')" "$wc_before"
}

test__task__commit_on_branch__copy_from_places_a_recorded_path() {
  setup_workspace "commit-on-branch-copy-from"
  _fixture_side_branch

  local commit exit_code=0
  commit="$(_task__commit_on_branch "$REPO" main "copy prefix from side" \
    --copy-from "$SIDE_TIP" prefix -- _writer_noop)" || exit_code=$?
  assert_success "staged commit created" "$exit_code"
  assert_eq "a copied file has the recorded content" \
    "$(_repo__read_file_at_revision "$REPO" main prefix/a.txt)" "a"
  assert_eq "every file under the copied directory is present" \
    "$(_repo__read_file_at_revision "$REPO" main prefix/b.txt)" "b"
  assert_not_contains "nothing else comes across" \
    "$(_repo__list_files_at_revision "$REPO" main)" "outside.txt"

  exit_code=0
  _task__commit_on_branch "$REPO" main "copy absent" \
    --copy-from "$SIDE_TIP" no-such-path -- _writer_noop >/dev/null 2>&1 || exit_code=$?
  assert_failure "copying an absent path fails" "$exit_code"
}

test__task__commit_on_branch__move_prefix_relocates_a_directory() {
  setup_workspace "commit-on-branch-move-prefix"
  _fixture_side_branch

  local commit exit_code=0
  commit="$(_task__commit_on_branch "$REPO" side "move prefix" \
    --move-prefix prefix moved -- _writer_noop)" || exit_code=$?
  assert_success "staged commit created" "$exit_code"
  local files
  files="$(_repo__list_files_at_revision "$REPO" side)"
  assert_contains "the files are at the new prefix" "$files" "moved/a.txt"
  assert_contains "every file moved" "$files" "moved/b.txt"
  assert_not_contains "the old prefix is gone" "$files" "prefix/a.txt"
  assert_eq "content is unchanged" "$(_repo__read_file_at_revision "$REPO" side moved/a.txt)" "a"

  exit_code=0
  local before
  before="$(_repo__resolve_commit "$REPO" side)"
  _task__commit_on_branch "$REPO" side "move absent" \
    --move-prefix no-such-prefix elsewhere -- _writer_stage_new_file "x" >/dev/null 2>&1 \
    || exit_code=$?
  assert_success "an absent prefix contributes nothing" "$exit_code"
  assert_not_contains "nothing lands at the destination" \
    "$(_repo__list_files_at_revision "$REPO" side)" "elsewhere/"
  assert_neq "the rest of the commit is still made" "$(_repo__resolve_commit "$REPO" side)" "$before"
}

test__task__check_path_exists__reports_recorded_paths() {
  setup_workspace "check-path-exists"
  _fixture_side_branch
  local exit_code=0
  _task__check_path_exists "$REPO" side prefix/a.txt || exit_code=$?
  assert_success "a recorded path exists" "$exit_code"
  exit_code=0
  _task__check_path_exists "$REPO" side no-such.txt || exit_code=$?
  assert_failure "an unrecorded path does not" "$exit_code"
}

test__task__commit_on_branch__modify_materializes_tip_content() {
  setup_workspace "commit-on-branch-modify"
  _fixture_side_branch

  local commit exit_code=0
  # _writer_edit_base itself asserts the materialized content ("base") and
  # fails otherwise, so a success here proves the tip content was staged.
  commit="$(_task__commit_on_branch "$REPO" side "edit base" \
    --modify base.txt -- _writer_edit_base)" || exit_code=$?
  assert_success "read-modify-write commit created" "$exit_code"
  assert_eq "edited content lands on the branch" \
    "$(_repo__read_file_at_revision "$REPO" side base.txt)" \
    "$(printf 'base\nedited')"
}

test__task__commit_on_branch__modify_absent_path_fails() {
  setup_workspace "commit-on-branch-modify-absent"
  _fixture_side_branch

  local err_file="$_TEST_ROOT/modify-absent-err.txt"
  local out='' exit_code=0
  out="$(_task__commit_on_branch "$REPO" side "nope" \
    --modify no/such/file.txt -- _writer_noop 2>"$err_file")" || exit_code=$?
  assert_failure "absent --modify path rejected" "$exit_code"
  assert_output_empty "no commit ID printed" "$out"
  assert_contains "error names the path" "$(cat "$err_file")" "no/such/file.txt"
  assert_eq "bookmark unmoved" "$(_repo__resolve_commit "$REPO" side)" "$SIDE_TIP"
}

test__task__commit_on_branch__delete_removes_file() {
  setup_workspace "commit-on-branch-delete"
  _fixture_side_branch

  local commit exit_code=0
  commit="$(_task__commit_on_branch "$REPO" side "drop base" \
    --delete base.txt -- _writer_noop)" || exit_code=$?
  assert_success "deletion commit created" "$exit_code"
  local ec=0
  _repo__check_file_exists_at_revision "$REPO" "$commit" base.txt || ec=$?
  assert_failure "deleted file absent at the new commit" "$ec"
  assert_eq "unrelated file survives" \
    "$(_repo__read_file_at_revision "$REPO" "$commit" outside.txt)" "keep"
}

test__task__commit_on_branch__delete_prefix_expands_to_tip_files() {
  setup_workspace "commit-on-branch-delete-prefix"
  _fixture_side_branch

  local commit exit_code=0
  commit="$(_task__commit_on_branch "$REPO" side "drop prefix" \
    --delete-prefix prefix -- _writer_noop)" || exit_code=$?
  assert_success "prefix deletion commit created" "$exit_code"
  local files
  files="$(_repo__list_files_at_revision "$REPO" "$commit")"
  assert_not_contains "first file under the prefix removed" "$files" "prefix/a.txt"
  assert_not_contains "second file under the prefix removed" "$files" "prefix/b.txt"
  assert_contains "file outside the prefix survives" "$files" "outside.txt"
  assert_contains "base file outside the prefix survives" "$files" "base.txt"
}

test__task__commit_on_branch__dirty_working_copy_untouched() {
  setup_workspace "commit-on-branch-dirty"
  _fixture_side_branch
  edit_file dirty.txt "un-snapshotted"
  local wc_change_before
  wc_change_before="$(_repo__resolve_change "$REPO" '@')"

  local commit exit_code=0
  commit="$(_task__commit_on_branch "$REPO" side "clean write" \
    -- _writer_stage_new_file "clean")" || exit_code=$?
  assert_success "staged commit created with a dirty working copy" "$exit_code"
  local ec=0
  _repo__check_file_exists_at_revision "$REPO" "$commit" dirty.txt || ec=$?
  assert_failure "dirty file did not leak into the commit" "$ec"
  assert_file_exists "dirty file still on disk" "$REPO/dirty.txt"
  assert_eq "dirty file content untouched" \
    "$(cat "$REPO/dirty.txt")" "un-snapshotted"
  # The bookmark write may snapshot pending changes into the working-copy
  # commit (amending it in place), so the stable change ID — not the commit
  # ID — is the identity that must survive.
  assert_eq "working-copy commit identity unchanged" \
    "$(_repo__resolve_change "$REPO" '@')" "$wc_change_before"
  assert_eq "working copy still parented off main, not the written branch" \
    "$(_repo__get_working_copy_parent "$REPO")" "$(get_full_commit_id main)"
}

test__task__commit_on_branch__invalid_arguments_rejected() {
  setup_workspace "commit-on-branch-args"
  _fixture_side_branch

  local exit_code=0
  _task__commit_on_branch "$REPO" side "msg" --bogus x -- _writer_noop \
    >/dev/null 2>&1 || exit_code=$?
  assert_failure "unknown flag rejected" "$exit_code"

  exit_code=0
  _task__commit_on_branch "$REPO" side "msg" --delete base.txt \
    >/dev/null 2>&1 || exit_code=$?
  assert_failure "missing -- rejected" "$exit_code"

  exit_code=0
  _task__commit_on_branch "$REPO" side "msg" -- \
    >/dev/null 2>&1 || exit_code=$?
  assert_failure "missing WRITER_FN rejected" "$exit_code"

  exit_code=0
  _task__commit_on_branch "$REPO" side "msg" -- _writer_fail \
    >/dev/null 2>&1 || exit_code=$?
  assert_failure "failing writer aborts" "$exit_code"

  assert_eq "bookmark unmoved after every failure" \
    "$(_repo__resolve_commit "$REPO" side)" "$SIDE_TIP"
}

test__task__commit_on_branch__leaves_no_temp_residue() {
  setup_workspace "commit-on-branch-residue"
  _fixture_side_branch
  local scratch_root="$_TEST_ROOT/commit-scratch"
  mkdir -p "$scratch_root"

  # TMPDIR redirects every mktemp in the call (the staging directory and the
  # backend's scratch directory) into an observable root.
  local commit exit_code=0
  commit="$(TMPDIR="$scratch_root" _task__commit_on_branch "$REPO" side "tidy" \
    -- _writer_stage_new_file "t")" || exit_code=$?
  assert_success "staged commit created" "$exit_code"
  assert_output_empty "no staging or scratch residue after success" \
    "$(find "$scratch_root" -mindepth 1)"

  exit_code=0
  commit="$(TMPDIR="$scratch_root" _task__commit_on_branch "$REPO" side "boom" \
    -- _writer_fail 2>/dev/null)" || exit_code=$?
  assert_failure "failing writer aborts" "$exit_code"
  assert_output_empty "no staging or scratch residue after failure" \
    "$(find "$scratch_root" -mindepth 1)"
}

# ---------------------------------------------------------------------------
# _task__write_symlink, _task__commit_fork, _task__start_branch
# ---------------------------------------------------------------------------

test__task__write_symlink__points_at_the_task_file() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  _task__write_symlink "$dir" "foo-abc12345"
  assert_symlink "symlink targets the task file" "$dir/TASK.md" ".tt/task/foo-abc12345/TASK.md"

  _task__write_symlink "$dir" "bar-abc12345"
  assert_symlink "an existing symlink is replaced" "$dir/TASK.md" ".tt/task/bar-abc12345/TASK.md"
}

test__task__commit_fork__builds_a_detached_fork_commit() {
  setup_workspace "commit-fork-basic"
  _fixture_side_branch
  local wc_before
  wc_before="$(_repo__resolve_commit "$REPO" '@')"

  local commit exit_code=0
  commit="$(_task__commit_fork "$REPO" "task/foo-abc12345" side "Foo title" \
    -- _writer_stage_new_file "staged")" || exit_code=$?
  assert_success "fork commit created" "$exit_code"
  assert_matches "full-length commit ID printed" "$commit" '^[0-9a-f]{40}$'
  assert_eq "fork commit sits on the base revision" \
    "$(_repo__resolve_commit "$REPO" "${commit}-")" "$SIDE_TIP"
  assert_eq "fork commit message names the task and title" \
    "$(get_commit_message_first_line "$commit")" "[tt:task:task/foo-abc12345:fork] Foo title"
  assert_eq "TASK.md points at the task file" \
    "$(_repo__read_symlink_at_revision "$REPO" "$commit" TASK.md)" \
    ".tt/task/foo-abc12345/TASK.md"
  assert_eq "writer output lands in the fork commit" \
    "$(_repo__read_file_at_revision "$REPO" "$commit" new.txt)" "staged"
  assert_eq "base bookmark unmoved" "$(_repo__resolve_commit "$REPO" side)" "$SIDE_TIP"
  assert_eq "no bookmark created" "$(get_bookmarks_at "$commit")" ""
  assert_eq "@ did not move" "$(_repo__resolve_commit "$REPO" '@')" "$wc_before"
}

test__task__commit_fork__writes_only_the_symlink_without_a_writer() {
  setup_workspace "commit-fork-no-writer"
  _fixture_side_branch

  local commit exit_code=0
  commit="$(_task__commit_fork "$REPO" "project/bar-abc12345" side "Bar")" || exit_code=$?
  assert_success "fork commit created for a project ID" "$exit_code"
  assert_eq "TASK.md points at the project task file" \
    "$(_repo__read_symlink_at_revision "$REPO" "$commit" TASK.md)" \
    ".tt/task/bar-abc12345/TASK.md"
  assert_eq "only TASK.md changes" "$(get_modified_files "$commit")" "TASK.md"
}

test__task__commit_fork__invalid_arguments_rejected() {
  setup_workspace "commit-fork-args"
  _fixture_side_branch

  local exit_code=0
  _task__commit_fork "$REPO" "not-a-task" side "T" >/dev/null 2>&1 || exit_code=$?
  assert_failure "unrecognized task ID rejected" "$exit_code"

  exit_code=0
  _task__commit_fork "$REPO" "task/foo-abc12345" side "T" _writer_noop \
    >/dev/null 2>&1 || exit_code=$?
  assert_failure "writer without -- rejected" "$exit_code"

  exit_code=0
  _task__commit_fork "$REPO" "task/foo-abc12345" side "T" -- \
    >/dev/null 2>&1 || exit_code=$?
  assert_failure "-- without WRITER_FN rejected" "$exit_code"

  exit_code=0
  _task__commit_fork "$REPO" "task/foo-abc12345" no-such-rev "T" \
    >/dev/null 2>&1 || exit_code=$?
  assert_failure "unresolvable base rejected" "$exit_code"

  exit_code=0
  _task__commit_fork "$REPO" "task/foo-abc12345" side "T" -- _writer_fail \
    >/dev/null 2>&1 || exit_code=$?
  assert_failure "failing writer aborts" "$exit_code"
}

test__task__start_branch__creates_and_forces_bookmarks() {
  setup_workspace "start-branch"
  _fixture_side_branch
  local main_tip
  main_tip="$(_repo__resolve_commit "$REPO" main)"

  local exit_code=0
  _task__start_branch "$REPO" fresh "$SIDE_TIP" || exit_code=$?
  assert_success "new bookmark created" "$exit_code"
  assert_eq "new bookmark on the revision" "$(_repo__resolve_commit "$REPO" fresh)" "$SIDE_TIP"

  exit_code=0
  _task__start_branch "$REPO" fresh "$main_tip" >/dev/null 2>&1 || exit_code=$?
  assert_failure "backwards move refused without --allow-backwards" "$exit_code"
  assert_eq "bookmark unmoved after refusal" "$(_repo__resolve_commit "$REPO" fresh)" "$SIDE_TIP"

  exit_code=0
  _task__start_branch "$REPO" fresh "$main_tip" --allow-backwards || exit_code=$?
  assert_success "backwards move allowed with --allow-backwards" "$exit_code"
  assert_eq "bookmark moved backwards" "$(_repo__resolve_commit "$REPO" fresh)" "$main_tip"

  exit_code=0
  _task__start_branch "$REPO" fresh "$SIDE_TIP" --bogus >/dev/null 2>&1 || exit_code=$?
  assert_failure "unknown flag rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _task__commit_handoff, _task__merge_branch, _task__check_conflicts,
# _task__advance_branch
# ---------------------------------------------------------------------------

test__task__commit_handoff__commits_on_tip_without_moving_bookmark() {
  setup_workspace "commit-handoff-basic"
  _fixture_side_branch
  local wc_before
  wc_before="$(_repo__resolve_commit "$REPO" '@')"

  local commit exit_code=0
  commit="$(_task__commit_handoff "$REPO" side "handoff" \
    --delete base.txt -- _writer_stage_new_file "carried")" || exit_code=$?
  assert_success "handoff commit created" "$exit_code"
  assert_matches "full-length commit ID printed" "$commit" '^[0-9a-f]{40}$'
  assert_eq "handoff sits on the branch tip" \
    "$(_repo__resolve_commit "$REPO" "${commit}-")" "$SIDE_TIP"
  assert_eq "bookmark did NOT advance" \
    "$(_repo__resolve_commit "$REPO" side)" "$SIDE_TIP"
  assert_eq "staged file readable at the handoff" \
    "$(_repo__read_file_at_revision "$REPO" "$commit" new.txt)" "carried"
  local ec=0
  _repo__check_file_exists_at_revision "$REPO" "$commit" base.txt || ec=$?
  assert_failure "deleted file absent at the handoff" "$ec"
  assert_eq "@ did not move" "$(_repo__resolve_commit "$REPO" '@')" "$wc_before"
}

test__task__merge_branch__merges_handoff_and_advances() {
  setup_workspace "merge-branch-basic"
  _fixture_side_branch
  local main_tip
  main_tip="$(_repo__resolve_commit "$REPO" main)"

  local handoff merge exit_code=0
  handoff="$(_task__commit_handoff "$REPO" side "handoff" \
    -- _writer_stage_new_file "merged content")" || exit_code=$?
  assert_success "handoff created" "$exit_code"

  merge="$(_task__merge_branch "$REPO" "land side" main "$handoff")" || exit_code=$?
  assert_success "merge commit created" "$exit_code"
  local merge_parents
  merge_parents="$(jj -R "$REPO" log -r "$merge" --no-graph \
    -T 'parents.map(|c| c.commit_id()).join(" ")' 2>/dev/null)"
  assert_eq "first parent is the receiving branch tip" \
    "${merge_parents%% *}" "$main_tip"
  assert_eq "second parent is the handoff" "${merge_parents##* }" "$handoff"
  assert_eq "merged tree carries the handoff content" \
    "$(_repo__read_file_at_revision "$REPO" "$merge" new.txt)" "merged content"

  local conflict_ec=0
  _task__check_conflicts "$REPO" "$merge" || conflict_ec=$?
  assert_failure "disjoint merge is conflict-free" "$conflict_ec"

  exit_code=0
  _task__advance_branch "$REPO" main "$merge" || exit_code=$?
  assert_success "branch advance succeeds" "$exit_code"
  assert_eq "bookmark moved to the merge" \
    "$(_repo__resolve_commit "$REPO" main)" "$merge"
}

# ---------------------------------------------------------------------------
# _task__list_unmerged_changes
# ---------------------------------------------------------------------------

test__task__list_unmerged_changes__reports_range_paths() {
  setup_workspace "unmerged-changes"
  # Two commits off main: the first is the range's root (a branch's fork
  # commit in the real topology) and is excluded from the diff; the second
  # carries the files the listing must report.
  jj -R "$REPO" new main >/dev/null 2>&1
  edit_file root.txt "root"
  jj_commit "branch root"
  edit_file base.txt "base"
  edit_file prefix/a.txt "a"
  edit_file prefix/b.txt "b"
  jj_commit "branch work"
  jj -R "$REPO" bookmark set side -r '@-' >/dev/null 2>&1
  jj -R "$REPO" new main >/dev/null 2>&1

  local all
  all="$(_task__list_unmerged_changes "$REPO" main side)"
  assert_contains "unfiltered listing has base.txt" "$all" "base.txt"
  assert_contains "unfiltered listing has prefix files" "$all" "prefix/a.txt"
  assert_not_contains "range root commit excluded" "$all" "root.txt"

  local filtered
  filtered="$(_task__list_unmerged_changes "$REPO" main side prefix)"
  assert_line_count "prefix filter keeps only prefix files" "$filtered" 2
  assert_contains "prefix/a.txt reported" "$filtered" "prefix/a.txt"
  assert_contains "prefix/b.txt reported" "$filtered" "prefix/b.txt"
  assert_not_contains "base.txt excluded by prefix" "$filtered" "base.txt"
}

# ---------------------------------------------------------------------------
# _task__list_unmerged_root_parents
# ---------------------------------------------------------------------------

# After a partial checkin, the task's new work hangs off the commit the
# checkin brought into the parent: a commit of the task's own line.
test__task__list_unmerged_root_parents__reports_the_partially_checked_in_tip() {
  setup_workspace "unmerged-root-parents"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo w1 > "$REPO/w1.txt"
  checkpoint_task "w1" >/dev/null || true
  w1_commit=$(get_full_commit_id "$task_id")
  run_tt task checkin "$task_id" >/dev/null 2>&1 || true   # partial checkin

  checkout_task "$task_id" >/dev/null || true
  echo w2 > "$REPO/w2.txt"
  checkpoint_task "w2" >/dev/null || true

  local root_parents
  root_parents="$(_task__list_unmerged_root_parents "$REPO" "$proj_id" "$task_id")"
  assert_eq "the range hangs off the checked-in tip" "$root_parents" "$w1_commit"
  assert_is_ancestor "that commit is already in the parent" "$w1_commit" "$proj_id"
  assert_task_symlink_at_rev "that commit points TASK.md at the task" "$w1_commit" "$task_id"

  assert_eq "an up-to-date range has no root parents" \
    "$(_task__list_unmerged_root_parents "$REPO" "$task_id" "$task_id")" ""
}

# ---------------------------------------------------------------------------
# _task__resolve_current
# ---------------------------------------------------------------------------

# Emits the two lines _task__resolve_current prints as one tab-separated record,
# so a single assertion covers the whole answer.
_resolve_current_record() {
  local task_file bookmark
  { read -r task_file; read -r bookmark; } < <(_task__resolve_current "$REPO" \
    "$(_workspace__get_task_prefix "$REPO")" "$(_workspace__get_project_prefix "$REPO")")
  printf '%s\t%s' "$task_file" "$bookmark"
}

test__task__resolve_current__reports_the_checked_out_task() {
  setup_workspace "resolve-current-checked-out"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  assert_eq "a project worktree reports the project and its task file" \
    "$(_resolve_current_record)" \
    "$(_path__task_file "${proj_id#project/}")"$'\t'"$proj_id"

  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  assert_eq "checking out a task reports that task and its task file" \
    "$(_resolve_current_record)" \
    "$(_path__task_file "${task_id#task/}")"$'\t'"$task_id"
}

test__task__resolve_current__unaffected_by_a_branch_advance() {
  setup_workspace "resolve-current-advanced"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  other_id=$(create_task "other" "Other") || true
  other_wt=$(create_task_worktree "$other_id")
  checkout_task "$task_id" >/dev/null || true

  # A write issued from another worktree advances this branch without moving
  # this working copy, leaving the bookmark on a sibling of the working-copy
  # commit rather than an ancestor of it: the shape in which the nearest
  # bookmarked ancestor is the project the task forked from.
  run_tt_in_worktree "$other_wt" task context add "$task_id" --title "Note" --slug "note" \
    <<< "body" >/dev/null 2>&1 || true
  assert_not_ancestor "the fixture leaves the worktree behind its branch" "$task_id" '@'

  assert_eq "a worktree left behind still reports its own task" \
    "$(_resolve_current_record)" \
    "$(_path__task_file "${task_id#task/}")"$'\t'"$task_id"
}

test__task__resolve_current__reports_a_task_never_checked_out() {
  setup_workspace "resolve-current-never-checked-out"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true

  # Park the working copy on the TODO task's branch without checking it out:
  # the fork commit already records the task.
  jj -R "$REPO" new "$task_id" >/dev/null 2>&1
  assert_eq "a worktree on a never-checked-out task reports that task" \
    "$(_resolve_current_record)" \
    "$(_path__task_file "${task_id#task/}")"$'\t'"$task_id"
}

test__task__resolve_current__reports_no_task_when_none_is_recorded() {
  setup_workspace "resolve-current-none"
  # Nothing has ever been checked out here, so the working copy records no task
  # and the worktree is on no branch — not on whichever bookmark lies below it.
  assert_eq "a worktree with no checked-out task reports no task" \
    "$(_resolve_current_record)" $'\t'
}

# ---------------------------------------------------------------------------
# _task__resolve_file
# ---------------------------------------------------------------------------

test__task__resolve_suffix__strips_either_prefix() {
  assert_eq "a task ID maps to its suffix" \
    "$(_task__resolve_suffix "task/t-0123abcd" "task/" "project/")" "t-0123abcd"
  assert_eq "a project ID maps to its suffix" \
    "$(_task__resolve_suffix "project/p-0123abcd" "task/" "project/")" "p-0123abcd"

  local output='' exit_code=0
  output="$(_task__resolve_suffix "other/t-0123abcd" "task/" "project/")" || exit_code=$?
  assert_eq "an ID with neither prefix returns 1" "$exit_code" "1"
  assert_eq "nothing printed for an ID with neither prefix" "$output" ''
}

test__task__resolve_file__maps_task_and_project_ids() {
  local output='' exit_code=0
  output="$(_task__resolve_file "task/t-0123abcd" "task/" "project/")" || exit_code=$?
  assert_success "a task ID resolves" "$exit_code"
  assert_eq "a task ID maps to its task file" "$output" "$(_path__task_file "t-0123abcd")"

  exit_code=0
  output="$(_task__resolve_file "project/p-0123abcd" "task/" "project/")" || exit_code=$?
  assert_success "a project ID resolves" "$exit_code"
  assert_eq "a project ID maps to its task file" "$output" "$(_path__task_file "p-0123abcd")"
}

test__task__resolve_file__rejects_an_id_with_neither_prefix() {
  local output='' exit_code=0
  output="$(_task__resolve_file "other/t-0123abcd" "task/" "project/")" || exit_code=$?
  assert_eq "an ID with neither prefix returns 1" "$exit_code" "1"
  assert_eq "nothing printed for an ID with neither prefix" "$output" ''
}

# ---------------------------------------------------------------------------
# _task__read_fields, _task__read_status, _task__read_title
# ---------------------------------------------------------------------------

# Usage: _read_fields REV TASK_ID FIELD...
_read_fields() {
  _task__read_fields "$REPO" "$1" "$2" \
    "$(_workspace__get_task_prefix "$REPO")" "$(_workspace__get_project_prefix "$REPO")" "${@:3}"
}

test__task__read_fields__reads_the_branch_tip_not_the_working_copy() {
  setup_workspace "read-fields-branch-tip"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  other_id=$(create_task "other" "Other") || true
  other_wt=$(create_task_worktree "$other_id")
  checkout_task "$task_id" >/dev/null || true

  run_tt_in_worktree "$other_wt" task complete "$task_id" >/dev/null 2>&1 || true
  assert_not_contains "the fixture leaves the working copy behind" \
    "$(cat "$REPO/$(_path__task_file "${task_id#task/}")")" "status: DONE"

  local output='' exit_code=0
  output="$(_read_fields "$task_id" "$task_id" title status)" || exit_code=$?
  assert_success "the fields are read" "$exit_code"
  assert_eq "title and status are read from the branch tip" "$output" $'T\nDONE'
}

test__task__read_fields__reads_at_another_revision() {
  setup_workspace "read-fields-other-rev"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "Child") || true
  checkout_task "$task_id" >/dev/null || true
  edit_file "$REPO/child-work.txt" "work"
  checkpoint_task "Child work" >/dev/null || true
  checkin_task "$task_id" --complete >/dev/null || true

  local output='' exit_code=0
  output="$(_read_fields "$proj_id" "$task_id" status title)" || exit_code=$?
  assert_success "the fields are read at the parent branch" "$exit_code"
  assert_eq "the child's fields are read at the parent branch" "$output" $'DONE\nChild'
}

test__task__read_fields__fails_for_unreadable_task_files() {
  setup_workspace "read-fields-failures"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  local before_child
  before_child=$(get_bookmark_commit "$proj_id")
  task_id=$(create_task "t" "T") || true

  local output='' exit_code=0
  output="$(_read_fields "$task_id" "other/t-0123abcd" title)" || exit_code=$?
  assert_eq "an ID with neither prefix returns 1" "$exit_code" "1"
  assert_eq "nothing printed for an ID with neither prefix" "$output" ''

  exit_code=0
  output="$(_read_fields "task/missing-0123abcd" "task/missing-0123abcd" title)" || exit_code=$?
  assert_eq "a missing revision returns 1" "$exit_code" "1"
  assert_eq "nothing printed for a missing revision" "$output" ''

  exit_code=0
  output="$(_read_fields "$before_child" "$task_id" title)" || exit_code=$?
  assert_eq "a task file absent at REV returns 1" "$exit_code" "1"
  assert_eq "nothing printed for a task file absent at REV" "$output" ''
}

test__task__read_fields__reads_repeatable_fields_as_counted_lists() {
  setup_workspace "read-fields-lists"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  a_id=$(create_task "a" "A") || true
  b_id=$(create_task "b" "B") || true

  local output='' exit_code=0
  output="$(_read_fields "$proj_id" "$proj_id" 'subtask[]' title 'context[]')" || exit_code=$?
  assert_success "the fields are read" "$exit_code"
  assert_eq "subtask is a counted list; an absent context counts zero" "$output" \
    "2"$'\n'"[ ] $a_id"$'\n'"[ ] $b_id"$'\n'"Project"$'\n'"0"
}

test__task__read_fields__rejects_fields_in_the_wrong_form() {
  local output='' exit_code field
  for field in subtask label context 'title[]' 'status[]' unknown 'unknown[]'; do
    exit_code=0
    output="$(_task__read_fields "/nonexistent" "rev" "task/t-0123abcd" "task/" "project/" \
      title "$field" 2>/dev/null)" || exit_code=$?
    assert_eq "'$field' is rejected" "$exit_code" "1"
    assert_eq "nothing printed when '$field' is rejected" "$output" ''
  done
}

# Writer: appends " Child title" to every subtask entry of the task file at
# the path passed as its second argument.
_writer_title_subtask_entries() {
  local stage="$1" path="$2"
  local line out=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == 'subtask: ['* ]] && line+=" Child title"
    out+="$line"$'\n'
  done < "$stage/$path"
  printf '%s' "$out" > "$stage/$path"
}

test__task__subtask_lookups__ignore_trailing_entry_titles() {
  setup_workspace "subtask-lookups-titled"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  child_id=$(create_task "c" "Child") || true

  local task_prefix project_prefix proj_file
  task_prefix="$(_workspace__get_task_prefix "$REPO")"
  project_prefix="$(_workspace__get_project_prefix "$REPO")"
  proj_file="$(_task__resolve_file "$proj_id" "$task_prefix" "$project_prefix")"
  _task__commit_on_branch "$REPO" "$proj_id" "title entries" \
    --modify "$proj_file" -- _writer_title_subtask_entries "$proj_file" >/dev/null
  assert_contains "the fixture titles the subtask entry" \
    "$(_task__read_file "$REPO" "$proj_id" "$proj_file")" "subtask: [ ] $child_id Child title"

  assert_eq "__task__list_subtasks drops the title after the ID" \
    "$(__task__list_subtasks "$REPO" "$proj_id" "$proj_id" "$task_prefix" "$project_prefix")" \
    "[ ]"$'\t'"$child_id"
  assert_eq "the parent is found through a titled entry" \
    "$(_task__find_parent_branch "$REPO" "$child_id" "$task_prefix" "$project_prefix")" \
    "$proj_id"
  assert_eq "a titled entry is followed to the child" \
    "$(_task__collect_descendant_dirs "$REPO" "$proj_id" "$proj_id" \
      "$task_prefix" "$project_prefix")" \
    "$(_path__task_dir "${child_id#task/}")"
}

test__task__read_fields__reads_the_body() {
  setup_workspace "read-fields-body"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  printf 'First\nSecond\n' | run_tt task edit "$task_id" >/dev/null 2>&1 || true

  local title body
  { IFS= read -r title; IFS= read -r -d '' body; } \
    <<< "$(_read_fields "$task_id" "$task_id" title '...')" || true
  body="${body%$'\n'}"
  assert_eq "the title precedes the body" "$title" "T"
  assert_eq "the body is read from the branch" "$body" $'First\nSecond'
}

test__task__resolve_context_file__maps_a_task_and_context_id() {
  local output='' exit_code=0
  output="$(_task__resolve_context_file "task/t-0123abcd" "context/c-4567cdef" \
    "task/" "project/")" || exit_code=$?
  assert_success "a task's context resolves" "$exit_code"
  assert_eq "the context file sits in the task directory" "$output" \
    "$(_path__task_context "t-0123abcd" "context/c-4567cdef")"

  exit_code=0
  output="$(_task__resolve_context_file "other/t-0123abcd" "context/c-4567cdef" \
    "task/" "project/")" || exit_code=$?
  assert_eq "an ID with neither prefix returns 1" "$exit_code" "1"
  assert_eq "nothing printed for an ID with neither prefix" "$output" ''
}

test__task__read_context_fields__reads_fields_and_body() {
  setup_workspace "read-context-fields"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  printf 'Ctx body\n' | run_tt task context add --title 'Say "hi"' --slug "ctx" \
    >/dev/null 2>&1 || true
  local ctx_id
  ctx_id="$(run_tt task context list 2>/dev/null)" || true

  local task_prefix project_prefix title created body
  task_prefix="$(_workspace__get_task_prefix "$REPO")"
  project_prefix="$(_workspace__get_project_prefix "$REPO")"
  { IFS= read -r title; IFS= read -r created; IFS= read -r -d '' body; } \
    <<< "$(_task__read_context_fields "$REPO" "$task_id" "$task_id" "$ctx_id" \
      "$task_prefix" "$project_prefix" title created '...')" || true
  body="${body%$'\n'}"
  assert_eq "the title is decoded" "$title" 'Say "hi"'
  assert_output_not_empty "the created timestamp is read" "$created"
  assert_eq "the body follows the fields" "$body" "Ctx body"

  local output='' exit_code=0 field
  for field in status 'label[]' 'context[]'; do
    exit_code=0
    output="$(_task__read_context_fields "$REPO" "$task_id" "$task_id" "$ctx_id" \
      "$task_prefix" "$project_prefix" "$field" 2>/dev/null)" || exit_code=$?
    assert_eq "'$field' is not a context field" "$exit_code" "1"
    assert_eq "nothing printed for '$field'" "$output" ''
  done

  exit_code=0
  output="$(_task__read_context_fields "$REPO" "$task_id" "$task_id" "context/none-0123abcd" \
    "$task_prefix" "$project_prefix" title 2>/dev/null)" || exit_code=$?
  assert_eq "a missing context file returns 1" "$exit_code" "1"
}

test__task__parse_subtask_entry__checkbox_and_id() {
  assert_eq "an entry with a title" \
    "$(_task__parse_subtask_entry '[x] task/a-1 Title A')" $'[x]\ttask/a-1'
  assert_eq "an unchecked entry" "$(_task__parse_subtask_entry '[ ] task/b-2')" $'[ ]\ttask/b-2'
  local output exit_code=0
  output="$(_task__parse_subtask_entry 'task/c-3')" || exit_code=$?
  assert_eq "an entry without a checkbox returns 1" "$exit_code" "1"
  assert_eq "nothing printed for a malformed entry" "$output" ''
}

test__task__set_field_and_labels__keep_the_canonical_order() {
  local file="$_TEST_ROOT/canonical-set.md"
  printf '%s\n' '---' 'title: "T"' 'status: TODO' 'updated: U' \
    'context: context/c-3' 'subtask: [ ] task/a-1' '---' 'Body' > "$file"
  _task__set_field "$file" created C
  _task__set_labels "$file" bug ui
  _task__set_field "$file" title '"New"'
  assert_eq "absent fields land at their canonical positions" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "New"' 'status: TODO' 'created: C' 'updated: U' \
      'label: bug' 'label: ui' 'context: context/c-3' 'subtask: [ ] task/a-1' '---' 'Body')"
  assert_frontmatter_order "the result is in canonical order" "$(<"$file")"
}

test__task__set_subtasks__replaces_the_entries() {
  local file="$_TEST_ROOT/set-subtasks.md"
  printf '%s\n' '---' 'title: "T"' 'subtask: [ ] task/a-1' 'subtask: [x] task/b-2 B' \
    'context: context/c-3' '---' > "$file"
  _task__set_subtasks "$file" '[x] task/b-2 B' '[ ] task/a-1'
  assert_eq "the entries are rewritten in the given order" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'subtask: [x] task/b-2 B' 'subtask: [ ] task/a-1' \
      'context: context/c-3' '---')"
}

test__task__read_status_and_title__print_the_single_value() {
  setup_workspace "read-status-title"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" 'Say "hi" \ there') || true

  local task_prefix project_prefix
  task_prefix="$(_workspace__get_task_prefix "$REPO")"
  project_prefix="$(_workspace__get_project_prefix "$REPO")"
  assert_eq "the status is printed" \
    "$(_task__read_status "$REPO" "$task_id" "$task_id" "$task_prefix" "$project_prefix")" "TODO"
  assert_eq "the decoded title is printed" \
    "$(_task__read_title "$REPO" "$task_id" "$task_id" "$task_prefix" "$project_prefix")" \
    'Say "hi" \ there'
}

# ---------------------------------------------------------------------------
# _task__find_for_revision
# ---------------------------------------------------------------------------

test__task__find_for_revision__reports_the_recorded_task() {
  setup_workspace "find-for-revision-recorded"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "work" >/dev/null || true

  local output='' exit_code=0
  output="$(_task__find_for_revision "$REPO" "$task_id")" || exit_code=$?
  assert_success "a task branch commit resolves" "$exit_code"
  assert_eq "the task recorded by the commit is reported" "$output" "$task_id"

  exit_code=0
  output="$(_task__find_for_revision "$REPO" "$proj_id")" || exit_code=$?
  assert_success "a project branch commit resolves" "$exit_code"
  assert_eq "the project recorded by the commit is reported" "$output" "$proj_id"
}

test__task__find_for_revision__fails_without_a_single_recorded_task() {
  setup_workspace "find-for-revision-none"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  local output='' exit_code=0
  output="$(_task__find_for_revision "$REPO" 'root()')" || exit_code=$?
  assert_failure "a commit recording no task is rejected" "$exit_code"
  assert_eq "nothing printed for a commit recording no task" "$output" ''

  exit_code=0
  output="$(_task__find_for_revision "$REPO" '@ | @-')" || exit_code=$?
  assert_failure "a revision naming several commits is rejected" "$exit_code"
  assert_eq "nothing printed for several commits" "$output" ''
}

# ---------------------------------------------------------------------------
# _task__set_subtask_status, _task__remove_context
# ---------------------------------------------------------------------------

# Writes a task file with titled and untitled subtask entries, two contexts and
# a body that mimics both.
_make_staged_task_file() {
  printf '%s\n' '---' 'title: "T"' 'status: TODO' 'context: context/a-1' \
    'context: context/b-2' 'subtask: [ ] task/a-1 Title A' 'subtask: [-] task/b-2' \
    '---' 'subtask: [ ] task/a-1' 'context: context/a-1' > "$1"
}

test__task__set_subtask_status__rewrites_the_checkbox_and_keeps_the_title() {
  local file="$_TEST_ROOT/set-status.md"
  _make_staged_task_file "$file"
  _task__set_subtask_status "$file" task/a-1 DONE
  _task__set_subtask_status "$file" task/b-2 TODO
  assert_eq "checkboxes rewritten, titles and body kept" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'status: TODO' 'context: context/a-1' \
      'context: context/b-2' 'subtask: [x] task/a-1 Title A' 'subtask: [ ] task/b-2' \
      '---' 'subtask: [ ] task/a-1' 'context: context/a-1')"
}

test__task__set_subtask_status__unknown_task_is_a_no_op() {
  local file="$_TEST_ROOT/set-status-none.md" before exit_code=0
  _make_staged_task_file "$file"
  before="$(<"$file")"
  _task__set_subtask_status "$file" task/a-11 DONE || exit_code=$?
  assert_success "an unlisted task ID returns 0" "$exit_code"
  assert_eq "file unchanged for an unlisted task ID" "$(<"$file")" "$before"
}

test__task__set_subtask_status__rejects_an_unknown_status() {
  local file="$_TEST_ROOT/set-status-bad.md" before exit_code=0
  _make_staged_task_file "$file"
  before="$(<"$file")"
  _task__set_subtask_status "$file" task/a-1 Done 2>/dev/null || exit_code=$?
  assert_eq "an unknown status returns 1" "$exit_code" "1"
  assert_eq "file unchanged for an unknown status" "$(<"$file")" "$before"
}

test__task__remove_context__removes_only_the_named_context() {
  local file="$_TEST_ROOT/remove-context.md"
  _make_staged_task_file "$file"
  _task__remove_context "$file" context/a-1
  assert_eq "only the named frontmatter entry removed" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "T"' 'status: TODO' 'context: context/b-2' \
      'subtask: [ ] task/a-1 Title A' 'subtask: [-] task/b-2' \
      '---' 'subtask: [ ] task/a-1' 'context: context/a-1')"
}

# ---------------------------------------------------------------------------
# _task__check_file_exists
# ---------------------------------------------------------------------------

test__task__check_file_exists__reports_presence_at_a_revision() {
  setup_workspace "check-file-exists"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  local before_child
  before_child=$(get_bookmark_commit "$proj_id")
  task_id=$(create_task "t" "T") || true

  local task_prefix project_prefix exit_code=0
  task_prefix="$(_workspace__get_task_prefix "$REPO")"
  project_prefix="$(_workspace__get_project_prefix "$REPO")"
  _task__check_file_exists "$REPO" "$task_id" "$task_id" "$task_prefix" "$project_prefix" \
    || exit_code=$?
  assert_success "the task file exists on its branch" "$exit_code"

  exit_code=0
  _task__check_file_exists "$REPO" "$before_child" "$task_id" "$task_prefix" "$project_prefix" \
    || exit_code=$?
  assert_eq "the task file is missing before it was created" "$exit_code" "1"

  local output=''
  exit_code=0
  output="$(_task__check_file_exists "$REPO" "$task_id" "other/t-0123abcd" \
    "$task_prefix" "$project_prefix")" || exit_code=$?
  assert_eq "an ID with neither prefix returns 1" "$exit_code" "1"
  assert_eq "nothing printed" "$output" ''
}

# Helper: create a temp task file with the given frontmatter lines + no body
_make_task_file() {
  local path="$1"; shift
  {
    echo '---'
    for line in "$@"; do echo "$line"; done
    echo '---'
  } > "$path"
}

# ---------------------------------------------------------------------------
# _task__add_context
# ---------------------------------------------------------------------------

test__task__add_context__inserts_before_subtask() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/child-abc12345"

  _task__add_context "$file" "context/research-xyz12345"

  local content
  content="$(cat "$file")"
  assert_frontmatter_order "context before subtask" "$content"

  local ctx_line sub_line
  ctx_line="$(printf '%s\n' "$content" | grep -n '^context:' | cut -d: -f1 | head -1)"
  sub_line="$(printf '%s\n' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "context line number before subtask line number" \
    "$([[ "$ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
}

test__task__add_context__inserts_before_closing_sep_when_no_subtask() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z"

  _task__add_context "$file" "context/research-xyz12345"

  local content
  content="$(cat "$file")"
  assert_contains "context entry present" "$content" "context: context/research-xyz12345"
  assert_frontmatter_order "valid ordering" "$content"
}

test__task__add_context__multiple_contexts_before_subtask() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/child-abc12345"

  _task__add_context "$file" "context/ctx1-aaa11111"
  _task__add_context "$file" "context/ctx2-bbb22222"

  local content
  content="$(cat "$file")"
  assert_frontmatter_order "all contexts before subtask" "$content"

  local last_ctx_line sub_line
  last_ctx_line="$(printf '%s\n' "$content" | grep -n '^context:' | cut -d: -f1 | tail -1)"
  sub_line="$(printf '%s\n' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "last context line before first subtask line" \
    "$([[ "$last_ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
}

# ---------------------------------------------------------------------------
# _task__add_subtask
# ---------------------------------------------------------------------------

test__task__add_subtask__inserts_after_context() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "context: context/research-xyz12345"

  _task__add_subtask "$file" "task/child-abc12345"

  local content
  content="$(cat "$file")"
  assert_frontmatter_order "subtask after context" "$content"

  local ctx_line sub_line
  ctx_line="$(printf '%s\n' "$content" | grep -n '^context:' | cut -d: -f1 | head -1)"
  sub_line="$(printf '%s\n' "$content" | grep -n '^subtask:' | cut -d: -f1 | head -1)"
  assert_eq "context line before subtask line" \
    "$([[ "$ctx_line" -lt "$sub_line" ]] && echo yes || echo no)" "yes"
}

test__task__add_subtask__inserts_at_end_when_empty() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z"

  _task__add_subtask "$file" "task/child-abc12345"

  local content
  content="$(cat "$file")"
  assert_contains "subtask entry present" "$content" "subtask: [ ] task/child-abc12345"
  assert_frontmatter_order "valid ordering" "$content"
}

test__task__remove_subtask__removes_any_checkbox_state() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/unchecked-aaa11111" \
    "subtask: [x] task/checked-bbb22222 Checked title" \
    "subtask: [-] task/skipped-ccc33333"

  _task__remove_subtask "$file" "task/unchecked-aaa11111"
  local content
  content="$(cat "$file")"
  assert_not_contains "unchecked entry removed" "$content" "task/unchecked-aaa11111"
  assert_contains "checked entry intact" "$content" \
    "subtask: [x] task/checked-bbb22222 Checked title"
  assert_contains "skipped entry intact" "$content" \
    "subtask: [-] task/skipped-ccc33333"

  _task__remove_subtask "$file" "task/checked-bbb22222"
  content="$(cat "$file")"
  assert_not_contains "checked entry with trailing title removed" \
    "$content" "task/checked-bbb22222"
  assert_contains "skipped entry still intact" "$content" \
    "subtask: [-] task/skipped-ccc33333"

  _task__remove_subtask "$file" "task/skipped-ccc33333"
  content="$(cat "$file")"
  assert_not_contains "skipped entry removed" "$content" "task/skipped-ccc33333"
  assert_not_contains "no subtask lines left" "$content" "subtask:"
  assert_contains "other frontmatter intact" "$content" 'title: "Test"'
}

test__task__remove_subtask__ignores_body_fence() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  # The body's fenced block repeats the exact frontmatter entry; only the
  # frontmatter occurrence may be removed.
  printf '%s\n' \
    '---' \
    'title: "Test"' \
    'subtask: [ ] task/real-abc12345' \
    '---' \
    'The frontmatter looked like:' \
    '' \
    '```markdown' \
    '---' \
    'subtask: [ ] task/real-abc12345' \
    '---' \
    '```' \
    > "$file"

  _task__remove_subtask "$file" "task/real-abc12345"

  local content
  content="$(cat "$file")"
  assert_output_empty "frontmatter has no subtask entries left" \
    "$(_frontmatter__parse_repeated_field "$content" subtask)"
  assert_eq "body occurrence survives" \
    "$(printf '%s\n' "$content" | grep -c 'subtask: \[ \] task/real-abc12345' || true)" \
    "1"
  assert_contains "body prose intact" "$content" "The frontmatter looked like:"
}

test__task__remove_subtask__nonexistent_entry_is_noop() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/present-aaa11111"

  local before
  before="$(cat "$file")"
  local exit_code=0
  _task__remove_subtask "$file" "task/absent-zzz99999" || exit_code=$?
  assert_success "removing a nonexistent entry returns 0" "$exit_code"
  assert_eq "file unchanged" "$(cat "$file")" "$before"
}

# ---------------------------------------------------------------------------
# _task__rename_subtask
# ---------------------------------------------------------------------------

test__task__rename_subtask__preserves_checkbox_title_and_order() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/first-aaa11111" \
    "subtask: [x] task/second-bbb22222 Second title" \
    "subtask: [-] task/third-ccc33333"

  _task__rename_subtask "$file" "task/second-bbb22222" "task/renamed-bbb22222"
  local content
  content="$(cat "$file")"
  assert_contains "entry repointed, checkbox and title kept" "$content" \
    "subtask: [x] task/renamed-bbb22222 Second title"
  assert_not_contains "old ID gone" "$content" "task/second-bbb22222"
  assert_eq "list order preserved" \
    "$(_frontmatter__parse_repeated_field "$content" subtask)" \
    "$(printf '[ ] task/first-aaa11111\n[x] task/renamed-bbb22222 Second title\n[-] task/third-ccc33333')"

  _task__rename_subtask "$file" "task/third-ccc33333" "task/last-ccc33333"
  content="$(cat "$file")"
  assert_contains "skipped-state entry repointed" "$content" \
    "subtask: [-] task/last-ccc33333"
  assert_contains "other frontmatter intact" "$content" 'title: "Test"'
}

test__task__rename_subtask__ignores_body_fence() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  # The body's fenced block repeats the exact frontmatter entry; only the
  # frontmatter occurrence may be rewritten.
  printf '%s\n' \
    '---' \
    'title: "Test"' \
    'subtask: [ ] task/real-abc12345' \
    '---' \
    'The frontmatter looked like:' \
    '' \
    '```markdown' \
    '---' \
    'subtask: [ ] task/real-abc12345' \
    '---' \
    '```' \
    > "$file"

  _task__rename_subtask "$file" "task/real-abc12345" "task/renamed-abc12345"

  local content
  content="$(cat "$file")"
  assert_eq "frontmatter entry repointed" \
    "$(_frontmatter__parse_repeated_field "$content" subtask)" \
    "[ ] task/renamed-abc12345"
  assert_eq "body occurrence survives" \
    "$(printf '%s\n' "$content" | grep -c 'subtask: \[ \] task/real-abc12345' || true)" \
    "1"
}

test__task__rename_subtask__nonexistent_entry_is_noop() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local file="$dir/TASK.md"

  _make_task_file "$file" \
    "title: \"Test\"" \
    "status: TODO" \
    "created: 2025-01-01T00:00:00Z" \
    "updated: 2025-01-01T00:00:00Z" \
    "subtask: [ ] task/present-aaa11111"

  local before
  before="$(cat "$file")"
  local exit_code=0
  _task__rename_subtask "$file" "task/absent-zzz99999" "task/other-zzz99999" \
    || exit_code=$?
  assert_success "renaming a nonexistent entry returns 0" "$exit_code"
  assert_eq "file unchanged" "$(cat "$file")" "$before"
}

test__task__write_file__canonical_task_file() {
  local file="$_TEST_ROOT/write-file.md"
  _task__write_file "$file" 'Say "hi"' TODO C U $'Body\nmore' bug ui
  assert_eq "frontmatter in canonical order, then the body" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "Say \"hi\""' 'status: TODO' 'created: C' 'updated: U' \
      'label: bug' 'label: ui' '---' 'Body' 'more')"
  assert_eq "the title reads back" "$(_frontmatter__parse_values "$(<"$file")" title)" 'Say "hi"'
}

test__task__write_file__empty_body() {
  local file="$_TEST_ROOT/write-file-empty.md"
  _task__write_file "$file" '' TODO C C ''
  assert_eq "nothing follows the closing delimiter" "$(cat "$file"; printf x)" \
    "$(printf '%s\n' '---' 'title: ""' 'status: TODO' 'created: C' 'updated: C' '---')"$'\n'x
}

test__task__write_context_file__fields_and_body() {
  local file="$_TEST_ROOT/write-context.md"
  _task__write_context_file "$file" 'Notes' C U 'Context body.'
  assert_eq "a context file has a title, timestamps and a body" "$(<"$file")" \
    "$(printf '%s\n' '---' 'title: "Notes"' 'created: C' 'updated: U' '---' 'Context body.')"
}

run_tests "tt lib/task (unit)"
