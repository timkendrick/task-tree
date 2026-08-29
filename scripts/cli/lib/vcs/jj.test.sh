#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../harness/harness.sh"
# shellcheck source=../common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common.sh"

# ---------------------------------------------------------------------------
# Unit tests for the jj backend in lib/vcs/jj.sh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Build a linear history on top of the setup_workspace state:
#   BASE_COMMIT -- first (one.txt) -- second (two.txt, bookmark "feature")
# with an empty working-copy commit on top. Sets BASE_COMMIT, FIRST_COMMIT and
# SECOND_COMMIT to the corresponding full commit IDs.
_fixture_linear_history() {
  BASE_COMMIT="$(get_full_commit_id '@-')"
  edit_file one.txt "one"
  jj -R "$REPO" commit -m "first" >/dev/null 2>&1
  edit_file two.txt "two"
  jj -R "$REPO" commit -m "second" >/dev/null 2>&1
  jj -R "$REPO" bookmark set feature -r '@-' >/dev/null 2>&1
  FIRST_COMMIT="$(get_full_commit_id 'feature-')"
  SECOND_COMMIT="$(get_full_commit_id 'feature')"
}

# Build two divergent branches off the current working-copy parent:
#   BASE_COMMIT -- side a (bookmark "sidea")
#              \- side b (bookmark "sideb")
# Both sides add the file named in $1 (default clash.txt) with different
# content, so merging them produces a conflict. Sets BASE_COMMIT.
_fixture_divergent_branches() {
  local file="${1:-clash.txt}"
  BASE_COMMIT="$(get_full_commit_id '@-')"
  jj -R "$REPO" new "$BASE_COMMIT" >/dev/null 2>&1
  edit_file "$file" "content a"
  jj -R "$REPO" commit -m "side a" >/dev/null 2>&1
  jj -R "$REPO" bookmark set sidea -r '@-' >/dev/null 2>&1
  jj -R "$REPO" new "$BASE_COMMIT" >/dev/null 2>&1
  edit_file "$file" "content b"
  jj -R "$REPO" commit -m "side b" >/dev/null 2>&1
  jj -R "$REPO" bookmark set sideb -r '@-' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Internal runners: TT_VERBOSE
# ---------------------------------------------------------------------------

test___jj__run__verbose_logs_command_and_preserves_stdout() {
  setup_workspace
  local plain_err_file="$_TEST_ROOT/plain-stderr.txt"
  local verbose_err_file="$_TEST_ROOT/verbose-stderr.txt"
  # TT_VERBOSE is pinned explicitly in both runs so an ambient value cannot
  # skew either side of the comparison.
  local plain_out verbose_out
  plain_out="$(TT_VERBOSE= _jj__get_commit_description "$REPO" main 2>"$plain_err_file")"
  verbose_out="$(TT_VERBOSE=1 _jj__get_commit_description "$REPO" main 2>"$verbose_err_file")"
  assert_eq "stdout is byte-identical with TT_VERBOSE=1" "$verbose_out" "$plain_out"
  assert_output_empty "no stderr chatter without TT_VERBOSE" \
    "$(cat "$plain_err_file")"
  local err
  err="$(cat "$verbose_err_file")"
  assert_contains "command line echoed to stderr" "$err" "+ jj -R"
  assert_contains "command arguments echoed to stderr" "$err" "log -r main"
}

# ---------------------------------------------------------------------------
# _jj__read_file_at_revision
# ---------------------------------------------------------------------------

test__jj__read_file_at_revision__reads_committed_file() {
  setup_workspace
  assert_eq "file content at main" \
    "$(_jj__read_file_at_revision "$REPO" main README.md)" "initial"
}

test__jj__read_file_at_revision__absent_file_fails() {
  setup_workspace
  local exit_code=0
  _jj__read_file_at_revision "$REPO" main missing.md >/dev/null || exit_code=$?
  assert_failure "absent file rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__get_operation_id
# ---------------------------------------------------------------------------

test__jj__get_operation_id__prints_nonempty_id() {
  setup_workspace
  local op_id exit_code=0
  op_id="$(_jj__get_operation_id "$REPO")" || exit_code=$?
  assert_success "operation ID read" "$exit_code"
  assert_output_not_empty "operation ID printed" "$op_id"
}

# ---------------------------------------------------------------------------
# _jj__restore_operation
# ---------------------------------------------------------------------------

test__jj__restore_operation__restores_previous_operation_state() {
  setup_workspace
  local before_op
  before_op="$(_jj__get_operation_id "$REPO")"
  edit_file victim.txt "x"
  jj -R "$REPO" commit -m "op restore victim" >/dev/null 2>&1

  local exit_code=0
  _jj__restore_operation "$REPO" "$before_op" || exit_code=$?
  assert_success "operation restored" "$exit_code"
  local descriptions
  descriptions="$(get_commit_message 'all()')"
  assert_not_contains "restored state predates the commit" \
    "$descriptions" "op restore victim"
}

test__jj__restore_operation__unknown_operation_fails() {
  setup_workspace
  local exit_code=0
  _jj__restore_operation "$REPO" "ffffffffffffffff" || exit_code=$?
  assert_failure "unknown operation rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__check_is_repository
# ---------------------------------------------------------------------------

test__jj__check_is_repository__repository_root() {
  setup_workspace
  local exit_code=0
  _jj__check_is_repository "$REPO" || exit_code=$?
  assert_success "repository root recognized" "$exit_code"
}

test__jj__check_is_repository__plain_directory() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  local exit_code=0
  _jj__check_is_repository "$dir" || exit_code=$?
  assert_failure "plain directory rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__get_backend_type / _jj__check_backend_supported
# ---------------------------------------------------------------------------

test__jj__get_backend_type__reads_store_type() {
  setup_workspace
  assert_eq "backend type of a git-backed repo" \
    "$(_jj__get_backend_type "$REPO")" "git"

  local plain
  plain="$(mktemp -d)"
  trap 'rm -rf "$plain"' RETURN
  local out='' exit_code=0
  out="$(_jj__get_backend_type "$plain")" || exit_code=$?
  assert_failure "unreadable store type rejected" "$exit_code"
  assert_output_empty "nothing printed on failure" "$out"
}

test__jj__check_backend_supported__accepts_git_rejects_others() {
  setup_workspace
  local exit_code=0
  _jj__check_backend_supported "$REPO" || exit_code=$?
  assert_success "git backend supported" "$exit_code"

  local fixture="$_TEST_ROOT/unsupported-backend"
  mkdir -p "$fixture/.jj/repo/store"
  printf 'simple' > "$fixture/.jj/repo/store/type"
  local err='' exit_code2=0
  err="$(_jj__check_backend_supported "$fixture" 2>&1)" || exit_code2=$?
  assert_failure "non-git backend rejected" "$exit_code2"
  assert_eq "exact contract message on stderr" \
    "$err" "Unsupported repository backend: simple"
}

# ---------------------------------------------------------------------------
# _jj__resolve_commit / _jj__resolve_change
# ---------------------------------------------------------------------------

test__jj__resolve_commit__prints_commit_id() {
  setup_workspace
  _fixture_linear_history
  assert_eq "commit ID of the bookmark" \
    "$(_jj__resolve_commit "$REPO" feature)" "$SECOND_COMMIT"
  assert_matches "full-length hex ID" \
    "$(_jj__resolve_commit "$REPO" feature)" '^[0-9a-f]{40}$'
  local exit_code=0
  _jj__resolve_commit "$REPO" no-such-bookmark >/dev/null || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

test__jj__resolve_change__prints_change_id() {
  setup_workspace
  _fixture_linear_history
  assert_matches "change ID shape" \
    "$(_jj__resolve_change "$REPO" feature)" '^[k-z]{32}$'
  local exit_code=0
  _jj__resolve_change "$REPO" no-such-bookmark >/dev/null || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__get_commit_timestamp
# ---------------------------------------------------------------------------

test__jj__get_commit_timestamp__prints_iso_utc() {
  setup_workspace
  assert_matches "ISO 8601 UTC timestamp" \
    "$(_jj__get_commit_timestamp "$REPO" main)" \
    '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
  local exit_code=0
  _jj__get_commit_timestamp "$REPO" no-such-bookmark >/dev/null || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__check_revision_exists
# ---------------------------------------------------------------------------

test__jj__check_revision_exists__existing_and_absent() {
  setup_workspace
  local exit_code=0
  _jj__check_revision_exists "$REPO" main || exit_code=$?
  assert_success "existing revision found" "$exit_code"
  exit_code=0
  _jj__check_revision_exists "$REPO" no-such-bookmark || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__check_commit_empty
# ---------------------------------------------------------------------------

test__jj__check_commit_empty__empty_and_nonempty() {
  setup_workspace
  local exit_code=0
  _jj__check_commit_empty "$REPO" '@' || exit_code=$?
  assert_success "fresh working-copy commit is empty" "$exit_code"

  exit_code=0
  _jj__check_commit_empty "$REPO" main || exit_code=$?
  assert_failure "commit with file changes is not empty" "$exit_code"

  edit_file pending.txt "pending"
  exit_code=0
  _jj__check_commit_empty "$REPO" '@' || exit_code=$?
  assert_failure "pending filesystem changes make @ non-empty" "$exit_code"

  exit_code=0
  _jj__check_commit_empty "$REPO" no-such-bookmark || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__check_has_conflicts / _jj__check_descendants_have_conflicts
# ---------------------------------------------------------------------------

test__jj__check_has_conflicts__single_revision() {
  setup_workspace
  local exit_code=0
  _jj__check_has_conflicts "$REPO" '@' || exit_code=$?
  assert_failure "clean revision has no conflicts" "$exit_code"

  _fixture_divergent_branches
  jj -R "$REPO" new sidea sideb >/dev/null 2>&1

  exit_code=0
  _jj__check_has_conflicts "$REPO" '@' || exit_code=$?
  assert_success "conflicted merge detected" "$exit_code"

  exit_code=0
  _jj__check_has_conflicts "$REPO" no-such-bookmark || exit_code=$?
  assert_failure "absent revision counts as conflict-free" "$exit_code"
}

test__jj__check_descendants_have_conflicts__detects_descendant_conflict() {
  setup_workspace
  _fixture_divergent_branches
  local exit_code=0
  _jj__check_descendants_have_conflicts "$REPO" "$BASE_COMMIT" || exit_code=$?
  assert_failure "no conflicts before the merge" "$exit_code"

  jj -R "$REPO" new sidea sideb >/dev/null 2>&1
  exit_code=0
  _jj__check_descendants_have_conflicts "$REPO" "$BASE_COMMIT" || exit_code=$?
  assert_success "conflicted descendant detected" "$exit_code"

  exit_code=0
  _jj__check_descendants_have_conflicts "$REPO" no-such-bookmark || exit_code=$?
  assert_failure "absent revision counts as conflict-free" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__check_is_ancestor
# ---------------------------------------------------------------------------

test__jj__check_is_ancestor__direction_and_absent() {
  setup_workspace
  _fixture_linear_history
  local exit_code=0
  _jj__check_is_ancestor "$REPO" "$BASE_COMMIT" feature || exit_code=$?
  assert_success "base is an ancestor of the tip" "$exit_code"
  exit_code=0
  _jj__check_is_ancestor "$REPO" feature "$BASE_COMMIT" || exit_code=$?
  assert_failure "tip is not an ancestor of the base" "$exit_code"
  exit_code=0
  _jj__check_is_ancestor "$REPO" no-such-bookmark feature || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__find_fork_point_commit
# ---------------------------------------------------------------------------

test__jj__find_fork_point_commit__finds_divergence_point() {
  setup_workspace
  _fixture_divergent_branches
  assert_eq "fork point of the two sides is their base" \
    "$(_jj__find_fork_point_commit "$REPO" sidea sideb)" "$BASE_COMMIT"
  local exit_code=0
  _jj__find_fork_point_commit "$REPO" sidea no-such-bookmark >/dev/null || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__find_nearest_bookmark
# ---------------------------------------------------------------------------

test__jj__find_nearest_bookmark__closest_bookmarked_ancestor() {
  setup_workspace
  _fixture_linear_history
  assert_eq "closest bookmarked ancestor of @" \
    "$(_jj__find_nearest_bookmark "$REPO" '@')" "feature"

  local out='' exit_code=0
  out="$(_jj__find_nearest_bookmark "$REPO" 'root()')" || exit_code=$?
  assert_failure "no bookmarked ancestor rejected" "$exit_code"
  assert_output_empty "nothing printed without a bookmarked ancestor" "$out"
}

# ---------------------------------------------------------------------------
# _jj__list_commits_in_range / _jj__count_commits_in_range
# ---------------------------------------------------------------------------

test__jj__list_commits_in_range__oldest_first() {
  setup_workspace
  _fixture_linear_history
  local expected
  expected="$(printf '%s\n%s' "$FIRST_COMMIT" "$SECOND_COMMIT")"
  assert_eq "range commits listed oldest first" \
    "$(_jj__list_commits_in_range "$REPO" "$BASE_COMMIT" feature)" "$expected"
  local exit_code=0
  _jj__list_commits_in_range "$REPO" "$BASE_COMMIT" no-such-bookmark >/dev/null || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

test__jj__count_commits_in_range__counts_and_tolerates_errors() {
  setup_workspace
  _fixture_linear_history
  assert_eq "two commits in the range" \
    "$(_jj__count_commits_in_range "$REPO" "$BASE_COMMIT" feature)" "2"
  assert_eq "empty range counts zero" \
    "$(_jj__count_commits_in_range "$REPO" feature feature)" "0"
  assert_eq "unresolvable range counts zero" \
    "$(_jj__count_commits_in_range "$REPO" "$BASE_COMMIT" no-such-bookmark)" "0"
}

# ---------------------------------------------------------------------------
# _jj__list_range_root_commits
# ---------------------------------------------------------------------------

test__jj__list_range_root_commits__prints_range_roots() {
  setup_workspace
  _fixture_linear_history
  assert_eq "the sole root of the linear range" \
    "$(_jj__list_range_root_commits "$REPO" "$BASE_COMMIT" feature)" "$FIRST_COMMIT"
  local exit_code=0
  _jj__list_range_root_commits "$REPO" "$BASE_COMMIT" no-such-bookmark >/dev/null || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__check_range_covered
# ---------------------------------------------------------------------------

test__jj__check_range_covered__full_and_partial_cover() {
  setup_workspace
  _fixture_linear_history
  local exit_code=0
  _jj__check_range_covered "$REPO" "$BASE_COMMIT" feature "$BASE_COMMIT" feature || exit_code=$?
  assert_success "identical cover range covers" "$exit_code"

  exit_code=0
  _jj__check_range_covered "$REPO" "$BASE_COMMIT" feature "$BASE_COMMIT" "$FIRST_COMMIT" || exit_code=$?
  assert_failure "partial cover range does not cover" "$exit_code"

  exit_code=0
  _jj__check_range_covered "$REPO" "$BASE_COMMIT" "$FIRST_COMMIT" \
    "$BASE_COMMIT" "$FIRST_COMMIT" "$FIRST_COMMIT" feature || exit_code=$?
  assert_success "union of cover pairs covers" "$exit_code"

  exit_code=0
  _jj__check_range_covered "$REPO" "$BASE_COMMIT" feature || exit_code=$?
  assert_failure "missing cover pairs rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__format_revision_range
# ---------------------------------------------------------------------------

test__jj__format_revision_range__native_and_git() {
  setup_workspace
  _fixture_linear_history
  assert_eq "native format echoes the symbols" \
    "$(_jj__format_revision_range "$REPO" native main feature)" "main..feature"
  assert_eq "git format resolves both endpoints" \
    "$(_jj__format_revision_range "$REPO" git "$BASE_COMMIT" feature)" \
    "${BASE_COMMIT}..${SECOND_COMMIT}"
  local exit_code=0
  _jj__format_revision_range "$REPO" git main no-such-bookmark >/dev/null || exit_code=$?
  assert_failure "git format with an absent endpoint rejected" "$exit_code"
  exit_code=0
  _jj__format_revision_range "$REPO" unknown main feature >/dev/null || exit_code=$?
  assert_failure "unknown format rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__find_file_introduction
# ---------------------------------------------------------------------------

test__jj__find_file_introduction__unique_and_ambiguous() {
  setup_workspace
  _fixture_linear_history
  assert_eq "commit that introduced one.txt" \
    "$(_jj__find_file_introduction "$REPO" one.txt feature '@')" "$FIRST_COMMIT"

  local out='' exit_code=0
  out="$(_jj__find_file_introduction "$REPO" not-tracked.txt feature '@')" || exit_code=$?
  assert_failure "file with no introduction rejected" "$exit_code"
  assert_output_empty "nothing printed without a match" "$out"
}

test__jj__find_file_introduction__non_unique_introduction_fails() {
  setup_workspace
  _fixture_divergent_branches dup.txt
  local out='' exit_code=0
  out="$(_jj__find_file_introduction "$REPO" dup.txt sidea sideb)" || exit_code=$?
  assert_failure "two independent introductions rejected" "$exit_code"
  assert_output_empty "nothing printed on ambiguity" "$out"
}

# ---------------------------------------------------------------------------
# _jj__list_file_waypoints
# ---------------------------------------------------------------------------

test__jj__list_file_waypoints__target_and_marker_commits() {
  setup_workspace
  local base
  base="$(get_full_commit_id '@-')"
  edit_file target.txt "t"
  jj -R "$REPO" commit -m "target change" >/dev/null 2>&1
  local target_commit
  target_commit="$(get_full_commit_id '@-')"
  edit_file marker.txt "m"
  jj -R "$REPO" commit -m "marker change" >/dev/null 2>&1
  local marker_commit
  marker_commit="$(get_full_commit_id '@-')"

  local waypoints
  waypoints="$(_jj__list_file_waypoints "$REPO" "$base" '@' '@' target.txt marker.txt)"
  assert_line_count "one waypoint per touching commit" "$waypoints" 2
  assert_eq "first waypoint is the target change" \
    "$(printf '%s\n' "$waypoints" | sed -n '1p' | cut -f1)" "$target_commit"
  assert_eq "target-changed flag set on the target waypoint" \
    "$(printf '%s\n' "$waypoints" | sed -n '1p' | cut -f4)" "1"
  assert_eq "second waypoint is the marker change" \
    "$(printf '%s\n' "$waypoints" | sed -n '2p' | cut -f1)" "$marker_commit"
  assert_eq "target-changed flag clear on the marker waypoint" \
    "$(printf '%s\n' "$waypoints" | sed -n '2p' | cut -f4)" "0"
  assert_eq "parent recorded for the target waypoint" \
    "$(printf '%s\n' "$waypoints" | sed -n '1p' | cut -f2)" "$base"

  local exit_code=0
  _jj__list_file_waypoints "$REPO" no-such-bookmark '@' '@' target.txt marker.txt \
    >/dev/null || exit_code=$?
  assert_failure "absent boundary rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__sort_commits_by_ancestry
# ---------------------------------------------------------------------------

test__jj__sort_commits_by_ancestry__orders_oldest_first() {
  setup_workspace
  _fixture_linear_history
  local expected
  expected="$(printf '%s\n%s' "$FIRST_COMMIT" "$SECOND_COMMIT")"
  assert_eq "ids re-ordered oldest first" \
    "$(_jj__sort_commits_by_ancestry "$REPO" "$BASE_COMMIT" feature feature \
      "$SECOND_COMMIT" "$FIRST_COMMIT")" "$expected"

  local out='' exit_code=0
  out="$(_jj__sort_commits_by_ancestry "$REPO" "$BASE_COMMIT" feature feature)" || exit_code=$?
  assert_success "empty id list succeeds" "$exit_code"
  assert_output_empty "empty id list prints nothing" "$out"

  exit_code=0
  _jj__sort_commits_by_ancestry "$REPO" no-such-bookmark feature feature \
    "$FIRST_COMMIT" >/dev/null || exit_code=$?
  assert_failure "absent boundary rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__set_bookmark
# ---------------------------------------------------------------------------

test__jj__set_bookmark__moves_bookmark_to_explicit_revision() {
  setup_workspace
  edit_file file.txt "content"
  jj -R "$REPO" commit -m "second" >/dev/null 2>&1

  local target
  target="$(jj -R "$REPO" log -r '@-' --no-graph -T 'commit_id')"

  local exit_code=0
  _jj__set_bookmark "$REPO" "marker" "$target" >/dev/null 2>&1 || exit_code=$?
  assert_success "bookmark set" "$exit_code"
  assert_eq "bookmark points at the explicit revision" \
    "$(jj -R "$REPO" log -r 'marker' --no-graph -T 'commit_id')" "$target"
}

# ---------------------------------------------------------------------------
# _jj__list_bookmark_names / _jj__list_bookmarks_at / _jj__check_bookmark_exists
# ---------------------------------------------------------------------------

test__jj__list_bookmark_names__lists_local_bookmarks() {
  setup_workspace
  _fixture_linear_history
  local names
  names="$(_jj__list_bookmark_names "$REPO")"
  assert_contains "main listed" "$names" "main"
  assert_contains "feature listed" "$names" "feature"

  local plain exit_code=0
  plain="$(mktemp -d)"
  trap 'rm -rf "$plain"' RETURN
  _jj__list_bookmark_names "$plain" >/dev/null || exit_code=$?
  assert_failure "non-repository rejected" "$exit_code"
}

test__jj__list_bookmarks_at__names_at_revision() {
  setup_workspace
  _fixture_linear_history
  assert_contains "bookmark at its own commit" \
    "$(_jj__list_bookmarks_at "$REPO" "$SECOND_COMMIT")" "feature"

  local out='' exit_code=0
  out="$(_jj__list_bookmarks_at "$REPO" '@')" || exit_code=$?
  assert_success "revision without bookmarks succeeds" "$exit_code"
  assert_output_empty "no names printed without bookmarks" "$out"

  exit_code=0
  _jj__list_bookmarks_at "$REPO" no-such-bookmark >/dev/null || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

test__jj__check_bookmark_exists__present_and_absent() {
  setup_workspace
  local exit_code=0
  _jj__check_bookmark_exists "$REPO" main || exit_code=$?
  assert_success "existing bookmark found" "$exit_code"
  exit_code=0
  _jj__check_bookmark_exists "$REPO" no-such-bookmark || exit_code=$?
  assert_failure "absent bookmark rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__rename_bookmark / _jj__delete_bookmark
# ---------------------------------------------------------------------------

test__jj__rename_bookmark__renames_and_rejects_absent() {
  setup_workspace
  _fixture_linear_history
  local exit_code=0
  _jj__rename_bookmark "$REPO" feature renamed || exit_code=$?
  assert_success "bookmark renamed" "$exit_code"
  exit_code=0
  _jj__check_bookmark_exists "$REPO" renamed || exit_code=$?
  assert_success "new name exists" "$exit_code"
  exit_code=0
  _jj__check_bookmark_exists "$REPO" feature || exit_code=$?
  assert_failure "old name gone" "$exit_code"

  exit_code=0
  _jj__rename_bookmark "$REPO" no-such-bookmark other || exit_code=$?
  assert_failure "absent bookmark rejected" "$exit_code"
}

test__jj__delete_bookmark__deletes_and_rejects_absent() {
  setup_workspace
  _fixture_linear_history
  local exit_code=0
  _jj__delete_bookmark "$REPO" feature || exit_code=$?
  assert_success "bookmark deleted" "$exit_code"
  exit_code=0
  _jj__check_bookmark_exists "$REPO" feature || exit_code=$?
  assert_failure "deleted bookmark gone" "$exit_code"

  exit_code=0
  _jj__delete_bookmark "$REPO" no-such-bookmark || exit_code=$?
  assert_failure "absent bookmark rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__create_worktree / _jj__get_worktree_revision
# ---------------------------------------------------------------------------

test__jj__create_worktree__adds_workspace_on_revision() {
  setup_workspace
  _fixture_linear_history
  local wt_path
  wt_path="$(dirname "$REPO")/wt-a"

  local exit_code=0
  _jj__create_worktree "$REPO" wt-a "$wt_path" feature || exit_code=$?
  assert_success "worktree created" "$exit_code"
  assert_file_exists "worktree files materialized" "$wt_path/two.txt"
  assert_contains "workspace registered" "$(_jj__list_worktrees "$REPO")" "wt-a"

  local wt_rev
  wt_rev="$(_jj__get_worktree_revision "$REPO" wt-a)"
  assert_output_not_empty "worktree revision resolved" "$wt_rev"
  assert_eq "worktree working copy sits on the requested revision" \
    "$(get_full_commit_id "${wt_rev}-")" "$SECOND_COMMIT"

  exit_code=0
  _jj__create_worktree "$REPO" wt-a "$(dirname "$REPO")/wt-b" feature || exit_code=$?
  assert_failure "duplicate workspace name rejected" "$exit_code"

  exit_code=0
  _jj__get_worktree_revision "$REPO" no-such-workspace >/dev/null || exit_code=$?
  assert_failure "unknown workspace name rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__check_file_exists_at_revision / _jj__list_files_at_*
# ---------------------------------------------------------------------------

test__jj__check_file_exists_at_revision__present_and_absent() {
  setup_workspace
  local exit_code=0
  _jj__check_file_exists_at_revision "$REPO" main README.md || exit_code=$?
  assert_success "existing file found" "$exit_code"
  exit_code=0
  _jj__check_file_exists_at_revision "$REPO" main missing.md || exit_code=$?
  assert_failure "absent file rejected" "$exit_code"
}

test__jj__list_files_at_revision__lists_and_scopes() {
  setup_workspace
  edit_file sub/inner.txt "s"
  jj -R "$REPO" commit -m "sub file" >/dev/null 2>&1

  local files
  files="$(_jj__list_files_at_revision "$REPO" '@-')"
  assert_contains "root file listed" "$files" "README.md"
  assert_contains "nested file listed repo-relative" "$files" "sub/inner.txt"

  local scoped
  scoped="$(_jj__list_files_at_revision "$REPO" '@-' sub)"
  assert_contains "prefix keeps matching files" "$scoped" "sub/inner.txt"
  assert_not_contains "prefix drops other files" "$scoped" "README.md"

  local exit_code=0
  _jj__list_files_at_revision "$REPO" no-such-bookmark >/dev/null || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

test__jj__list_files_at_operation__lists_at_operation() {
  setup_workspace
  local op
  op="$(_jj__get_operation_id "$REPO")"
  assert_contains "file listed at the current operation" \
    "$(_jj__list_files_at_operation "$REPO" "$op" main)" "README.md"
  local exit_code=0
  _jj__list_files_at_operation "$REPO" "ffffffffffffffff" main >/dev/null || exit_code=$?
  assert_failure "unknown operation rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__get_file_diff / _jj__show_diff
# ---------------------------------------------------------------------------

test__jj__get_file_diff__single_file_git_diff() {
  setup_workspace
  _fixture_linear_history
  local diff
  diff="$(_jj__get_file_diff "$REPO" feature two.txt)"
  assert_contains "git-format header present" "$diff" "diff --git"
  assert_contains "added content present" "$diff" "+two"
  assert_output_empty "untouched file yields no diff" \
    "$(_jj__get_file_diff "$REPO" feature one.txt)"
  local exit_code=0
  _jj__get_file_diff "$REPO" no-such-bookmark two.txt >/dev/null || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

test__jj__show_diff__range_diff_with_exclusions() {
  setup_workspace
  _fixture_linear_history
  edit_file sub/inner.txt "s"
  jj -R "$REPO" commit -m "sub file" >/dev/null 2>&1
  jj -R "$REPO" bookmark set feature -r '@-' >/dev/null 2>&1

  local full
  full="$(_jj__show_diff "$REPO" "$BASE_COMMIT" feature)"
  assert_contains "first file in the diff" "$full" "one.txt"
  assert_contains "second file in the diff" "$full" "two.txt"
  assert_contains "nested file in the diff" "$full" "sub/inner.txt"

  local filtered
  filtered="$(_jj__show_diff "$REPO" "$BASE_COMMIT" feature file two.txt dir sub)"
  assert_contains "unexcluded file kept" "$filtered" "one.txt"
  assert_not_contains "excluded file dropped" "$filtered" "two.txt"
  assert_not_contains "excluded directory dropped" "$filtered" "sub/inner.txt"

  local exit_code=0
  _jj__show_diff "$REPO" "$BASE_COMMIT" no-such-bookmark >/dev/null || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__check_working_copy_clean
# ---------------------------------------------------------------------------

test__jj__check_working_copy_clean__clean_working_copy() {
  setup_workspace
  local exit_code=0
  _jj__check_working_copy_clean "$REPO" || exit_code=$?
  assert_success "clean working copy detected" "$exit_code"
}

test__jj__check_working_copy_clean__dirty_working_copy() {
  setup_workspace
  edit_file dirty.txt "pending changes"
  local exit_code=0
  _jj__check_working_copy_clean "$REPO" || exit_code=$?
  assert_failure "dirty working copy detected" "$exit_code"
}

run_tests "tt lib/vcs/jj (unit)"
