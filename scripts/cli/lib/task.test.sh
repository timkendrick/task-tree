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

run_tests "tt lib/task (unit)"
