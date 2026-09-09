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
# Internal runners: TT_LOG
#
# TT_LOG=info narrates the mutations tt performs on the repository; verbose
# additionally narrates reads and internal plumbing. In every case TT_LOG is
# pinned explicitly so an ambient value cannot skew a comparison.
# ---------------------------------------------------------------------------

test___jj__read__is_silent_at_info_and_traced_at_verbose() {
  setup_workspace
  local off_err="$_TEST_ROOT/read-off.txt"
  local info_err="$_TEST_ROOT/read-info.txt"
  local verbose_err="$_TEST_ROOT/read-verbose.txt"
  local off_out info_out verbose_out
  off_out="$(TT_LOG= _jj__get_commit_description "$REPO" main 2>"$off_err")"
  info_out="$(TT_LOG=info _jj__get_commit_description "$REPO" main 2>"$info_err")"
  verbose_out="$(TT_LOG=verbose _jj__get_commit_description "$REPO" main 2>"$verbose_err")"

  assert_eq "stdout is byte-identical at info" "$info_out" "$off_out"
  assert_eq "stdout is byte-identical at verbose" "$verbose_out" "$off_out"
  assert_output_empty "no stderr chatter when logging is off" "$(cat "$off_err")"
  assert_output_empty "a read is not narrated at info" "$(cat "$info_err")"

  local err
  err="$(cat "$verbose_err")"
  assert_contains "command line echoed to stderr at verbose" "$err" "+ jj -R"
  assert_contains "command arguments echoed to stderr" "$err" "log -r main"
}

test___jj__write__is_traced_at_info() {
  setup_workspace
  local off_err="$_TEST_ROOT/write-off.txt"
  local info_err="$_TEST_ROOT/write-info.txt"
  jj -R "$REPO" bookmark set trace-target -r main >/dev/null 2>&1

  TT_LOG= _jj__set_bookmark "$REPO" trace-target main 2>"$off_err"
  assert_output_empty "a mutation is silent when logging is off" "$(cat "$off_err")"

  TT_LOG=info _jj__set_bookmark "$REPO" trace-target main 2>"$info_err"
  local err
  err="$(cat "$info_err")"
  assert_contains "mutation command line narrated at info" "$err" "+ jj -R"
  assert_contains "mutation arguments narrated at info" "$err" "bookmark set trace-target"
}

test___jj__write__forwards_the_commands_own_output_at_info() {
  # At info the point is to narrate what happened to the repository, so the
  # mutation's own reporting is forwarded rather than discarded.
  setup_workspace
  local err_file="$_TEST_ROOT/write-forward.txt"
  jj -R "$REPO" bookmark set doomed -r main >/dev/null 2>&1
  TT_LOG=info _jj__delete_bookmark "$REPO" doomed 2>"$err_file"
  assert_contains "jj's own reporting reaches stderr" "$(cat "$err_file")" "Deleted"
}

test___jj__write__never_leaks_output_to_stdout() {
  setup_workspace
  jj -R "$REPO" bookmark set quiet-target -r main >/dev/null 2>&1
  local level
  for level in '' info verbose; do
    local out
    out="$(TT_LOG="$level" _jj__set_bookmark "$REPO" quiet-target main 2>/dev/null)"
    assert_output_empty "mutation stdout suppressed at TT_LOG=${level:-off}" "$out"
  done
}

test___jj__write_internal__is_traced_only_at_verbose() {
  # The deliberate working-copy snapshot is private mechanism, not an effect a
  # user would recognize, so it must not appear at info even though it mutates.
  setup_workspace
  local info_err="$_TEST_ROOT/internal-info.txt"
  local verbose_err="$_TEST_ROOT/internal-verbose.txt"
  TT_LOG=info _jj__snapshot_worktree "$REPO" 2>"$info_err"
  TT_LOG=verbose _jj__snapshot_worktree "$REPO" 2>"$verbose_err"
  assert_output_empty "internal mutation not narrated at info" "$(cat "$info_err")"
  assert_contains "internal mutation narrated at verbose" \
    "$(cat "$verbose_err")" "+ jj -R"
}

test__jj__operations_that_change_directory__accept_a_relative_root() {
  # These operations run their jj invocation from inside the repository, and
  # name it with $PWD rather than the caller's argument. jj resolves -R after
  # the working directory changes, so passing the argument through would make a
  # relative root resolve against itself (cd foo, then -R foo means foo/foo);
  # $PWD is absolute by construction once the cd has happened.
  setup_workspace
  local parent relative
  parent="$(dirname "$REPO")"
  relative="$(basename "$REPO")"

  local code=0
  ( cd "$parent" && _jj__get_operation_id "$relative" ) >/dev/null 2>/dev/null || code=$?
  assert_success "_jj__get_operation_id accepts a relative root" "$code"

  code=0
  ( cd "$parent" && _jj__list_changed_files "$relative" '@' ) >/dev/null 2>/dev/null || code=$?
  assert_success "_jj__list_changed_files accepts a relative root" "$code"

  local listed
  listed="$(cd "$parent" && _jj__list_files_at_revision "$relative" '@' 2>/dev/null)"
  assert_not_contains "a relative root still yields repo-relative paths" "$listed" "../"
  assert_eq "and the same listing as an absolute root" \
    "$listed" "$(_jj__list_files_at_revision "$REPO" '@')"
}

test__jj__list_files_at_revision__paths_do_not_depend_on_the_callers_directory() {
  # The reason most of the directory-changing call sites exist: jj reports
  # paths relative to the working directory, so without the cd this output
  # would depend on where the user invoked tt from.
  setup_workspace
  local from_root from_elsewhere
  from_root="$(cd "$REPO" && _jj__list_files_at_revision "$REPO" '@')"
  from_elsewhere="$(cd "$_TEST_ROOT" && _jj__list_files_at_revision "$REPO" '@')"
  assert_eq "paths do not depend on the caller's directory" \
    "$from_elsewhere" "$from_root"
  assert_not_contains "paths are not relativized outward" "$from_elsewhere" "../"
}

test__jj__list_files_at_revision__prefix_filters_the_listing() {
  # The prefix and no-prefix forms share one invocation via an optional
  # fileset argument; both paths need covering.
  setup_workspace
  local all filtered
  all="$(_jj__list_files_at_revision "$REPO" '@')"
  filtered="$(_jj__list_files_at_revision "$REPO" '@' "$TT_METADATA_DIR")"
  assert_contains "unfiltered listing includes a metadata file" "$all" "$TT_METADATA_DIR/"
  assert_contains "filtered listing includes the metadata file" "$filtered" "$TT_METADATA_DIR/"
  assert_not_contains "filtered listing excludes the repo-root task symlink" \
    "$(printf '%s\n' "$filtered")" "$(printf '%s\n' "$TT_TASK_SYMLINK_FILENAME")"
}

test___jj__read__preserves_exit_status_at_every_level() {
  setup_workspace
  local level
  for level in '' info verbose; do
    local code=0
    TT_LOG="$level" _jj__resolve_commit "$REPO" no-such-revision \
      >/dev/null 2>/dev/null || code=$?
    assert_failure "failure reported at TT_LOG=${level:-off}" "$code"
  done
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
# _jj__find_prefix_introduction
# ---------------------------------------------------------------------------

test__jj__find_prefix_introduction__matches_directory_and_ignores_heads() {
  setup_workspace
  BASE_COMMIT="$(get_full_commit_id '@-')"
  edit_file nested/dir/one.txt "one"
  jj -R "$REPO" commit -m "introduce dir" >/dev/null 2>&1
  local introduction
  introduction="$(get_full_commit_id '@-')"
  edit_file nested/dir/two.txt "two"
  jj -R "$REPO" commit -m "extend dir" >/dev/null 2>&1
  jj -R "$REPO" bookmark set feature -r '@-' >/dev/null 2>&1
  # A branch forked from the introducing commit: the introduction must be
  # found without naming any head, so that both lines are anchored by it.
  jj -R "$REPO" new "$introduction" >/dev/null 2>&1
  edit_file nested/dir/three.txt "three"
  jj -R "$REPO" commit -m "other line" >/dev/null 2>&1
  jj -R "$REPO" bookmark set other -r '@-' >/dev/null 2>&1

  assert_eq "commit that introduced the directory" \
    "$(_jj__find_prefix_introduction "$REPO" nested/dir)" "$introduction"
  assert_eq "a file prefix resolves too" \
    "$(_jj__find_prefix_introduction "$REPO" nested/dir/one.txt)" "$introduction"

  local out='' exit_code=0
  out="$(_jj__find_prefix_introduction "$REPO" not-tracked)" || exit_code=$?
  assert_failure "prefix with no introduction rejected" "$exit_code"
  assert_output_empty "nothing printed without a match" "$out"
}

test__jj__find_prefix_introduction__non_unique_introduction_fails() {
  setup_workspace
  _fixture_divergent_branches shared/dup.txt
  local out='' exit_code=0
  out="$(_jj__find_prefix_introduction "$REPO" shared)" || exit_code=$?
  assert_failure "two independent introductions rejected" "$exit_code"
  assert_output_empty "nothing printed on ambiguity" "$out"
}

# ---------------------------------------------------------------------------
# _jj__list_descendant_changes
# ---------------------------------------------------------------------------

test__jj__list_descendant_changes__includes_self_and_every_branch() {
  setup_workspace
  local base
  base="$(get_full_commit_id '@-')"
  edit_file one.txt "one"
  jj -R "$REPO" commit -m "fork point" >/dev/null 2>&1
  local fork
  fork="$(get_full_commit_id '@-')"
  edit_file two.txt "two"
  jj -R "$REPO" commit -m "line a" >/dev/null 2>&1
  jj -R "$REPO" bookmark set linea -r '@-' >/dev/null 2>&1
  jj -R "$REPO" new "$fork" >/dev/null 2>&1
  edit_file three.txt "three"
  jj -R "$REPO" commit -m "line b" >/dev/null 2>&1
  jj -R "$REPO" bookmark set lineb -r '@-' >/dev/null 2>&1

  local changes
  changes="$(_jj__list_descendant_changes "$REPO" "$fork")"
  assert_eq "the anchor itself comes first" \
    "$(printf '%s\n' "$changes" | head -1)" "$(_jj__resolve_change "$REPO" "$fork")"
  assert_contains "descendant on one line listed" \
    "$changes" "$(_jj__resolve_change "$REPO" linea)"
  assert_contains "descendant on the other line listed" \
    "$changes" "$(_jj__resolve_change "$REPO" lineb)"
  assert_not_contains "ancestors are not listed" \
    "$changes" "$(_jj__resolve_change "$REPO" "$base")"
}

# ---------------------------------------------------------------------------
# _jj__read_symlink_at_revision
# ---------------------------------------------------------------------------

test__jj__read_symlink_at_revision__reads_target_and_rejects_non_symlinks() {
  setup_workspace
  mkdir -p "$REPO/nested"
  edit_file "$REPO/nested/target.txt" "content"
  ln -s "nested/target.txt" "$REPO/LINK.md"
  jj -R "$REPO" commit -m "add symlink" >/dev/null 2>&1

  assert_eq "symlink target read from the revision" \
    "$(_jj__read_symlink_at_revision "$REPO" '@-' LINK.md)" "nested/target.txt"

  local exit_code=0
  _jj__read_symlink_at_revision "$REPO" '@-' nested/target.txt >/dev/null || exit_code=$?
  assert_failure "regular file rejected" "$exit_code"
  exit_code=0
  _jj__read_symlink_at_revision "$REPO" '@-' missing.md >/dev/null || exit_code=$?
  assert_failure "absent path rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__refresh_worktree
# ---------------------------------------------------------------------------

test__jj__refresh_worktree__recovers_after_a_bare_rewrite_of_the_working_copy() {
  setup_workspace
  edit_file kept.txt "original"
  jj -R "$REPO" commit -m "base" >/dev/null 2>&1
  local base
  base="$(get_full_commit_id '@-')"
  edit_file kept.txt "rewritten"
  edit_file added.txt "added"
  jj -R "$REPO" commit -m "source" >/dev/null 2>&1
  jj -R "$REPO" bookmark set src -r '@-' >/dev/null 2>&1
  jj -R "$REPO" new "$base" >/dev/null 2>&1

  # Bare rewrite of the working-copy commit: the graph moves, the files on
  # disk do not, and every command that loads the working copy now fails.
  _jj__restore_tree "$REPO" src '@'
  assert_eq "on-disk file still holds the pre-rewrite content" \
    "$(cat "$REPO/kept.txt")" "original"
  local stale_exit=0
  jj -R "$REPO" status >/dev/null 2>&1 || stale_exit=$?
  assert_failure "working copy is stale before the refresh" "$stale_exit"

  local exit_code=0
  _jj__refresh_worktree "$REPO" || exit_code=$?
  assert_success "worktree refreshed" "$exit_code"
  assert_eq "on-disk file caught up with the rewrite" \
    "$(cat "$REPO/kept.txt")" "rewritten"
  assert_file_exists "file added by the rewrite is on disk" "$REPO/added.txt"
  local ok_exit=0
  jj -R "$REPO" status >/dev/null 2>&1 || ok_exit=$?
  assert_success "working copy usable again" "$ok_exit"

  exit_code=0
  _jj__refresh_worktree "$REPO" || exit_code=$?
  assert_success "refreshing an up-to-date worktree is harmless" "$exit_code"
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

test__jj__set_bookmark__backwards_move_requires_flag() {
  setup_workspace
  edit_file file.txt "content"
  jj -R "$REPO" commit -m "second" >/dev/null 2>&1

  local older newer
  older="$(jj -R "$REPO" log -r '@--' --no-graph -T 'commit_id')"
  newer="$(jj -R "$REPO" log -r '@-' --no-graph -T 'commit_id')"

  _jj__set_bookmark "$REPO" "marker" "$newer" >/dev/null 2>&1

  # Without --allow-backwards, moving the bookmark to a non-descendant fails
  # and the bookmark stays put.
  local exit_code=0
  _jj__set_bookmark "$REPO" "marker" "$older" >/dev/null 2>&1 || exit_code=$?
  assert_failure "backwards move without flag rejected" "$exit_code"
  assert_eq "bookmark unmoved after rejected backwards move" \
    "$(jj -R "$REPO" log -r 'marker' --no-graph -T 'commit_id')" "$newer"

  # With --allow-backwards the same move succeeds.
  exit_code=0
  _jj__set_bookmark "$REPO" "marker" "$older" --allow-backwards >/dev/null 2>&1 \
    || exit_code=$?
  assert_success "backwards move with flag succeeds" "$exit_code"
  assert_eq "bookmark moved backwards to the older revision" \
    "$(jj -R "$REPO" log -r 'marker' --no-graph -T 'commit_id')" "$older"
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
# _jj__list_changed_files_in_range
# ---------------------------------------------------------------------------

test__jj__list_changed_files_in_range__reports_own_work_only() {
  setup_workspace
  local base
  base="$(get_full_commit_id '@-')"
  edit_file inherited.txt "inherited"
  jj -R "$REPO" commit -m "base work" >/dev/null 2>&1
  jj -R "$REPO" bookmark set parent -r '@-' >/dev/null 2>&1

  # The range's root introduces stub.txt; the commits above it add own.txt.
  edit_file stub.txt "stub"
  jj -R "$REPO" commit -m "branch creation" >/dev/null 2>&1
  edit_file own.txt "own"
  jj -R "$REPO" commit -m "branch work" >/dev/null 2>&1
  jj -R "$REPO" bookmark set child -r '@-' >/dev/null 2>&1

  local changed
  changed="$(_jj__list_changed_files_in_range "$REPO" parent child)"
  assert_contains "the range's own work is reported" "$changed" "own.txt"
  assert_not_contains "content inherited from the base is not reported" \
    "$changed" "inherited.txt"
  assert_not_contains "the range root's own paths are excluded" \
    "$changed" "stub.txt"

  local exit_code=0
  _jj__list_changed_files_in_range "$REPO" parent no-such-bookmark >/dev/null \
    || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
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

# ---------------------------------------------------------------------------
# Mutations (bare): _jj__commit_changeset
# ---------------------------------------------------------------------------

test__jj__commit_changeset__basic_commit_from_stage() {
  setup_workspace
  local parent
  parent="$(_jj__resolve_commit "$REPO" main)"
  local stage="$_TEST_ROOT/stage-basic"
  mkdir -p "$stage/sub"
  printf 'top\n' > "$stage/top.txt"
  printf 'nested\n' > "$stage/sub/nested.txt"

  local commit exit_code=0
  commit="$(_jj__commit_changeset "$REPO" main "bare change" "$stage")" || exit_code=$?
  assert_success "changeset committed" "$exit_code"
  assert_matches "full-length commit ID printed" "$commit" '^[0-9a-f]{40}$'
  assert_eq "parent is the requested revision" \
    "$(jj -R "$REPO" --ignore-working-copy log -r "$commit" --no-graph \
      -T 'parents.map(|p| p.commit_id()).join(" ")')" \
    "$parent"
  assert_eq "description recorded" \
    "$(_jj__get_commit_description "$REPO" "$commit")" "bare change"
  assert_eq "staged file present" \
    "$(_jj__read_file_at_revision "$REPO" "$commit" top.txt)" "top"
  assert_eq "nested staged file present" \
    "$(_jj__read_file_at_revision "$REPO" "$commit" sub/nested.txt)" "nested"
  assert_eq "parent tree carried over" \
    "$(_jj__read_file_at_revision "$REPO" "$commit" README.md)" "initial"
}

test__jj__commit_changeset__is_entirely_silent_at_info() {
  # A bare write is built from git plumbing plus a temporary-ref import hop.
  # None of that is an effect a user would recognize, and jj reports the
  # temporary ref's removal as "Abandoned 1 commits that are no longer
  # reachable" — alarming out of context. The whole sequence is therefore
  # verbose-only; what a user sees at info is the bookmark move that follows.
  setup_workspace
  local stage="$_TEST_ROOT/stage-info"
  mkdir -p "$stage"
  printf 'v\n' > "$stage/v.txt"
  local info_err="$_TEST_ROOT/changeset-info-err.txt"
  local commit
  commit="$(TT_LOG=info _jj__commit_changeset "$REPO" main "info run" "$stage" \
    2>"$info_err")"
  local err
  err="$(cat "$info_err")"
  assert_output_empty "bare write is silent at info" "$err"
  assert_eq "commit id still returned on stdout" "${#commit}" 40
}

test__jj__commit_changeset__traces_plumbing_at_verbose() {
  setup_workspace
  local stage="$_TEST_ROOT/stage-verbose"
  mkdir -p "$stage"
  printf 'v\n' > "$stage/v.txt"
  local plain_err="$_TEST_ROOT/plain-git-err.txt"
  local verbose_err="$_TEST_ROOT/verbose-git-err.txt"
  local plain_commit verbose_commit
  plain_commit="$(TT_LOG= _jj__commit_changeset "$REPO" main "quiet run" "$stage" \
    2>"$plain_err")"
  verbose_commit="$(TT_LOG=verbose _jj__commit_changeset "$REPO" main "verbose run" "$stage" \
    2>"$verbose_err")"
  assert_output_empty "no stderr chatter when logging is off" \
    "$(cat "$plain_err")"
  assert_contains "git plumbing narrated at verbose" \
    "$(cat "$verbose_err")" "+ git"
  assert_contains "the import hop narrated at verbose" \
    "$(cat "$verbose_err")" "+ jj"
  # Tracing must not disturb the operation's return value.
  assert_eq "commit id returned while tracing" "${#verbose_commit}" 40
  assert_eq "commit id returned when quiet" "${#plain_commit}" 40
}

test__jj__commit_changeset__dirty_working_copy_not_involved() {
  setup_workspace
  edit_file dirty.txt "un-snapshotted"
  local wc_before
  wc_before="$(_jj__resolve_commit "$REPO" '@')"
  local stage="$_TEST_ROOT/stage-dirty"
  mkdir -p "$stage"
  printf 'clean\n' > "$stage/clean.txt"

  local commit exit_code=0
  commit="$(_jj__commit_changeset "$REPO" main "no dirt" "$stage")" || exit_code=$?
  assert_success "changeset committed with a dirty working copy" "$exit_code"
  local ec=0
  _jj__check_file_exists_at_revision "$REPO" "$commit" dirty.txt || ec=$?
  assert_failure "dirty file not part of the new commit" "$ec"
  assert_file_exists "dirty file still on disk" "$REPO/dirty.txt"
  assert_eq "dirty file content untouched" \
    "$(cat "$REPO/dirty.txt")" "un-snapshotted"
  ec=0
  _jj__check_file_exists_at_revision "$REPO" '@' dirty.txt || ec=$?
  assert_failure "working copy still un-snapshotted" "$ec"
  assert_eq "@ did not move" "$(_jj__resolve_commit "$REPO" '@')" "$wc_before"
}

test__jj__commit_changeset__symlink_round_trip() {
  setup_workspace
  ln -s old-target existing-link
  ln -s doomed dead-link
  jj -R "$REPO" commit -m "links" >/dev/null 2>&1
  jj -R "$REPO" bookmark set main -r '@-' >/dev/null 2>&1

  local stage="$_TEST_ROOT/stage-links"
  mkdir -p "$stage"
  ln -s some/target "$stage/new-link"
  ln -s new-target "$stage/existing-link"

  local commit exit_code=0
  commit="$(_jj__commit_changeset "$REPO" main "link changes" "$stage" dead-link)" \
    || exit_code=$?
  assert_success "changeset committed" "$exit_code"

  assert_eq "created symlink has mode 120000" \
    "$(git --git-dir="$REPO/.git" ls-tree "$commit" -- new-link | cut -d' ' -f1)" \
    "120000"
  assert_eq "created symlink target" \
    "$(git --git-dir="$REPO/.git" cat-file blob "${commit}:new-link")" \
    "some/target"
  assert_eq "retargeted symlink has mode 120000" \
    "$(git --git-dir="$REPO/.git" ls-tree "$commit" -- existing-link | cut -d' ' -f1)" \
    "120000"
  assert_eq "retargeted symlink target" \
    "$(git --git-dir="$REPO/.git" cat-file blob "${commit}:existing-link")" \
    "new-target"
  local ec=0
  _jj__check_file_exists_at_revision "$REPO" "$commit" dead-link || ec=$?
  assert_failure "deleted symlink absent from the new commit" "$ec"
  assert_contains "symlink listed among tracked files" \
    "$(_jj__list_files_at_revision "$REPO" "$commit")" "new-link"
}

test__jj__commit_changeset__file_modes_preserved() {
  setup_workspace
  local stage="$_TEST_ROOT/stage-modes"
  mkdir -p "$stage"
  printf '#!/bin/sh\n' > "$stage/tool.sh"
  chmod +x "$stage/tool.sh"
  printf 'plain\n' > "$stage/plain.txt"

  local commit exit_code=0
  commit="$(_jj__commit_changeset "$REPO" main "modes" "$stage")" || exit_code=$?
  assert_success "changeset committed" "$exit_code"
  assert_eq "executable file keeps mode 100755" \
    "$(git --git-dir="$REPO/.git" ls-tree "$commit" -- tool.sh | cut -d' ' -f1)" \
    "100755"
  assert_eq "regular file keeps mode 100644" \
    "$(git --git-dir="$REPO/.git" ls-tree "$commit" -- plain.txt | cut -d' ' -f1)" \
    "100644"
}

test__jj__commit_changeset__deletions_before_overlay() {
  setup_workspace
  edit_file old.txt "old"
  edit_file prefix "file that becomes a directory"
  jj -R "$REPO" commit -m "victims" >/dev/null 2>&1
  jj -R "$REPO" bookmark set main -r '@-' >/dev/null 2>&1

  local stage="$_TEST_ROOT/stage-del"
  mkdir -p "$stage/prefix"
  printf 'inner\n' > "$stage/prefix/inner.txt"

  local commit exit_code=0
  commit="$(_jj__commit_changeset "$REPO" main "deletions" "$stage" old.txt prefix)" \
    || exit_code=$?
  assert_success "changeset committed" "$exit_code"
  local ec=0
  _jj__check_file_exists_at_revision "$REPO" "$commit" old.txt || ec=$?
  assert_failure "deleted path absent" "$ec"
  assert_eq "staged file beneath the deleted prefix present" \
    "$(_jj__read_file_at_revision "$REPO" "$commit" prefix/inner.txt)" "inner"
  assert_contains "prefix is now a directory entry, not the old file" \
    "$(git --git-dir="$REPO/.git" ls-tree "$commit" -- prefix)" "tree"
  assert_not_contains "old file gone from the listing" \
    "$(_jj__list_files_at_revision "$REPO" "$commit")" "old.txt"
}

test__jj__commit_changeset__identity_from_jj_config() {
  setup_workspace
  local expected_name expected_email
  expected_name="$(jj -R "$REPO" config get user.name 2>/dev/null)"
  expected_email="$(jj -R "$REPO" config get user.email 2>/dev/null)"
  local stage="$_TEST_ROOT/stage-id"
  mkdir -p "$stage"
  printf 'i\n' > "$stage/i.txt"

  local commit exit_code=0
  commit="$(GIT_AUTHOR_NAME="Decoy Author" GIT_AUTHOR_EMAIL="decoy@example.com" \
    GIT_COMMITTER_NAME="Decoy Committer" GIT_COMMITTER_EMAIL="decoy@example.com" \
    _jj__commit_changeset "$REPO" main "identity" "$stage")" || exit_code=$?
  assert_success "changeset committed" "$exit_code"
  assert_eq "author identity from jj config despite decoy env" \
    "$(jj -R "$REPO" --ignore-working-copy log -r "$commit" --no-graph \
      -T 'author.name() ++ " <" ++ author.email() ++ ">"')" \
    "$expected_name <$expected_email>"
  assert_eq "committer identity from jj config despite decoy env" \
    "$(jj -R "$REPO" --ignore-working-copy log -r "$commit" --no-graph \
      -T 'committer.name() ++ " <" ++ committer.email() ++ ">"')" \
    "$expected_name <$expected_email>"
}

test__jj__commit_changeset__leaves_no_trace() {
  setup_workspace
  local stage="$_TEST_ROOT/stage-trace"
  mkdir -p "$stage"
  printf 't\n' > "$stage/t.txt"
  local scratch_root="$_TEST_ROOT/scratch-root"
  mkdir -p "$scratch_root"

  local commit exit_code=0
  commit="$(TMPDIR="$scratch_root" \
    _jj__commit_changeset "$REPO" main "tidy" "$stage")" || exit_code=$?
  assert_success "changeset committed" "$exit_code"
  assert_not_contains "no temporary git ref survives" \
    "$(git --git-dir="$REPO/.git" for-each-ref)" "tt-tmp-"
  assert_not_contains "no stray jj bookmark survives" \
    "$(_jj__list_bookmark_names "$REPO")" "tt-tmp-"
  assert_output_empty "scratch directory removed" \
    "$(find "$scratch_root" -mindepth 1)"
  local ec=0
  _jj__check_revision_exists "$REPO" "$commit" || ec=$?
  assert_success "commit still resolvable after cleanup" "$ec"
}

test__jj__commit_changeset__non_git_store_rejected() {
  setup_workspace
  local fixture="$_TEST_ROOT/simple-backend"
  mkdir -p "$fixture/.jj/repo/store"
  printf 'simple' > "$fixture/.jj/repo/store/type"
  local stage="$_TEST_ROOT/stage-simple"
  mkdir -p "$stage"
  local out='' err_file="$_TEST_ROOT/simple-err.txt" exit_code=0
  out="$(_jj__commit_changeset "$fixture" main "nope" "$stage" 2>"$err_file")" \
    || exit_code=$?
  assert_failure "non-git backend rejected" "$exit_code"
  assert_eq "exact contract message on stderr" \
    "$(cat "$err_file")" "Unsupported repository backend: simple"
  assert_output_empty "nothing printed on failure" "$out"
}

test__jj__commit_changeset__invalid_inputs_fail_cleanly() {
  setup_workspace
  local stage="$_TEST_ROOT/stage-fail"
  mkdir -p "$stage"
  printf 'f\n' > "$stage/f.txt"

  local out='' exit_code=0
  out="$(_jj__commit_changeset "$REPO" no-such-bookmark "msg" "$stage" 2>/dev/null)" \
    || exit_code=$?
  assert_failure "absent parent revision rejected" "$exit_code"
  assert_output_empty "nothing printed on failure" "$out"

  exit_code=0
  out="$(_jj__commit_changeset "$REPO" main "msg" "$_TEST_ROOT/no-such-stage" 2>/dev/null)" \
    || exit_code=$?
  assert_failure "missing stage directory rejected" "$exit_code"
  assert_output_empty "nothing printed for a missing stage dir" "$out"

  assert_not_contains "no temporary ref left behind by failures" \
    "$(git --git-dir="$REPO/.git" for-each-ref)" "tt-tmp-"
}

test__jj__commit_changeset__secondary_workspace_repo() {
  setup_workspace
  _fixture_linear_history
  local wt_path
  wt_path="$(dirname "$REPO")/wt-bare"
  local exit_code=0
  _jj__create_worktree "$REPO" wt-bare "$wt_path" feature || exit_code=$?
  assert_success "worktree created" "$exit_code"
  assert_file_exists "secondary workspace has a repo pointer file" \
    "$wt_path/.jj/repo"

  local stage="$_TEST_ROOT/stage-ws"
  mkdir -p "$stage"
  printf 'ws\n' > "$stage/ws.txt"
  local commit
  exit_code=0
  commit="$(_jj__commit_changeset "$wt_path" feature "from workspace" "$stage")" \
    || exit_code=$?
  assert_success "changeset committed via secondary workspace root" "$exit_code"
  assert_eq "file content readable via the canonical repo" \
    "$(_jj__read_file_at_revision "$REPO" "$commit" ws.txt)" "ws"
}

test__jj__commit_changeset__other_workspace_untouched() {
  setup_workspace
  _fixture_linear_history
  local wt_path
  wt_path="$(dirname "$REPO")/wt-victim"
  _jj__create_worktree "$REPO" wt-victim "$wt_path" feature >/dev/null 2>&1

  printf 'pending\n' > "$wt_path/pending.txt"
  local wt_rev_before
  wt_rev_before="$(_jj__get_worktree_revision "$REPO" wt-victim)"

  local stage="$_TEST_ROOT/stage-victim"
  mkdir -p "$stage"
  printf 'x\n' > "$stage/x.txt"
  local commit exit_code=0
  commit="$(_jj__commit_changeset "$REPO" feature "onto feature" "$stage")" \
    || exit_code=$?
  assert_success "changeset committed" "$exit_code"

  assert_file_exists "worktree materialized file still on disk" "$wt_path/two.txt"
  assert_file_exists "worktree pending file still on disk" "$wt_path/pending.txt"
  assert_eq "worktree pending content untouched" \
    "$(cat "$wt_path/pending.txt")" "pending"
  assert_eq "worktree working-copy commit unchanged" \
    "$(_jj__get_worktree_revision "$REPO" wt-victim)" "$wt_rev_before"
  local ec=0
  _jj__check_file_exists_at_revision "$REPO" 'wt-victim@' pending.txt || ec=$?
  assert_failure "worktree changes remain un-snapshotted" "$ec"
}

# ---------------------------------------------------------------------------
# _jj__create_merge_commit
# ---------------------------------------------------------------------------

test__jj__create_merge_commit__two_parents() {
  setup_workspace
  local base
  base="$(get_full_commit_id '@-')"
  jj -R "$REPO" new "$base" >/dev/null 2>&1
  edit_file left.txt "left"
  jj -R "$REPO" commit -m "left side" >/dev/null 2>&1
  jj -R "$REPO" bookmark set left -r '@-' >/dev/null 2>&1
  jj -R "$REPO" new "$base" >/dev/null 2>&1
  edit_file right.txt "right"
  jj -R "$REPO" commit -m "right side" >/dev/null 2>&1
  jj -R "$REPO" bookmark set right -r '@-' >/dev/null 2>&1
  local left_commit right_commit
  left_commit="$(get_full_commit_id left)"
  right_commit="$(get_full_commit_id right)"

  local commit exit_code=0
  commit="$(_jj__create_merge_commit "$REPO" "merge the sides" left right)" \
    || exit_code=$?
  assert_success "merge created" "$exit_code"
  assert_matches "full-length commit ID printed" "$commit" '^[0-9a-f]{40}$'
  assert_eq "parents are exactly the two given revisions" \
    "$(jj -R "$REPO" --ignore-working-copy log -r "$commit" --no-graph \
      -T 'parents.map(|p| p.commit_id()).join(" ")')" \
    "$left_commit $right_commit"
  assert_eq "description recorded" \
    "$(_jj__get_commit_description "$REPO" "$commit")" "merge the sides"
  local ec=0
  _jj__check_commit_empty "$REPO" "$commit" || ec=$?
  assert_success "empty diff against the auto-merged tree" "$ec"
  assert_eq "both sides' content in the merged tree" \
    "$(_jj__read_file_at_revision "$REPO" "$commit" left.txt)" "left"

  # A second merge of the same parents with a different description must
  # resolve to its own commit, proving the description narrows the lookup.
  local commit2
  exit_code=0
  commit2="$(_jj__create_merge_commit "$REPO" $'multi line\nmessage' left right)" \
    || exit_code=$?
  assert_success "second merge with the same parents created" "$exit_code"
  assert_neq "distinct commit resolved for the second merge" "$commit2" "$commit"
  assert_eq "multi-line description round-trips" \
    "$(_jj__get_commit_description "$REPO" "$commit2")" $'multi line\nmessage'
}

test__jj__create_merge_commit__octopus_and_failures() {
  setup_workspace
  local base i
  base="$(get_full_commit_id '@-')"
  for i in 1 2 3; do
    jj -R "$REPO" new "$base" >/dev/null 2>&1
    edit_file "side$i.txt" "s$i"
    jj -R "$REPO" commit -m "side $i" >/dev/null 2>&1
    jj -R "$REPO" bookmark set "side$i" -r '@-' >/dev/null 2>&1
  done
  local commit exit_code=0
  commit="$(_jj__create_merge_commit "$REPO" 'tricky "quoted" \ message' \
    side1 side2 side3)" || exit_code=$?
  assert_success "three-parent merge created" "$exit_code"
  assert_line_count "three parents recorded" \
    "$(jj -R "$REPO" --ignore-working-copy log -r "$commit" --no-graph \
      -T 'parents.map(|p| p.commit_id()).join("\n")')" 3
  assert_eq "quoted description round-trips" \
    "$(_jj__get_commit_description "$REPO" "$commit")" 'tricky "quoted" \ message'

  exit_code=0
  _jj__create_merge_commit "$REPO" "msg" side1 >/dev/null || exit_code=$?
  assert_failure "fewer than two parents rejected" "$exit_code"
  exit_code=0
  _jj__create_merge_commit "$REPO" "msg" side1 no-such-bookmark >/dev/null \
    || exit_code=$?
  assert_failure "absent parent rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__set_description
# ---------------------------------------------------------------------------

test__jj__set_description__replaces_and_rejects_absent() {
  setup_workspace
  _fixture_linear_history
  local first_change
  first_change="$(_jj__resolve_change "$REPO" "$FIRST_COMMIT")"
  local exit_code=0
  _jj__set_description "$REPO" "$FIRST_COMMIT" "rewritten description" \
    || exit_code=$?
  assert_success "description replaced" "$exit_code"
  assert_eq "new description stored" \
    "$(_jj__get_commit_description "$REPO" 'feature-')" "rewritten description"
  assert_eq "change ID preserved across the rewrite" \
    "$(_jj__resolve_change "$REPO" 'feature-')" "$first_change"

  exit_code=0
  _jj__set_description "$REPO" no-such-bookmark "x" || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__move_commits
# ---------------------------------------------------------------------------

test__jj__move_commits__rebases_sources_onto_destination() {
  setup_workspace
  _fixture_linear_history
  jj -R "$REPO" new "$BASE_COMMIT" >/dev/null 2>&1
  edit_file dest.txt "d"
  jj -R "$REPO" commit -m "destination" >/dev/null 2>&1
  jj -R "$REPO" bookmark set dest -r '@-' >/dev/null 2>&1

  local exit_code=0
  _jj__move_commits "$REPO" dest "$FIRST_COMMIT" || exit_code=$?
  assert_success "source rebased" "$exit_code"
  local ec=0
  _jj__check_is_ancestor "$REPO" dest feature || ec=$?
  assert_success "destination now an ancestor of the moved branch" "$ec"
  assert_eq "descendants moved along with the source" \
    "$(_jj__count_commits_in_range "$REPO" dest feature)" "2"
  assert_eq "moved commit content intact" \
    "$(_jj__read_file_at_revision "$REPO" feature two.txt)" "two"

  exit_code=0
  _jj__move_commits "$REPO" dest || exit_code=$?
  assert_failure "no sources rejected" "$exit_code"
  exit_code=0
  _jj__move_commits "$REPO" dest no-such-bookmark || exit_code=$?
  assert_failure "absent source rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__squash_commit
# ---------------------------------------------------------------------------

test__jj__squash_commit__preserves_destination_identity_and_message() {
  setup_workspace
  edit_file dst.txt "d"
  jj -R "$REPO" commit -m "destination message" >/dev/null 2>&1
  jj -R "$REPO" bookmark set dst -r '@-' >/dev/null 2>&1
  edit_file extra.txt "e"
  jj -R "$REPO" commit -m "source message" >/dev/null 2>&1
  local src_commit dst_change
  src_commit="$(get_full_commit_id '@-')"
  dst_change="$(_jj__resolve_change "$REPO" dst)"

  local exit_code=0
  _jj__squash_commit "$REPO" "$src_commit" dst || exit_code=$?
  assert_success "squashed" "$exit_code"
  assert_eq "destination change ID preserved" \
    "$(_jj__resolve_change "$REPO" dst)" "$dst_change"
  assert_eq "destination message preserved" \
    "$(_jj__get_commit_description "$REPO" dst)" "destination message"
  assert_eq "source content folded into the destination" \
    "$(_jj__read_file_at_revision "$REPO" dst extra.txt)" "e"
  assert_eq "emptied source abandoned; @ now sits on the destination" \
    "$(_jj__resolve_commit "$REPO" '@-')" "$(_jj__resolve_commit "$REPO" dst)"

  exit_code=0
  _jj__squash_commit "$REPO" no-such-bookmark dst || exit_code=$?
  assert_failure "absent source revision rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__restore_tree
# ---------------------------------------------------------------------------

test__jj__restore_tree__wholesale_tree_and_descendant_content() {
  setup_workspace
  edit_file a.txt "base"
  jj -R "$REPO" commit -m "base file" >/dev/null 2>&1
  local base
  base="$(get_full_commit_id '@-')"
  edit_file a.txt "target version"
  edit_file t.txt "target only"
  jj -R "$REPO" commit -m "target" >/dev/null 2>&1
  jj -R "$REPO" bookmark set tgt -r '@-' >/dev/null 2>&1
  edit_file c.txt "child file"
  jj -R "$REPO" commit -m "child" >/dev/null 2>&1
  jj -R "$REPO" bookmark set kid -r '@-' >/dev/null 2>&1
  jj -R "$REPO" new "$base" >/dev/null 2>&1
  edit_file a.txt "source version"
  jj -R "$REPO" commit -m "source" >/dev/null 2>&1
  jj -R "$REPO" bookmark set src -r '@-' >/dev/null 2>&1

  local tgt_change
  tgt_change="$(_jj__resolve_change "$REPO" tgt)"
  local exit_code=0
  _jj__restore_tree "$REPO" src tgt || exit_code=$?
  assert_success "tree restored" "$exit_code"
  assert_eq "target change ID unchanged" \
    "$(_jj__resolve_change "$REPO" tgt)" "$tgt_change"
  assert_eq "target description unchanged" \
    "$(_jj__get_commit_description "$REPO" tgt)" "target"
  assert_output_empty "target tree equals source tree" \
    "$(_jj__show_diff "$REPO" src tgt)"
  local ec=0
  _jj__check_file_exists_at_revision "$REPO" tgt t.txt || ec=$?
  assert_failure "target-only file gone after the wholesale restore" "$ec"
  assert_eq "descendant keeps its content, not a replayed diff" \
    "$(_jj__read_file_at_revision "$REPO" kid a.txt)" "target version"
  assert_eq "descendant's own file intact" \
    "$(_jj__read_file_at_revision "$REPO" kid c.txt)" "child file"

  exit_code=0
  _jj__restore_tree "$REPO" no-such-bookmark tgt || exit_code=$?
  assert_failure "absent source rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _jj__abandon_commit
# ---------------------------------------------------------------------------

test__jj__abandon_commit__abandons_and_rejects_absent() {
  setup_workspace
  _fixture_linear_history
  # Park the working copy away from the branch being rewritten: a bare abandon
  # of an ancestor of @ would leave @'s on-disk working copy stale.
  jj -R "$REPO" new main >/dev/null 2>&1
  local second_change
  second_change="$(_jj__resolve_change "$REPO" feature)"
  local exit_code=0
  _jj__abandon_commit "$REPO" "$FIRST_COMMIT" || exit_code=$?
  assert_success "commit abandoned" "$exit_code"
  assert_eq "descendants rebased onto the abandoned commit's parent" \
    "$(_jj__count_commits_in_range "$REPO" "$BASE_COMMIT" feature)" "1"
  local ec=0
  _jj__check_file_exists_at_revision "$REPO" feature one.txt || ec=$?
  assert_failure "abandoned commit's file gone from the rebased tip" "$ec"
  assert_eq "surviving commit keeps its change ID" \
    "$(_jj__resolve_change "$REPO" feature)" "$second_change"

  exit_code=0
  _jj__abandon_commit "$REPO" no-such-bookmark || exit_code=$?
  assert_failure "absent revision rejected" "$exit_code"
}

run_tests "tt lib/vcs/jj (unit)"
