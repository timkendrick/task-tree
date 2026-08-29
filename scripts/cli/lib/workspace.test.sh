#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for workspace resolution and configuration in lib/workspace.sh
# ---------------------------------------------------------------------------

# Create a second, plain repository directory beside the setup_workspace one
# and print its canonicalized path. Workspace resolution only inspects the
# on-disk repository marker directory, so an empty marker is a sufficient
# stand-in for a full repository here.
_make_other_repo() {
  local dir="$1"
  mkdir -p "$dir/.jj"
  (cd "$dir" && pwd -P)
}

test__workspace__resolve_repo__flag_beats_env() {
  setup_workspace "resolve-repo-flag"
  local other
  other="$(_make_other_repo "$_TEST_ROOT/resolve-repo-flag/other")"

  local resolved
  resolved="$(TT_REPO="$other" _workspace__resolve_repo "$REPO")"
  assert_eq "--repo value wins over TT_REPO" "$resolved" "$REPO"
}

test__workspace__resolve_repo__env_beats_walk_up() {
  setup_workspace "resolve-repo-env"
  local other
  other="$(_make_other_repo "$_TEST_ROOT/resolve-repo-env/other")"

  local resolved
  resolved="$(cd "$other" && TT_REPO="$REPO" _workspace__resolve_repo "")"
  assert_eq "TT_REPO wins over walk-up from CWD" "$resolved" "$REPO"
}

test__workspace__resolve_repo__walks_up_from_cwd() {
  setup_workspace "resolve-repo-walk"
  local other
  other="$(_make_other_repo "$_TEST_ROOT/resolve-repo-walk/other")"
  mkdir -p "$other/nested/sub"

  local resolved
  resolved="$(cd "$other/nested/sub" && unset TT_REPO && _workspace__resolve_repo "")"
  assert_eq "walk-up finds the enclosing repo" "$resolved" "$other"
}

test__workspace__resolve_repo__rejects_non_repository() {
  local plain
  plain="$(mktemp -d)"
  trap 'rm -rf "$plain"' RETURN

  local out exit_code=0
  out="$( (_workspace__resolve_repo "$plain") 2>&1 )" || exit_code=$?
  assert_exit_code "non-repo path rejected" 1 "$exit_code"
  assert_contains "error names the path" "$out" "Error: Not a jj repository: $plain"
}

test__workspace__resolve_repo__errors_without_enclosing_repo() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  local out exit_code=0
  out="$( (cd "$dir" && unset TT_REPO && _workspace__resolve_repo "") 2>&1 )" || exit_code=$?
  assert_exit_code "no enclosing repo rejected" 1 "$exit_code"
  assert_contains "error suggests --repo / TT_REPO" "$out" \
    "Error: No enclosing jj repository. Use --repo or set TT_REPO."
}

test__workspace__prefixes__defaults_without_config() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  assert_eq "task prefix defaults to task/" "$(_workspace__get_task_prefix "$dir")" "task/"
  assert_eq "project prefix defaults to project/" "$(_workspace__get_project_prefix "$dir")" "project/"
}

test__workspace__prefixes__read_from_config() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  mkdir -p "$dir/.tt"
  printf 'task_prefix = "feature/"\nproject_prefix = "epic/"\n' > "$dir/.tt/config.toml"

  assert_eq "task prefix read from config" "$(_workspace__get_task_prefix "$dir")" "feature/"
  assert_eq "project prefix read from config" "$(_workspace__get_project_prefix "$dir")" "epic/"
}

test__workspace__dir__set_get_round_trip() {
  local root
  root="$(mktemp -d)"
  trap 'rm -rf "$root"' RETURN
  mkdir -p "$root/repo/.tt" "$root/virtual"
  local expected
  expected="$(cd "$root/virtual" && pwd -P)"

  _workspace__set_dir "$root/repo" "$root/virtual"
  local target
  target="$(readlink "$root/repo/.tt/workspace")"
  assert_matches "workspace symlink target is absolute" "$target" '^/'
  assert_eq "get returns the canonicalized directory" \
    "$(_workspace__get_dir "$root/repo")" "$expected"
}

test__workspace__get_dir__fails_when_unconfigured() {
  local root
  root="$(mktemp -d)"
  trap 'rm -rf "$root"' RETURN
  mkdir -p "$root/repo/.tt"

  local exit_code=0
  _workspace__get_dir "$root/repo" >/dev/null || exit_code=$?
  assert_failure "unconfigured workspace dir" "$exit_code"
}

test__workspace__get_active_worktree__reads_head_symlink() {
  local root
  root="$(mktemp -d)"
  trap 'rm -rf "$root"' RETURN
  mkdir -p "$root/ws" "$root/wt"
  local expected
  expected="$(cd "$root/wt" && pwd -P)"
  ln -s "$root/wt" "$root/ws/HEAD"

  assert_eq "active worktree resolved from HEAD" \
    "$(_workspace__get_active_worktree "$root/ws")" "$expected"
}

test__workspace__get_active_worktree__fails_without_head() {
  local root
  root="$(mktemp -d)"
  trap 'rm -rf "$root"' RETURN
  mkdir -p "$root/ws"

  local exit_code=0
  _workspace__get_active_worktree "$root/ws" >/dev/null || exit_code=$?
  assert_failure "absent HEAD symlink" "$exit_code"
}

run_tests "tt lib/workspace (unit)"
