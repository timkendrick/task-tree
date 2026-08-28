#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for path helpers in lib/path.sh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _path__metadata
# ---------------------------------------------------------------------------

test__path__metadata__bare() {
  assert_eq "metadata dir without subpath" "$(_path__metadata)" ".tt"
}

test__path__metadata__with_subpath() {
  assert_eq "metadata dir with subpath" "$(_path__metadata 'config.toml')" ".tt/config.toml"
}

# ---------------------------------------------------------------------------
# _path__task_root / _path__task_file / _path__task_dir / _path__task_context
# ---------------------------------------------------------------------------

test__path__task_root__shape() {
  assert_eq "task root path" "$(_path__task_root)" ".tt/task"
}

test__path__task_file__shape() {
  assert_eq "task file path" \
    "$(_path__task_file 'my-task-abc12345')" ".tt/task/my-task-abc12345/TASK.md"
}

test__path__task_dir__shape() {
  assert_eq "task dir path" \
    "$(_path__task_dir 'my-task-abc12345')" ".tt/task/my-task-abc12345"
}

test__path__task_context__shape() {
  assert_eq "context file path" \
    "$(_path__task_context 'my-task-abc12345' 'context/notes-def67890')" \
    ".tt/task/my-task-abc12345/context/notes-def67890.md"
}

# ---------------------------------------------------------------------------
# _path__metadata_exclusions
# ---------------------------------------------------------------------------

test__path__metadata_exclusions__record_format() {
  local out
  out="$(_path__metadata_exclusions)"
  assert_line_count "one record per excluded path" "$out" 2
  assert_eq "dir record for the metadata directory" \
    "$(printf '%s\n' "$out" | sed -n '1p')" "$(printf 'dir\t.tt')"
  assert_eq "file record for the task symlink" \
    "$(printf '%s\n' "$out" | sed -n '2p')" "$(printf 'file\tTASK.md')"
}

# ---------------------------------------------------------------------------
# _path__resolve_symlinks
# ---------------------------------------------------------------------------

test__path__resolve_symlinks__follows_symlinks() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  mkdir "$dir/real"
  ln -s "$dir/real" "$dir/link"

  local expected
  expected="$(cd "$dir/real" && pwd -P)"
  assert_eq "symlinked dir resolves to canonical path" \
    "$(_path__resolve_symlinks "$dir/link")" "$expected"
}

test__path__resolve_symlinks__fails_for_missing_dir() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  local exit_code=0
  _path__resolve_symlinks "$dir/missing" 2>/dev/null || exit_code=$?
  assert_failure "missing directory rejected" "$exit_code"
}

# ---------------------------------------------------------------------------
# _path__make_absolute_symlink
# ---------------------------------------------------------------------------

test__path__make_absolute_symlink__absolute_target() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  mkdir "$dir/target"

  _path__make_absolute_symlink "$dir/target" "$dir/link"
  assert_symlink "absolute target used verbatim" "$dir/link" "$dir/target"
}

test__path__make_absolute_symlink__resolves_relative_target() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  mkdir "$dir/target"

  (cd "$dir" && _path__make_absolute_symlink "target" "$dir/link")

  local expected
  expected="$(cd "$dir/target" && pwd -P)"
  assert_symlink "relative target resolved to absolute path" "$dir/link" "$expected"
}

test__path__make_absolute_symlink__replaces_existing_symlink() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN
  mkdir "$dir/first" "$dir/second"

  _path__make_absolute_symlink "$dir/first" "$dir/link"
  _path__make_absolute_symlink "$dir/second" "$dir/link"
  assert_symlink "existing symlink replaced" "$dir/link" "$dir/second"
}

test__path__make_absolute_symlink__missing_target_errors() {
  local dir
  dir="$(mktemp -d)"
  trap 'rm -rf "$dir"' RETURN

  local out exit_code=0
  out="$(_path__make_absolute_symlink "$dir/missing" "$dir/link" 2>&1)" || exit_code=$?
  assert_failure "missing target rejected" "$exit_code"
  assert_contains "error message names the target" "$out" "Symlink target does not exist: $dir/missing"
  assert_file_not_exists "no symlink created" "$dir/link"
}

run_tests "tt lib/path (unit)"
