#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for worktree management in lib/worktree.sh
# ---------------------------------------------------------------------------

test__worktree__parse_list_line__normal_line() {
  local parsed
  parsed="$(_worktree__parse_list_line 'default: /some/absolute/path')"
  assert_eq "workspace name parsed" "$(printf '%s' "$parsed" | sed -n '1p')" "default"
  assert_eq "workspace path parsed" "$(printf '%s' "$parsed" | sed -n '2p')" "/some/absolute/path"
}

test__worktree__parse_list_line__error_path_line() {
  local parsed
  parsed="$(_worktree__parse_list_line 'wt1: <Error: Workspace has no recorded path: wt1>')"
  assert_eq "workspace name parsed from error line" \
    "$(printf '%s' "$parsed" | sed -n '1p')" "wt1"
  assert_output_empty "error path becomes empty string" \
    "$(printf '%s' "$parsed" | sed -n '2p')"
}

test__worktree__list_entries__lists_default_workspace() {
  setup_workspace "worktree-list-entries"

  local entries
  entries="$(_worktree__list_entries "$REPO")"
  assert_line_count "exactly one workspace" "$entries" 1
  assert_contains "default workspace record" "$entries" "$(printf 'default\t%s' "$REPO")"
}

test__worktree__resolve_name_path__round_trip() {
  setup_workspace "worktree-name-path"

  local name
  name="$(_worktree__resolve_name "$REPO" "$REPO")"
  assert_eq "repo path resolves to the default workspace name" "$name" "default"

  local path
  path="$(_worktree__resolve_path "$REPO" "$name")"
  assert_eq "workspace name resolves back to the repo path" "$path" "$REPO"
}

test__worktree__resolve_name__unknown_path_fails() {
  setup_workspace "worktree-unknown-path"

  local exit_code=0
  _worktree__resolve_name "$REPO" "/no/such/worktree" >/dev/null || exit_code=$?
  assert_failure "unknown worktree path" "$exit_code"
}

test__worktree__check_exists__accepts_a_worktree_root() {
  setup_workspace "worktree-exists-yes"

  local exit_code=0
  _worktree__check_exists "$REPO" || exit_code=$?
  assert_success "the repository's own worktree root is recognized" "$exit_code"
}

test__worktree__check_exists__rejects_a_plain_directory_and_a_missing_path() {
  setup_workspace "worktree-exists-no"

  local plain="$_TEST_ROOT/worktree-exists-no/plain"
  mkdir -p "$plain"

  local exit_code=0
  _worktree__check_exists "$plain" || exit_code=$?
  assert_failure "a directory holding no worktree is rejected" "$exit_code"

  exit_code=0
  _worktree__check_exists "$_TEST_ROOT/worktree-exists-no/absent" || exit_code=$?
  assert_failure "a path that does not exist is rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# Fixtures for the working-copy invariant and sync machinery
# ---------------------------------------------------------------------------

# Check out a task with a commit of its own and leave the current working copy
# as an empty commit above its tip:
#   project -- feature work (bookmark <task>) -- @ (empty)
# A real task rather than a hand-made bookmark, because a worktree is attributed
# to a branch by the task its working copy records (_worktree__resolve_branch_at)
# and a bookmark nothing was ever checked out on names no task.
# Sets FEATURE to the task ID, FEATURE_TIP to the branch tip's full commit ID.
_fixture_feature_checkout() {
  local project_id
  project_id="$(create_project "proj" "Project")"
  checkout_task "$project_id" >/dev/null 2>&1
  FEATURE="$(create_task "feature" "Feature")"
  checkout_task "$FEATURE" >/dev/null 2>&1
  edit_file one.txt "one"
  checkpoint_task "feature work" >/dev/null 2>&1
  FEATURE_TIP="$(get_full_commit_id "$FEATURE")"
}

# Usage: _advance_branch_bare BRANCH FILENAME CONTENT
# Advance BRANCH by one bare commit adding FILENAME with CONTENT, without
# touching any working copy (bare changeset + bookmark move). Prints the new
# tip's full commit ID.
_advance_branch_bare() {
  local branch="$1" filename="$2" content="$3"
  local stage="$_TEST_ROOT/stage-$$-$RANDOM"
  mkdir -p "$stage"
  printf '%s\n' "$content" > "$stage/$filename"
  local commit
  commit="$(_repo__commit_changeset "$REPO" "$branch" "advance $branch" "$stage")" || return 1
  _repo__set_bookmark "$REPO" "$branch" "$commit" || return 1
  printf '%s\n' "$commit"
}

# Usage: _add_worktree NAME REV
# Create a worktree named NAME on REV next to $REPO and print its
# recorded path (resolved through the workspace list, so path comparisons in
# assertions match what the worktree functions themselves see).
_add_worktree() {
  local name="$1" rev="$2"
  _repo__create_worktree "$REPO" "$name" "$(dirname "$REPO")/$name" "$rev" || return 1
  _worktree__resolve_path "$REPO" "$name"
}

# ---------------------------------------------------------------------------
# _worktree__check_stale
# ---------------------------------------------------------------------------

test__worktree__check_stale__healthy_worktree_is_not_stale() {
  setup_workspace "wt-stale-healthy"

  local status=0
  _worktree__check_stale "$REPO" "$REPO" || status=$?
  assert_eq "a healthy worktree reports not stale" "$status" "1"
}

test__worktree__check_stale__worktree_behind_its_branch_is_not_stale() {
  setup_workspace "wt-stale-behind"
  local proj_id task_id wt
  proj_id="$(create_project "proj" "Project")"
  checkout_task "$proj_id"
  task_id="$(create_task "behind" "Behind")"
  wt="$(create_task_worktree "$task_id")"

  # Advance the branch past the worktree without rewriting its @: the worktree
  # is left behind, which is a different condition from being stale.
  local tip
  tip="$(get_full_commit_id "$task_id")"
  jj -R "$REPO" --ignore-working-copy new --no-edit -m "ahead" "$tip" >/dev/null 2>&1
  jj -R "$REPO" --ignore-working-copy bookmark set "$task_id" \
    -r "description(substring:'ahead')" >/dev/null 2>&1

  local behind=0
  _worktree__check_behind "$REPO" "$wt" || behind=$?
  assert_success "the worktree really is behind its branch" "$behind"

  local status=0
  _worktree__check_stale "$REPO" "$wt" || status=$?
  assert_eq "a worktree that is merely behind is not stale" "$status" "1"
}

test__worktree__check_stale__rewritten_working_copy_is_stale() {
  setup_workspace "wt-stale-rewritten"
  local proj_id task_id wt
  proj_id="$(create_project "proj" "Project")"
  checkout_task "$proj_id"
  task_id="$(create_task "rewritten" "Rewritten")"
  wt="$(create_task_worktree "$task_id")"

  make_worktree_stale "$wt"

  local status=0
  _worktree__check_stale "$REPO" "$wt" || status=$?
  assert_eq "a rewritten working copy reports stale" "$status" "0"
}

test__worktree__check_stale__unreadable_state_is_undetermined() {
  setup_workspace "wt-stale-unreadable"

  local status=0
  _worktree__check_stale "$REPO" "$_TEST_ROOT" 2>/dev/null || status=$?
  assert_eq "an unreadable workspace is undetermined, not healthy" "$status" "2"
}

# ---------------------------------------------------------------------------
# _worktree__ensure_working_copy
# ---------------------------------------------------------------------------

test__worktree__ensure_working_copy__refuses_bookmark_on_clean_wc() {
  setup_workspace "wt-ensure-clean"
  # Put a bookmark directly on the (clean, empty) working-copy commit: the
  # refusal must not depend on the working copy being dirty.
  jj -R "$REPO" bookmark set topic -r '@' >/dev/null 2>&1
  assert_wc_clean "working copy is clean before the check"

  local out exit_code=0
  out="$(_worktree__ensure_working_copy "$REPO" 2>&1)" || exit_code=$?
  assert_failure "refuses while @ carries a bookmark" "$exit_code"
  assert_eq "first line names the bookmark" \
    "$(printf '%s' "$out" | sed -n '1p')" \
    "Error: The working-copy commit is the tip of bookmark 'topic'."
}

test__worktree__ensure_working_copy__refuses_unrelated_bookmark() {
  setup_workspace "wt-ensure-unrelated"
  _fixture_feature_checkout
  # The bookmark on @ has nothing to do with "feature" (the branch a command
  # would be writing to); any bookmark on @ must trigger the refusal.
  jj -R "$REPO" bookmark set scratch -r '@' >/dev/null 2>&1

  local out exit_code=0
  out="$(_worktree__ensure_working_copy "$REPO" 2>&1)" || exit_code=$?
  assert_failure "refuses for a bookmark unrelated to any branch being written" "$exit_code"
  assert_contains "message names the unrelated bookmark" "$out" \
    "the tip of bookmark 'scratch'"
  assert_contains "message suggests moving off the bookmark" "$out" \
    "Move off it first, by starting a new working-copy commit on top of it."
}

test__worktree__ensure_working_copy__accepts_wc_above_bookmark() {
  setup_workspace "wt-ensure-normal"
  _fixture_feature_checkout

  local exit_code=0
  _worktree__ensure_working_copy "$REPO" || exit_code=$?
  assert_success "normal state (@ child of a bookmarked commit) accepted" "$exit_code"
}

# ---------------------------------------------------------------------------
# _worktree__ensure_worktree_current
# ---------------------------------------------------------------------------

test__worktree__ensure_worktree_current__accepts_a_healthy_worktree() {
  setup_workspace "wt-current-healthy"

  local exit_code=0
  _worktree__ensure_worktree_current "$REPO" "$REPO" || exit_code=$?
  assert_success "a healthy worktree is accepted" "$exit_code"
}

test__worktree__ensure_worktree_current__refuses_a_stale_worktree() {
  setup_workspace "wt-current-stale"
  local proj_id task_id wt
  proj_id="$(create_project "proj" "Project")"
  checkout_task "$proj_id"
  task_id="$(create_task "stale" "Stale")"
  wt="$(create_task_worktree "$task_id")"
  make_worktree_stale "$wt"

  local out exit_code=0
  out="$(_worktree__ensure_worktree_current "$REPO" "$wt" 2>&1)" || exit_code=$?
  assert_failure "a stale worktree is refused" "$exit_code"
  assert_eq "first line names the stale workspace" \
    "$(printf '%s' "$out" | sed -n '1p')" \
    "Error: The workspace is stale: $wt"
  assert_contains "the refusal names the recovery command" "$out" \
    "tt worktree refresh $wt --force"
  assert_contains "the refusal states the consequence" "$out" \
    "Uncommitted changes in that workspace will be lost."
}

test__worktree__ensure_worktree_current__refuses_an_undetermined_worktree() {
  setup_workspace "wt-current-undetermined"

  local out exit_code=0
  out="$(_worktree__ensure_worktree_current "$REPO" "$_TEST_ROOT" 2>&1)" || exit_code=$?
  assert_failure "an unreadable workspace is refused, not passed" "$exit_code"
  assert_contains "the refusal names the workspace" "$out" \
    "Error: Could not determine the state of the workspace: $_TEST_ROOT"
}

# ---------------------------------------------------------------------------
# _worktree__ensure_canonical_current
# ---------------------------------------------------------------------------

test__worktree__ensure_canonical_current__accepts_a_healthy_canonical_workspace() {
  setup_workspace "wt-canonical-healthy"
  local proj_id task_id wt
  proj_id="$(create_project "proj" "Project")"
  checkout_task "$proj_id"
  task_id="$(create_task "healthy" "Healthy")"
  wt="$(create_task_worktree "$task_id")"

  local exit_code=0
  ( cd "$wt" && _worktree__ensure_canonical_current "$wt" ) || exit_code=$?
  assert_success "a healthy canonical workspace is accepted" "$exit_code"
}

test__worktree__ensure_canonical_current__refuses_a_stale_canonical_workspace() {
  setup_workspace "wt-canonical-stale"
  local proj_id task_id wt
  proj_id="$(create_project "proj" "Project")"
  checkout_task "$proj_id"
  task_id="$(create_task "guarded" "Guarded")"
  wt="$(create_task_worktree "$task_id")"
  make_worktree_stale "$REPO"

  local out exit_code=0
  out="$( cd "$wt" && _worktree__ensure_canonical_current "$wt" 2>&1 )" || exit_code=$?
  assert_failure "a stale canonical workspace is refused" "$exit_code"
  assert_contains "the refusal names the canonical workspace" "$out" \
    "Error: The workspace is stale: $REPO"
  assert_contains "the refusal names the recovery command" "$out" "tt worktree refresh"
}

test__worktree__ensure_canonical_current__skips_when_canonical_is_the_invoking_worktree() {
  setup_workspace "wt-canonical-is-invoking"
  make_worktree_stale "$REPO"

  # The invoking worktree is left to fail on its own terms, so the guard must
  # stand aside even though the canonical workspace is stale.
  local exit_code=0
  _worktree__ensure_canonical_current "$REPO" >/dev/null 2>&1 || exit_code=$?
  assert_success "the guard skips the workspace the command runs in" "$exit_code"
}

test__worktree__ensure_canonical_current__skips_inside_a_transaction() {
  setup_workspace "wt-canonical-nested"
  local proj_id task_id wt
  proj_id="$(create_project "proj" "Project")"
  checkout_task "$proj_id"
  task_id="$(create_task "nested" "Nested")"
  wt="$(create_task_worktree "$task_id")"
  make_worktree_stale "$REPO"

  # A nested guard would refuse mid-transaction, and the rollback that refusal
  # triggers is the one staleness breaks.
  local exit_code=0
  ( cd "$wt" && TT_TRANSACTION_ID=someop _worktree__ensure_canonical_current "$wt" ) \
    >/dev/null 2>&1 || exit_code=$?
  assert_success "the guard skips inside an open transaction" "$exit_code"
}

# ---------------------------------------------------------------------------
# _worktree__reattach_current
# ---------------------------------------------------------------------------

test__worktree__reattach_current__follows_branch_advance() {
  setup_workspace "wt-reattach-follow"
  _fixture_feature_checkout

  local new_tip
  new_tip="$(_advance_branch_bare "$FEATURE" adv.txt "advanced")"
  assert_output_not_empty "bare advance produced a commit" "$new_tip"

  local exit_code=0
  _worktree__reattach_current "$REPO" "$FEATURE" "$FEATURE_TIP" "$new_tip" || exit_code=$?
  assert_success "reattach succeeds" "$exit_code"
  assert_eq "working-copy parent is the new tip" \
    "$(get_full_commit_id '@-')" "$new_tip"
  assert_file_exists "new commit's file materialized on disk" "$REPO/adv.txt"
  assert_eq "materialized content matches the bare write" \
    "$(cat "$REPO/adv.txt")" "advanced"
}

test__worktree__reattach_current__ignores_wc_on_unrelated_branch() {
  setup_workspace "wt-reattach-unrelated"
  # Build a side branch entirely by bare writes, so the working copy stays an
  # empty commit above main and never descends from the side branch.
  local stage="$_TEST_ROOT/stage-side"
  mkdir -p "$stage"
  printf 'side\n' > "$stage/side.txt"
  local side_tip
  side_tip="$(_repo__commit_changeset "$REPO" main "side branch" "$stage")"
  _repo__set_bookmark "$REPO" side "$side_tip"
  local new_tip
  new_tip="$(_advance_branch_bare side more.txt "more")"

  local parent_before
  parent_before="$(get_full_commit_id '@-')"
  local exit_code=0
  _worktree__reattach_current "$REPO" side "$side_tip" "$new_tip" || exit_code=$?
  assert_success "reattach is a no-op (status 0)" "$exit_code"
  assert_eq "working copy did not move" "$(get_full_commit_id '@-')" "$parent_before"
  assert_file_not_exists "side branch files not materialized" "$REPO/more.txt"
}

test__worktree__reattach_current__leaves_wc_on_child_branch() {
  setup_workspace "wt-reattach-child"
  # The task forks from the project's tip, so @ on the task descends from that
  # tip. A plain advance of the project must still leave @ on the task.
  local proj_id task_id
  proj_id="$(create_project "proj" "Project")"
  checkout_task "$proj_id" >/dev/null 2>&1
  task_id="$(create_task "child" "Child")"
  checkout_task "$task_id" >/dev/null 2>&1
  local proj_tip
  proj_tip="$(get_full_commit_id "$proj_id")"
  local fork_status=0
  is_vcs_ancestor "$proj_tip" '@' || fork_status=$?
  assert_success "the project tip is an ancestor of the working copy" "$fork_status"
  local new_tip
  new_tip="$(_advance_branch_bare "$proj_id" adv.txt "advanced")"

  local parent_before
  parent_before="$(get_full_commit_id '@-')"
  local exit_code=0
  _worktree__reattach_current "$REPO" "$proj_id" "$proj_tip" "$new_tip" || exit_code=$?
  assert_success "reattach is a no-op (status 0)" "$exit_code"
  assert_eq "working copy did not move" "$(get_full_commit_id '@-')" "$parent_before"
  assert_file_not_exists "project advance not materialized" "$REPO/adv.txt"
}

test__worktree__reattach_current__follows_merge_on_own_branch() {
  setup_workspace "wt-reattach-merge-own"
  _fixture_feature_checkout
  # Build a side line forked off the feature tip by bare writes, then merge
  # it back into feature. @ sits directly on the feature tip, so it follows
  # the merge advance.
  local stage="$_TEST_ROOT/stage-merge-own"
  mkdir -p "$stage"
  printf 'child\n' > "$stage/child.txt"
  local child_tip
  child_tip="$(_repo__commit_changeset "$REPO" "$FEATURE_TIP" "child work" "$stage")"
  _repo__set_bookmark "$REPO" child "$child_tip"
  local merge
  merge="$(_repo__create_merge_commit "$REPO" "land child" "$FEATURE_TIP" "$child_tip")"

  local exit_code=0
  _worktree__reattach_current "$REPO" "$FEATURE" "$FEATURE_TIP" "$merge" || exit_code=$?
  assert_success "reattach succeeds" "$exit_code"
  assert_eq "working-copy parent is the merge" "$(get_full_commit_id '@-')" "$merge"
  assert_file_exists "merged file materialized on disk" "$REPO/child.txt"
}

test__worktree__reattach_current__leaves_wc_on_merged_branch() {
  setup_workspace "wt-reattach-merge-child"
  _fixture_feature_checkout
  # main is the receiving branch here and feature the merged-in line: @ sits
  # on feature, and every feature commit descends from main's tip, so a plain
  # descent check would drag @ onto the merge. The reattach must leave it
  # alone.
  local main_tip
  main_tip="$(get_full_commit_id main)"
  local stage="$_TEST_ROOT/stage-merge-child"
  mkdir -p "$stage"
  printf 'handoff\n' > "$stage/handoff.txt"
  local handoff
  handoff="$(_repo__commit_changeset "$REPO" "$FEATURE_TIP" "handoff" "$stage")"
  local merge
  merge="$(_repo__create_merge_commit "$REPO" "land feature" "$main_tip" "$handoff")"

  local parent_before
  parent_before="$(get_full_commit_id '@-')"
  local exit_code=0
  _worktree__reattach_current "$REPO" main "$main_tip" "$merge" || exit_code=$?
  assert_success "reattach is a no-op (status 0)" "$exit_code"
  assert_eq "working copy did not move" "$(get_full_commit_id '@-')" "$parent_before"
  assert_eq "working copy still on the feature tip" "$parent_before" "$FEATURE_TIP"
  assert_file_not_exists "merge content not materialized" "$REPO/handoff.txt"
}

# ---------------------------------------------------------------------------
# Bare writes vs. other worktrees, listing and syncing
# ---------------------------------------------------------------------------

test__worktree__bare_write__leaves_other_worktree_untouched() {
  setup_workspace "wt-bare-untouched"
  _fixture_feature_checkout
  # Move the current working copy off feature so the worktree is
  # the only one on the branch.
  jj -R "$REPO" new main >/dev/null 2>&1
  local wt_path
  wt_path="$(_add_worktree wt-other "$FEATURE")"
  assert_output_not_empty "worktree created" "$wt_path"

  printf 'never-snapshotted\n' > "$wt_path/pending.txt"
  local wt_rev_before
  wt_rev_before="$(_repo__get_worktree_revision "$REPO" wt-other)"

  local new_tip
  new_tip="$(_advance_branch_bare "$FEATURE" adv.txt "advanced")"
  assert_output_not_empty "bare advance produced a commit" "$new_tip"

  assert_file_exists "worktree tracked file still on disk" "$wt_path/one.txt"
  assert_eq "tracked content unchanged" "$(cat "$wt_path/one.txt")" "one"
  assert_file_exists "un-snapshotted file still on disk" "$wt_path/pending.txt"
  assert_eq "un-snapshotted content unchanged" \
    "$(cat "$wt_path/pending.txt")" "never-snapshotted"
  assert_file_not_exists "bare write not materialized in the worktree" \
    "$wt_path/adv.txt"
  assert_eq "worktree working-copy commit unchanged" \
    "$(_repo__get_worktree_revision "$REPO" wt-other)" "$wt_rev_before"

  # jj must remain fully usable inside the worktree (this call snapshots, so
  # it runs after all the untouched-state assertions above).
  local wt_desc exit_code=0
  wt_desc="$(jj -R "$wt_path" log -r '@-' --no-graph -T 'description.first_line()' 2>/dev/null)" \
    || exit_code=$?
  assert_success "jj commands still work in the worktree" "$exit_code"
  assert_contains "worktree parent is still the old feature tip" "$wt_desc" "feature work"
}

test__worktree__list_unsynced__reports_behind_worktree() {
  setup_workspace "wt-unsynced-list"
  _fixture_feature_checkout
  # The current working copy stays on feature too: after the bare write it is
  # equally behind, but must be omitted from the report (callers reattach the
  # current worktree directly).
  local wt_path
  wt_path="$(_add_worktree wt-behind "$FEATURE")"
  assert_output_not_empty "worktree created" "$wt_path"

  local new_tip
  new_tip="$(_advance_branch_bare "$FEATURE" adv.txt "advanced")"
  assert_output_not_empty "bare advance produced a commit" "$new_tip"

  local records
  records="$(_worktree__list_unsynced "$REPO" "$FEATURE")"
  assert_line_count "exactly one out-of-sync worktree" "$records" 1
  assert_eq "record is <path><TAB><task-id>" "$records" \
    "$(printf '%s\t%s' "$wt_path" "$FEATURE")"

  local err
  err="$(_worktree__report_unsynced "$REPO" "$FEATURE" 2>&1 >/dev/null)"
  assert_eq "warning header line" \
    "$(printf '%s' "$err" | sed -n '1p')" \
    "The following worktrees are now out of sync:"
  assert_eq "indented worktree line names path and task id" \
    "$(printf '%s' "$err" | sed -n '2p')" \
    "  $wt_path ($FEATURE)"
  assert_contains "directs the user to tt worktree sync" "$err" "tt worktree sync"
}

test__worktree__report_unsynced__silent_when_in_sync() {
  setup_workspace "wt-unsynced-silent"
  _fixture_feature_checkout
  local wt_path
  wt_path="$(_add_worktree wt-insync "$FEATURE")"
  assert_output_not_empty "worktree created" "$wt_path"

  assert_output_empty "no unsynced records while the branch tip is unchanged" \
    "$(_worktree__list_unsynced "$REPO" "$FEATURE")"
  local err exit_code=0
  err="$(_worktree__report_unsynced "$REPO" "$FEATURE" 2>&1 >/dev/null)" || exit_code=$?
  assert_success "report returns 0 with nothing to report" "$exit_code"
  assert_output_empty "no warning printed" "$err"
}

test__worktree__sync__brings_behind_worktree_forward() {
  setup_workspace "wt-sync"
  _fixture_feature_checkout
  jj -R "$REPO" new main >/dev/null 2>&1
  local wt_path
  wt_path="$(_add_worktree wt-sync "$FEATURE")"
  assert_output_not_empty "worktree created" "$wt_path"

  # Uncommitted changes in the worktree: an edit to a tracked file plus a
  # file jj has never snapshotted.
  printf 'one edited\n' > "$wt_path/one.txt"
  printf 'fresh\n' > "$wt_path/fresh.txt"

  local new_tip
  new_tip="$(_advance_branch_bare "$FEATURE" adv.txt "advanced")"
  assert_output_not_empty "bare advance produced a commit" "$new_tip"

  local out exit_code=0
  out="$(_worktree__sync "$REPO" "$wt_path")" || exit_code=$?
  assert_success "sync succeeds" "$exit_code"
  assert_eq "synced record names branch, old parent and new tip" "$out" \
    "$(printf 'synced\t%s\t%s\t%s' "$FEATURE" "$FEATURE_TIP" "$new_tip")"
  assert_eq "worktree parent is now the branch head" \
    "$(jj -R "$wt_path" --ignore-working-copy log -r '@-' --no-graph -T 'commit_id' 2>/dev/null)" \
    "$new_tip"
  assert_file_exists "bare-write file materialized in the worktree" "$wt_path/adv.txt"
  assert_eq "tracked-file edit preserved" "$(cat "$wt_path/one.txt")" "one edited"
  assert_file_exists "never-snapshotted file preserved" "$wt_path/fresh.txt"
  assert_eq "never-snapshotted content preserved" "$(cat "$wt_path/fresh.txt")" "fresh"

  exit_code=0
  out="$(_worktree__sync "$REPO" "$wt_path")" || exit_code=$?
  assert_success "second sync succeeds" "$exit_code"
  assert_eq "second sync reports up-to-date" "$out" \
    "$(printf 'up-to-date\t%s' "$FEATURE")"
}

test__worktree__record_working_copy__records_uncommitted_work() {
  setup_workspace "wt-record-wc"
  _fixture_feature_checkout
  jj -R "$REPO" new main >/dev/null 2>&1
  local wt_path
  wt_path="$(_add_worktree wt-record "$FEATURE")"
  assert_output_not_empty "worktree created" "$wt_path"

  # A file the backend has never seen: the case where the work exists only on
  # disk and the recorded operation is the sole route back to it.
  printf 'unsaved\n' > "$wt_path/scratch.txt"

  local op
  op="$(_worktree__record_working_copy "$wt_path")"
  assert_output_not_empty "an operation id is returned" "$op"
  assert_contains "the file is now in the worktree's working-copy commit" \
    "$(jj -R "$wt_path" --ignore-working-copy log -r '@' --no-graph -T '' \
         --summary 2>/dev/null)" \
    "scratch.txt"

  # The recording targets the named worktree, not the invoking one.
  assert_output_empty "the invoking worktree was not recorded" \
    "$(jj -R "$REPO" --ignore-working-copy log -r '@' --no-graph -T '' \
         --summary 2>/dev/null)"
}

test__worktree__record_working_copy__clean_worktree_returns_nothing() {
  setup_workspace "wt-record-wc-clean"
  _fixture_feature_checkout
  jj -R "$REPO" new main >/dev/null 2>&1
  local wt_path
  wt_path="$(_add_worktree wt-record-clean "$FEATURE")"
  assert_output_not_empty "worktree created" "$wt_path"

  local op exit_code=0
  op="$(_worktree__record_working_copy "$wt_path")" || exit_code=$?
  assert_success "recording a clean worktree succeeds" "$exit_code"
  assert_output_empty "nothing to record yields no operation id" "$op"
}

test__worktree__record_working_copy__missing_worktree_fails() {
  setup_workspace "wt-record-wc-missing"

  # Empty output must mean "nothing to record" and nothing else, so a worktree
  # that cannot be captured reports failure rather than an empty result.
  local op exit_code=0
  op="$(_worktree__record_working_copy "$REPO/does-not-exist")" || exit_code=$?
  assert_failure "a missing worktree fails the caller" "$exit_code"
  assert_output_empty "a missing worktree yields no operation id" "$op"
}

test__worktree__resolve_branch__reads_the_checked_out_task() {
  setup_workspace "worktree-resolve-branch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  assert_eq "a project worktree resolves to the project branch" \
    "$(_worktree__resolve_branch "$REPO" "$REPO")" "$proj_id"

  task_id=$(create_task "t" "T") || true
  other_id=$(create_task "other" "Other") || true
  other_wt=$(create_task_worktree "$other_id")
  checkout_task "$task_id" >/dev/null || true
  assert_eq "checking out a task moves the worktree to its branch" \
    "$(_worktree__resolve_branch "$REPO" "$REPO")" "$task_id"

  # A write issued from another worktree advances this branch without moving
  # this working copy: the bookmark leaves its ancestry, and what the working
  # copy records does not change. Issuing the write here instead would carry
  # this worktree onto the new tip and never produce the shape.
  run_tt_in_worktree "$other_wt" task context add "$task_id" --title "n" --slug "n" \
    <<< "body" >/dev/null 2>&1 || true
  assert_not_ancestor "the write leaves this worktree behind its branch" "$task_id" '@'
  assert_eq "a worktree left behind is still on its own branch" \
    "$(_worktree__resolve_branch "$REPO" "$REPO")" "$task_id"
}

test__worktree__resolve_branch__unaffected_by_bookmarked_descendants() {
  setup_workspace "worktree-resolve-descendants"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  # The shape no ranking of bookmarks can resolve: the project's own worktree is
  # parked above a tip that several branches now descend from — a checked-in
  # child rebased onto it, and freshly created sibling stubs — none of which is
  # on another's line.
  task_a=$(create_task "a" "A") || true
  checkout_task "$task_a" >/dev/null || true
  edit_file "a.txt" "a"
  checkpoint_task "A work" >/dev/null || true
  checkin_task "$task_a" --complete >/dev/null 2>&1 || true
  checkout_task "$proj_id" >/dev/null || true
  task_b=$(create_task "b" "B") || true
  task_c=$(create_task "c" "C") || true
  run_tt task propagate --from "$proj_id" >/dev/null 2>&1 || true

  assert_eq "the project's worktree is still on the project branch" \
    "$(_worktree__resolve_branch "$REPO" "$REPO")" "$proj_id"
  assert_neq "and not on a sibling stub" \
    "$(_worktree__resolve_branch "$REPO" "$REPO")" "$task_b"
  assert_neq "and not on the checked-in child" \
    "$(_worktree__resolve_branch "$REPO" "$REPO")" "$task_a"
  assert_output_not_empty "the stub tasks exist" "$task_c"
}

test__worktree__resolve_branch__no_task_no_branch() {
  setup_workspace "worktree-resolve-none"
  # A working copy that has never had a task checked out records no task
  # symlink, and is on no branch at all rather than on the nearest bookmark.
  local out exit_code=0
  out="$(_worktree__resolve_branch "$REPO" "$REPO")" || exit_code=$?
  assert_failure "a worktree with no checked-out task has no branch" "$exit_code"
  assert_output_empty "nothing printed without a branch" "$out"
}

test__worktree__find_for_branch__finds_worktree_on_branch() {
  setup_workspace "worktree-find-branch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  local wt
  wt=$(create_task_worktree "$task_id")

  local found
  found="$(_worktree__find_for_branch "$REPO" "$task_id")"
  assert_eq "the task's worktree is found" "$found" "$wt"

  found="$(_worktree__find_for_branch "$REPO" "main")"
  assert_output_empty "no worktree is on main" "$found"
}

test__worktree__find_for_branch__excludes_the_canonical_repository() {
  setup_workspace "worktree-find-branch-canonical"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  local found
  found="$(_worktree__find_for_branch "$REPO" "$proj_id")"
  assert_output_empty "a branch checked out only in the canonical repository has no worktree" \
    "$found"

  task_id=$(create_task "t" "T") || true
  local wt
  wt=$(create_task_worktree "$task_id")
  # Park the canonical repository above the task's tip as well, so its working
  # copy records the task too.
  jj -R "$REPO" new "$task_id" >/dev/null 2>&1
  assert_eq "the canonical repository is on the task" \
    "$(_worktree__resolve_branch "$REPO" "$REPO")" "$task_id"

  found="$(_worktree__find_for_branch "$REPO" "$task_id")"
  assert_eq "only the worktree is found" "$found" "$wt"

  found="$(_worktree__find_for_branch "$wt" "$task_id")"
  assert_eq "the same result from inside the worktree" "$found" "$wt"
}

test__worktree__find_for_branch__lists_worktrees_in_listing_order() {
  setup_workspace "worktree-find-branch-order"
  _fixture_feature_checkout
  jj -R "$REPO" new main >/dev/null 2>&1
  local wt_a wt_b
  wt_a="$(_add_worktree wt-a "$FEATURE")"
  wt_b="$(_add_worktree wt-b "$FEATURE")"

  local found
  found="$(_worktree__find_for_branch "$REPO" "$FEATURE")"
  assert_eq "both worktrees in workspace-listing order" "$found" \
    "$(printf '%s\n%s' "$wt_a" "$wt_b")"
}

# ---------------------------------------------------------------------------
# The canonical repository in worktree listings
# ---------------------------------------------------------------------------

test__worktree__list__omits_the_canonical_repository() {
  setup_workspace "worktree-list-no-canonical"
  _fixture_feature_checkout
  local wt_path
  wt_path="$(_add_worktree wt-listed "$FEATURE")"

  local records
  records="$(_worktree__list "$REPO")"
  assert_eq "only the worktree is listed" "$records" \
    "$(printf 'wt-listed\t%s\t%s' "$wt_path" "$FEATURE")"

  records="$(_worktree__list "$wt_path")"
  assert_eq "the same listing from inside the worktree" "$records" \
    "$(printf 'wt-listed\t%s\t%s' "$wt_path" "$FEATURE")"
}

test__worktree__list_all_unsynced__skips_the_canonical_repository_from_a_worktree() {
  setup_workspace "wt-all-unsynced-from-worktree"
  _fixture_feature_checkout
  # The canonical repository stays on feature, so the bare write leaves it
  # behind just like the worktree.
  local wt_path
  wt_path="$(_add_worktree wt-behind "$FEATURE")"
  _advance_branch_bare "$FEATURE" adv.txt "advanced" >/dev/null

  local records
  records="$(_worktree__list_all_unsynced "$wt_path")"
  assert_eq "only the worktree is reported" "$records" \
    "$(printf '%s\t%s' "$wt_path" "$FEATURE")"
}

test__worktree__list_all_unsynced__includes_the_canonical_repository_from_it() {
  setup_workspace "wt-all-unsynced-from-canonical"
  _fixture_feature_checkout
  local wt_path
  wt_path="$(_add_worktree wt-behind "$FEATURE")"
  _advance_branch_bare "$FEATURE" adv.txt "advanced" >/dev/null

  local records
  records="$(_worktree__list_all_unsynced "$REPO")"
  assert_line_count "the canonical repository and the worktree are reported" "$records" 2
  assert_contains "the canonical repository is reported" "$records" \
    "$(printf '%s\t%s' "$REPO" "$FEATURE")"
  assert_contains "the worktree is reported" "$records" \
    "$(printf '%s\t%s' "$wt_path" "$FEATURE")"
}

test__worktree__list_unsynced__never_reports_the_canonical_repository() {
  setup_workspace "wt-unsynced-no-canonical"
  _fixture_feature_checkout
  local wt_a wt_b
  wt_a="$(_add_worktree wt-a "$FEATURE")"
  wt_b="$(_add_worktree wt-b "$FEATURE")"
  _advance_branch_bare "$FEATURE" adv.txt "advanced" >/dev/null

  local records
  records="$(_worktree__list_unsynced "$wt_a" "$FEATURE")"
  assert_eq "only the other worktree is reported" "$records" \
    "$(printf '%s\t%s' "$wt_b" "$FEATURE")"
}

run_tests "tt lib/worktree (unit)"
