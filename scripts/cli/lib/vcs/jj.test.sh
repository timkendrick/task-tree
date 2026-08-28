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
