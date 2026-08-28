#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for shared helpers in lib/common.sh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# write_task_stub (via task/create)
# ---------------------------------------------------------------------------

test_write_task_stub__has_placeholder_title() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  local suffix="my-stub-abc12345"
  write_task_stub "$dir" "$suffix" 2>/dev/null

  local file="$dir/.tt/task/$suffix/TASK.md"
  local content
  content="$(cat "$file")"
  assert_contains "placeholder title line" "$content" 'title: ""'
  assert_contains "status TODO" "$content" 'status: TODO'
}

# ---------------------------------------------------------------------------
# get_task_range_context / resolve_task_range
# ---------------------------------------------------------------------------

test_get_task_range_context__matches_resolve_task_range() {
  setup_workspace "range-context-compat"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  checkpoint_task "work" >/dev/null || true

  local context legacy
  context="$(get_task_range_context "$REPO" "$task_id")"
  legacy="$(resolve_task_range "$REPO" "$task_id")"

  local ctx_task ctx_parent ctx_upper
  IFS=$'\t' read -r ctx_task ctx_parent ctx_upper <<< "$context"
  assert_eq "context reports the task id" "$ctx_task" "$task_id"
  assert_eq "resolve_task_range matches context's parent/upper fields" \
    "$legacy" "$ctx_parent $ctx_upper"
}

# ---------------------------------------------------------------------------
# get_full_task_range_records
# ---------------------------------------------------------------------------

# Fetches full-range records for TASK_ID via its resolved parent/upper bound,
# printing them tab-separated (one per line) on stdout for the caller to parse.
_full_range_records_for() {
  local task_id="$1"
  local context
  context="$(get_task_range_context "$REPO" "$task_id")"
  local ctx_task parent_bookmark upper_bound
  IFS=$'\t' read -r ctx_task parent_bookmark upper_bound <<< "$context"
  get_full_task_range_records "$REPO" "$task_id" "$parent_bookmark" "$upper_bound"
}

test_full_task_range__current_only_when_never_checked_in() {
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

test_full_task_range__excludes_creation_and_wrapper_commits() {
  setup_workspace "full-range-wrappers"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  echo work > "$REPO/work.txt"
  checkpoint_task "work" >/dev/null || true
  checkpoint_commit=$(get_full_commit_id "$task_id")
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
  handoff_commit=$(jj -R "$REPO" log --no-graph -r "description(substring:'${task_id}:handoff]')" -T 'commit_id' 2>/dev/null)
  checkin_commit=$(jj -R "$REPO" log --no-graph -r "description(substring:'${task_id}:checkin]')" -T 'commit_id' 2>/dev/null)
  assert_revset_count "handoff excluded from component" "(${base}..${tip}) & ${handoff_commit}" 0
  assert_revset_count "checkin merge excluded from component" "(${base}..${tip}) & ${checkin_commit}" 0
}

test_full_task_range__historical_plus_current() {
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
  w2_commit=$(get_full_commit_id "$task_id")

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
  assert_revset_count "w2 is included in the current component" \
    "(${current_base}..${current_tip}) & ${w2_commit}" 1
}

test_full_task_range__multiple_discontiguous_historical_components() {
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
  w2_commit=$(get_full_commit_id "$task_id")
  # --force accepts the parent-side subtask-checkbox conflict a second,
  # unrebased checkin produces here. --rebase is deliberately avoided: it
  # pre-merges the parent's tree (including its TASK.md target) into the
  # child, so the second handoff's symlink already points at the parent with
  # no transition left to detect -- an ambiguous case this discovery
  # intentionally ignores (see DESIGN.md).
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
  assert_revset_count "w2 is included in the second historical component" \
    "(${second_base}..${second_tip}) & ${w2_commit}" 1
}

test_full_task_range__unrelated_project_work_excluded() {
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
  unrelated_commit=$(get_full_commit_id "$proj_id")
  checkpoint_task "unrelated project work" >/dev/null || true

  local records
  records="$(_full_range_records_for "$task_id")"
  assert_line_count "only the one historical component" "$records" 1

  local base tip
  IFS=$'\t' read -r base tip _ _ _ <<< "$records"
  assert_revset_count "unrelated project commit excluded" "(${base}..${tip}) & ${unrelated_commit}" 0
}

test_full_task_range__project_branch_rejected() {
  setup_workspace "full-range-project-rejected"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  checkpoint_task "project work" >/dev/null || true

  local exit_code=0
  get_full_task_range_records "$REPO" "$proj_id" "main" "$proj_id" >/dev/null 2>&1 || exit_code=$?
  assert_failure "full range discovery rejects project branches" "$exit_code"
}

run_tests "tt lib/common (unit)"
