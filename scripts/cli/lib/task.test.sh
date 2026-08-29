#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

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
  assert_contains "w2 is included in the second historical component" \
    "$(_repo__list_commits_in_range "$REPO" "$second_base" "$second_tip")" "$w2_commit"
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

run_tests "tt lib/task (unit)"
