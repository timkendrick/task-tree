#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

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

# ---------------------------------------------------------------------------
# Fixtures for the working-copy invariant and sync machinery
# ---------------------------------------------------------------------------

# Build a "feature" branch on top of the setup_workspace state and leave the
# current working copy as an empty commit above its tip:
#   main -- feature work (bookmark "feature") -- @ (empty)
# Sets FEATURE_TIP to the branch tip's full commit ID.
_fixture_feature_checkout() {
  edit_file one.txt "one"
  jj_commit "feature work"
  jj -R "$REPO" bookmark set feature -r '@-' >/dev/null 2>&1
  FEATURE_TIP="$(get_full_commit_id 'feature')"
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

# Usage: _create_secondary_worktree NAME REV
# Create a secondary workspace named NAME on REV next to $REPO and print its
# recorded path (resolved through the workspace list, so path comparisons in
# assertions match what the worktree functions themselves see).
_create_secondary_worktree() {
  local name="$1" rev="$2"
  _repo__create_worktree "$REPO" "$name" "$(dirname "$REPO")/$name" "$rev" || return 1
  _worktree__resolve_path "$REPO" "$name"
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
  assert_contains "message suggests moving off the bookmark" "$out" "jj new"
}

test__worktree__ensure_working_copy__accepts_wc_above_bookmark() {
  setup_workspace "wt-ensure-normal"
  _fixture_feature_checkout

  local exit_code=0
  _worktree__ensure_working_copy "$REPO" || exit_code=$?
  assert_success "normal state (@ child of a bookmarked commit) accepted" "$exit_code"
}

# ---------------------------------------------------------------------------
# _worktree__reattach_current
# ---------------------------------------------------------------------------

test__worktree__reattach_current__follows_branch_advance() {
  setup_workspace "wt-reattach-follow"
  _fixture_feature_checkout

  local new_tip
  new_tip="$(_advance_branch_bare feature adv.txt "advanced")"
  assert_output_not_empty "bare advance produced a commit" "$new_tip"

  local exit_code=0
  _worktree__reattach_current "$REPO" "$FEATURE_TIP" "$new_tip" || exit_code=$?
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
  _worktree__reattach_current "$REPO" "$side_tip" "$new_tip" || exit_code=$?
  assert_success "reattach is a no-op (status 0)" "$exit_code"
  assert_eq "working copy did not move" "$(get_full_commit_id '@-')" "$parent_before"
  assert_file_not_exists "side branch files not materialized" "$REPO/more.txt"
}

# ---------------------------------------------------------------------------
# Bare writes vs. other worktrees, listing and syncing
# ---------------------------------------------------------------------------

test__worktree__bare_write__leaves_other_worktree_untouched() {
  setup_workspace "wt-bare-untouched"
  _fixture_feature_checkout
  # Move the current working copy off feature so the secondary worktree is
  # the only one on the branch.
  jj -R "$REPO" new main >/dev/null 2>&1
  local wt_path
  wt_path="$(_create_secondary_worktree wt-other feature)"
  assert_output_not_empty "secondary worktree created" "$wt_path"

  printf 'never-snapshotted\n' > "$wt_path/pending.txt"
  local wt_rev_before
  wt_rev_before="$(_repo__get_worktree_revision "$REPO" wt-other)"

  local new_tip
  new_tip="$(_advance_branch_bare feature adv.txt "advanced")"
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
  assert_eq "worktree parent is still the old feature tip" "$wt_desc" "feature work"
}

test__worktree__list_unsynced__reports_behind_worktree() {
  setup_workspace "wt-unsynced-list"
  _fixture_feature_checkout
  # The current working copy stays on feature too: after the bare write it is
  # equally behind, but must be omitted from the report (callers reattach the
  # current worktree directly).
  local wt_path
  wt_path="$(_create_secondary_worktree wt-behind feature)"
  assert_output_not_empty "secondary worktree created" "$wt_path"

  local new_tip
  new_tip="$(_advance_branch_bare feature adv.txt "advanced")"
  assert_output_not_empty "bare advance produced a commit" "$new_tip"

  local records
  records="$(_worktree__list_unsynced "$REPO" feature)"
  assert_line_count "exactly one out-of-sync worktree" "$records" 1
  assert_eq "record is <path><TAB><task-id>" "$records" \
    "$(printf '%s\t%s' "$wt_path" feature)"

  local err
  err="$(_worktree__report_unsynced "$REPO" feature 2>&1 >/dev/null)"
  assert_eq "warning header line" \
    "$(printf '%s' "$err" | sed -n '1p')" \
    "The following worktrees are now out of sync:"
  assert_eq "indented worktree line names path and task id" \
    "$(printf '%s' "$err" | sed -n '2p')" \
    "  $wt_path (feature)"
  assert_contains "directs the user to tt worktree sync" "$err" "tt worktree sync"
}

test__worktree__report_unsynced__silent_when_in_sync() {
  setup_workspace "wt-unsynced-silent"
  _fixture_feature_checkout
  local wt_path
  wt_path="$(_create_secondary_worktree wt-insync feature)"
  assert_output_not_empty "secondary worktree created" "$wt_path"

  assert_output_empty "no unsynced records while the branch tip is unchanged" \
    "$(_worktree__list_unsynced "$REPO" feature)"
  local err exit_code=0
  err="$(_worktree__report_unsynced "$REPO" feature 2>&1 >/dev/null)" || exit_code=$?
  assert_success "report returns 0 with nothing to report" "$exit_code"
  assert_output_empty "no warning printed" "$err"
}

test__worktree__sync__brings_behind_worktree_forward() {
  setup_workspace "wt-sync"
  _fixture_feature_checkout
  jj -R "$REPO" new main >/dev/null 2>&1
  local wt_path
  wt_path="$(_create_secondary_worktree wt-sync feature)"
  assert_output_not_empty "secondary worktree created" "$wt_path"

  # Uncommitted changes in the worktree: an edit to a tracked file plus a
  # file jj has never snapshotted.
  printf 'one edited\n' > "$wt_path/one.txt"
  printf 'fresh\n' > "$wt_path/fresh.txt"

  local new_tip
  new_tip="$(_advance_branch_bare feature adv.txt "advanced")"
  assert_output_not_empty "bare advance produced a commit" "$new_tip"

  local out exit_code=0
  out="$(_worktree__sync "$REPO" "$wt_path")" || exit_code=$?
  assert_success "sync succeeds" "$exit_code"
  assert_eq "synced record names branch, old parent and new tip" "$out" \
    "$(printf 'synced\t%s\t%s\t%s' feature "$FEATURE_TIP" "$new_tip")"
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
    "$(printf 'up-to-date\t%s' feature)"
}

test__worktree__find_for_branch__finds_workspace_on_branch() {
  setup_workspace "worktree-find-branch"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true

  local task_prefix project_prefix
  task_prefix="$(_workspace__get_task_prefix "$REPO")"
  project_prefix="$(_workspace__get_project_prefix "$REPO")"

  local found
  found="$(_worktree__find_for_branch "$REPO" "$proj_id" "$task_prefix" "$project_prefix")"
  assert_contains "repo workspace is on the project branch" "$found" "$REPO"

  found="$(_worktree__find_for_branch "$REPO" "main" "$task_prefix" "$project_prefix")"
  assert_output_empty "no workspace is on main" "$found"
}

run_tests "tt lib/worktree (unit)"
