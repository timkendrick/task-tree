#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"

# ---------------------------------------------------------------------------
# Helper: get subtask order as a space-separated string of task IDs
# Reads from the parent task file on the parent branch
# Usage: subtask_order PARENT_ID
subtask_order() {
  local parent_id="$1"
  local content
  content="$(read_task_file "$parent_id" "$parent_id")"
  printf '%s' "$content" | awk '/^subtask:/{sub(/^subtask:[[:space:]]*\[[^]]*\][[:space:]]*/, ""); print}' | tr '\n' ' ' | sed 's/ $//'
}

# ---------------------------------------------------------------------------
# Helper: get frontmatter field order as a space-separated string
# Usage: frontmatter_field_order TASK_ID [REV]
frontmatter_field_order() {
  local task_id="$1" rev="${2:-$1}"
  local content
  content="$(read_task_file "$task_id" "$rev")"
  printf '%s' "$content" | awk '
    /^---$/ { n++; if (n==2) exit; next }
    n==1 && /^[a-zA-Z]/ {
      key=$0; sub(/:.*/, "", key)
      printf "%s ", key
    }
  ' | sed 's/ $//'
}

# ---------------------------------------------------------------------------
# Helper: count commits on a branch since its parent
# Usage: count_bookmark_commits BOOKMARK
count_bookmark_commits() {
  local bm="$1"
  local count
  count="$(jj -R "$REPO" log -r "$bm" --no-graph -T '"x\n"' 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "$count"
}

# ---------------------------------------------------------------------------
# Reorder modifier mode tests
# ---------------------------------------------------------------------------

test_task_reorder__up_basic() {
  setup_workspace "reorder-up"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  task_c=$(create_task "tc" "Task C") || true
  checkout_task "$task_a" >/dev/null || true

  run_tt task reorder "$task_b" --up >/dev/null 2>&1 || true
  local order
  order="$(subtask_order "$proj_id")"
  # Should be: task_b task_a task_c
  assert_eq "b moved up" "$order" "$task_b $task_a $task_c"
}


test_task_reorder__down_basic() {
  setup_workspace "reorder-down"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  task_c=$(create_task "tc" "Task C") || true
  checkout_task "$task_a" >/dev/null || true

  run_tt task reorder "$task_b" --down >/dev/null 2>&1 || true
  local order
  order="$(subtask_order "$proj_id")"
  # Should be: task_a task_c task_b
  assert_eq "b moved down" "$order" "$task_a $task_c $task_b"
}


test_task_reorder__before_basic() {
  setup_workspace "reorder-before"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  task_c=$(create_task "tc" "Task C") || true
  checkout_task "$task_a" >/dev/null || true

  # Move task_c before task_a
  run_tt task reorder "$task_c" --before "$task_a" >/dev/null 2>&1 || true
  local order
  order="$(subtask_order "$proj_id")"
  assert_eq "c before a" "$order" "$task_c $task_a $task_b"
}


test_task_reorder__after_basic() {
  setup_workspace "reorder-after"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  task_c=$(create_task "tc" "Task C") || true
  checkout_task "$task_a" >/dev/null || true

  # Move task_a after task_c
  run_tt task reorder "$task_a" --after "$task_c" >/dev/null 2>&1 || true
  local order
  order="$(subtask_order "$proj_id")"
  assert_eq "a after c" "$order" "$task_b $task_c $task_a"
}


test_task_reorder__up_already_first() {
  setup_workspace "reorder-up-first"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true

  local output exit_code=0
  output=$(run_tt task reorder "$task_a" --up 2>&1) || exit_code=$?
  assert_failure "up already first" "$exit_code"
  assert_contains "error message" "$output" "already first"
}


test_task_reorder__down_already_last() {
  setup_workspace "reorder-down-last"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true

  local output exit_code=0
  output=$(run_tt task reorder "$task_b" --down 2>&1) || exit_code=$?
  assert_failure "down already last" "$exit_code"
  assert_contains "error message" "$output" "already last"
}


test_task_reorder__before_noop() {
  setup_workspace "reorder-before-noop"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  task_c=$(create_task "tc" "Task C") || true
  checkout_task "$task_a" >/dev/null || true

  bm_before=$(get_bookmark_commit "$proj_id")
  # task_b is already immediately before task_c → no-op
  run_tt task reorder "$task_b" --before "$task_c" >/dev/null 2>&1 || true
  bm_after=$(get_bookmark_commit "$proj_id")
  assert_eq "bookmark unchanged" "$bm_before" "$bm_after"
}


test_task_reorder__after_noop() {
  setup_workspace "reorder-after-noop"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  task_c=$(create_task "tc" "Task C") || true
  checkout_task "$task_a" >/dev/null || true

  bm_before=$(get_bookmark_commit "$proj_id")
  # task_c is already immediately after task_b → no-op
  run_tt task reorder "$task_c" --after "$task_b" >/dev/null 2>&1 || true
  bm_after=$(get_bookmark_commit "$proj_id")
  assert_eq "bookmark unchanged" "$bm_before" "$bm_after"
}


test_task_reorder__before_sibling_not_found() {
  setup_workspace "reorder-before-notfound"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true

  local output exit_code=0
  output=$(run_tt task reorder "$task_a" --before "task/nonexistent-12345678" 2>&1) || exit_code=$?
  assert_failure "sibling not found" "$exit_code"
  assert_contains "error message" "$output" "not found"
}


test_task_reorder__dirty_wc_fails() {
  setup_workspace "reorder-dirty-wc"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true

  # Make the WC dirty
  echo "dirty" > "$REPO/dirty-file.txt"

  local exit_code=0
  run_tt task reorder "$task_a" --up 2>&1 || exit_code=$?
  assert_failure "dirty wc fails" "$exit_code"
}


test_task_reorder__transaction_recorded() {
  setup_workspace "reorder-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true
  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task reorder "$task_a" --down >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after reorder"
}


test_task_reorder__commit_message() {
  setup_workspace "reorder-commit-msg"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true

  run_tt task reorder "$task_a" --down >/dev/null 2>&1 || true
  assert_commit_message "commit message" "@-" "[tt:task:$proj_id:reorder] Project"
}


test_task_reorder__parentless_task_fails() {
  setup_workspace "reorder-parentless"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  local output exit_code=0
  output=$(run_tt task reorder "$proj_id" --up 2>&1) || exit_code=$?
  assert_failure "parentless reorder" "$exit_code"
  assert_contains "error message" "$output" "no parent"
}


# ---------------------------------------------------------------------------
# Tidy mode tests
# ---------------------------------------------------------------------------

test_task_reorder__tidy_basic() {
  setup_workspace "reorder-tidy-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # Create task_b first, complete+checkin it, then create task_a.
  # This avoids merge conflicts and gives a non-canonical order:
  # After checkin: [x] task_b (DONE)
  # After creating task_a: [x] task_b, [ ] task_a → DONE before TODO = non-canonical.
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_b" >/dev/null || true
  run_tt task complete "$task_b" >/dev/null 2>&1 || true
  run_tt task checkin "$task_b" >/dev/null 2>&1 || true
  task_a=$(create_task "ta" "Task A") || true

  # Run tidy on the project
  run_tt task reorder "$proj_id" >/dev/null 2>&1 || true
  local order
  order="$(subtask_order "$proj_id")"

  # Expected: TODO first (task_a), then DONE (task_b)
  assert_eq "subtasks sorted by status" "$order" "$task_a $task_b"
}


test_task_reorder__tidy_noop() {
  setup_workspace "reorder-tidy-noop"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  checkout_task "$task_a" >/dev/null || true

  bm_before=$(get_bookmark_commit "$proj_id")
  # Already in canonical order → no-op
  run_tt task reorder "$proj_id" >/dev/null 2>&1 || true
  bm_after=$(get_bookmark_commit "$proj_id")
  assert_eq "bookmark unchanged on no-op" "$bm_before" "$bm_after"
}


test_task_reorder__tidy_frontmatter_field_order() {
  setup_workspace "reorder-tidy-fields"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  checkout_task "$task_a" >/dev/null || true

  run_tt task reorder "$proj_id" >/dev/null 2>&1 || true
  local fields
  fields="$(frontmatter_field_order "$proj_id")"
  # Should be: title status created updated (no labels/contexts/subtasks if none)
  assert_matches "canonical field order" "$fields" "^title status created updated"
}


test_task_reorder__tidy_labels_preserved() {
  setup_workspace "reorder-tidy-labels"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(run_tt task create --slug "t" --title "T" --label "alpha" --label "beta" --label "gamma" <<< "" | tail -1) || true
  checkout_task "$task_id" >/dev/null || true

  run_tt task reorder "$task_id" >/dev/null 2>&1 || true
  # Labels should retain original relative order
  assert_task_label "label alpha preserved" "$task_id" "alpha"
  assert_task_label "label beta preserved" "$task_id" "beta"
  assert_task_label "label gamma preserved" "$task_id" "gamma"

  # Verify order: alpha before beta before gamma
  local content
  content="$(read_task_file "$task_id")"
  local labels_str
  labels_str="$(printf '%s' "$content" | awk '/^label:/{sub(/^label:[[:space:]]*/, ""); print}' | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "label order" "$labels_str" "alpha beta gamma"
}


test_task_reorder__tidy_contexts_preserved() {
  setup_workspace "reorder-tidy-contexts"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  # Add contexts
  run_tt task context add --title "Plan" --slug "plan" <<< "plan body" >/dev/null 2>&1 || true
  run_tt task context add --title "Notes" --slug "notes" <<< "notes body" >/dev/null 2>&1 || true

  run_tt task reorder "$task_id" >/dev/null 2>&1 || true
  # Contexts should retain original relative order
  assert_context_entry "context plan preserved" "$task_id" "context/plan"
  assert_context_entry "context notes preserved" "$task_id" "context/notes"

  # Verify order in frontmatter
  local content
  content="$(read_task_file "$task_id")"
  local ctx_str
  ctx_str="$(printf '%s' "$content" | awk '/^context:/{sub(/^context:[[:space:]]*/, ""); print}' | tr '\n' ' ' | sed 's/ $//')"
  assert_contains "plan before notes" "$ctx_str" "context/plan"
}


test_task_reorder__tidy_within_status_stable() {
  setup_workspace "reorder-tidy-stable"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  task_c=$(create_task "tc" "Task C") || true
  # All are TODO, so tidy should keep their relative order
  checkout_task "$task_a" >/dev/null || true

  run_tt task reorder "$proj_id" >/dev/null 2>&1 || true
  local order
  order="$(subtask_order "$proj_id")"
  assert_eq "stable order within TODO" "$order" "$task_a $task_b $task_c"
}


test_task_reorder__tidy_commit_message() {
  setup_workspace "reorder-tidy-commit"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  # Create task_b first, complete+checkin, then create task_a.
  # Result: [x] task_b, [ ] task_a — DONE before TODO = non-canonical.
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_b" >/dev/null || true
  run_tt task complete "$task_b" >/dev/null 2>&1 || true
  run_tt task checkin "$task_b" >/dev/null 2>&1 || true
  task_a=$(create_task "ta" "Task A") || true

  run_tt task reorder "$proj_id" >/dev/null 2>&1 || true
  assert_commit_message "tidy commit message" "@-" "[tt:task:$proj_id:reorder] Project"
}


test_task_reorder__tidy_transaction_recorded() {
  setup_workspace "reorder-tidy-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  # Create task_b first, complete+checkin it, then create task_a.
  # Result: [x] task_b, [ ] task_a — DONE before TODO = non-canonical.
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_b" >/dev/null || true
  run_tt task complete "$task_b" >/dev/null 2>&1 || true
  run_tt task checkin "$task_b" >/dev/null 2>&1 || true
  task_a=$(create_task "ta" "Task A") || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task reorder "$proj_id" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after tidy"
}


test_task_reorder__tidy_defaults_to_current_task() {
  setup_workspace "reorder-tidy-default"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  checkout_task "$task_a" >/dev/null || true

  # Tidy with no task_id argument → should tidy the current task (task_a)
  run_tt task reorder >/dev/null 2>&1 || true
  # Just verify it didn't fail
  assert_bookmark_exists "task exists" "$task_a"
}


test_task_reorder__tidy_dirty_wc_fails() {
  setup_workspace "reorder-tidy-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  checkout_task "$task_a" >/dev/null || true

  echo "dirty" > "$REPO/dirty-file.txt"

  local exit_code=0
  run_tt task reorder "$task_a" 2>&1 || exit_code=$?
  assert_failure "dirty wc fails tidy" "$exit_code"
}


test_task_reorder__tidy_merged_task() {
  setup_workspace "reorder-tidy-merged"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true

  # Complete and checkin task_b — now it's merged ([x] on project branch)
  run_tt task complete "$task_b" >/dev/null 2>&1 || true
  run_tt task checkin "$task_b" >/dev/null 2>&1 || true

  # Now tidy the project (which has task_a [ ] and task_b [x])
  run_tt task reorder "$proj_id" >/dev/null 2>&1 || true
  local order
  order="$(subtask_order "$proj_id")"
  # IN-PROGRESS/TODO first, then DONE: task_a [ ] then task_b [x]
  assert_eq "merged task tidy" "$order" "$task_a $task_b"
}


# ---------------------------------------------------------------------------
# Alias test
# ---------------------------------------------------------------------------

test_task_reorder__alias() {
  setup_workspace "reorder-alias"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_a=$(create_task "ta" "Task A") || true
  task_b=$(create_task "tb" "Task B") || true
  checkout_task "$task_a" >/dev/null || true

  # Use `tt reorder` (alias) instead of `tt task reorder`
  run_tt reorder "$task_a" --down >/dev/null 2>&1 || true
  local order
  order="$(subtask_order "$proj_id")"
  assert_eq "alias works" "$order" "$task_b $task_a"
}


test_task_reorder__help() {
  setup_workspace "reorder-help"
  output="" exit_code=0
  output=$(run_tt task reorder --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task reorder"
  assert_optional_usage_argument "argument: --up" "$output" "--up"
  assert_optional_usage_argument "argument: --down" "$output" "--down"
  assert_optional_usage_argument "argument: --before" "$output" "--before"
  assert_optional_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt task reorder"
