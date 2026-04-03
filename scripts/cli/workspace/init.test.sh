#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


test_workspace_init__basic_initialization() {
  setup_workspace "init-basic"
  repo="$_TEST_ROOT/init-basic-alt/repo"
  virtual="$_TEST_ROOT/init-basic-alt/virtual"
  mkdir -p "$repo"
  jj git init "$repo" >/dev/null 2>&1
  cd "$repo"
  echo "initial" > README.md
  jj -R "$repo" commit -m "Initial commit" >/dev/null 2>&1
  jj -R "$repo" bookmark set main >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt workspace init "$repo" "$virtual" 2>&1) || exit_code=$?

  assert_success "init succeeds" "$exit_code"
  assert_file_exists ".tt/config.toml exists" "$repo/.tt/config.toml"
  assert_file_exists ".tt/.gitignore exists" "$repo/.tt/.gitignore"
  assert_file_exists ".tt/history exists" "$repo/.tt/history"

  config="$(cat "$repo/.tt/config.toml")"
  assert_contains "config has task_prefix" "$config" 'task_prefix = "task/"'
  assert_contains "config has project_prefix" "$config" 'project_prefix = "project/"'

  gitignore="$(cat "$repo/.tt/.gitignore")"
  assert_contains "gitignore has /history" "$gitignore" "/history"
  assert_contains "gitignore has /workspace" "$gitignore" "/workspace"

  assert_symlink ".tt/workspace symlink" "$repo/.tt/workspace" "$virtual"

  assert_file_exists "virtual dir exists" "$virtual"
  assert_symlink "HEAD symlink" "$virtual/HEAD" "$repo"
}


test_workspace_init__custom_prefixes() {
  setup_workspace "init-prefixes"
  repo="$_TEST_ROOT/init-prefixes-alt/repo"
  virtual="$_TEST_ROOT/init-prefixes-alt/virtual"
  mkdir -p "$repo"
  jj git init "$repo" >/dev/null 2>&1
  cd "$repo"
  echo "initial" > README.md
  jj -R "$repo" commit -m "Initial commit" >/dev/null 2>&1
  jj -R "$repo" bookmark set main >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt workspace init "$repo" "$virtual" --task-prefix "t/" --project-prefix "p/" 2>&1) || exit_code=$?
  assert_success "init with custom prefixes succeeds" "$exit_code"
  config="$(cat "$repo/.tt/config.toml")"
  assert_contains "config has task_prefix t/" "$config" 'task_prefix = "t/"'
  assert_contains "config has project_prefix p/" "$config" 'project_prefix = "p/"'
}


test_workspace_init__same_prefix_rejected() {
  setup_workspace "init-same-prefix"
  repo="$_TEST_ROOT/init-same-alt/repo"
  virtual="$_TEST_ROOT/init-same-alt/virtual"
  mkdir -p "$repo"
  jj git init "$repo" >/dev/null 2>&1
  cd "$repo"
  echo "initial" > README.md
  jj -R "$repo" commit -m "Initial commit" >/dev/null 2>&1
  jj -R "$repo" bookmark set main >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt workspace init "$repo" "$virtual" --task-prefix "x/" --project-prefix "x/" 2>&1) || exit_code=$?
  assert_failure "same prefix rejected" "$exit_code"
  assert_contains "error about prefixes" "$output" "prefix"
}


test_workspace_init__non_jj_directory_rejected() {
  setup_workspace "init-non-jj"
  repo="$_TEST_ROOT/init-nonjj/repo"
  virtual="$_TEST_ROOT/init-nonjj/virtual"
  mkdir -p "$repo"

  output="" exit_code=0
  output=$(run_tt workspace init "$repo" "$virtual" 2>&1) || exit_code=$?
  assert_failure "non-jj directory rejected" "$exit_code"
}


test_workspace_init__dirty_working_copy_rejected() {
  setup_workspace "init-dirty"
  repo="$_TEST_ROOT/init-dirty-alt/repo"
  virtual="$_TEST_ROOT/init-dirty-alt/virtual"
  mkdir -p "$repo"
  jj git init "$repo" >/dev/null 2>&1
  cd "$repo"
  echo "initial" > README.md
  jj -R "$repo" commit -m "Initial commit" >/dev/null 2>&1
  jj -R "$repo" bookmark set main >/dev/null 2>&1
  echo "dirty" > "$repo/untracked-file.txt"

  output="" exit_code=0
  output=$(run_tt workspace init "$repo" "$virtual" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
}


test_workspace_init__non_empty_virtual_dir_without_force() {
  setup_workspace "init-noempty"
  repo="$_TEST_ROOT/init-noempty-alt/repo"
  virtual="$_TEST_ROOT/init-noempty-alt/virtual"
  mkdir -p "$repo" "$virtual"
  echo "existing" > "$virtual/some-file.txt"
  jj git init "$repo" >/dev/null 2>&1
  cd "$repo"
  echo "initial" > README.md
  jj -R "$repo" commit -m "Initial commit" >/dev/null 2>&1
  jj -R "$repo" bookmark set main >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt workspace init "$repo" "$virtual" 2>&1) || exit_code=$?
  assert_failure "non-empty virtual dir rejected" "$exit_code"

  exit_code=0
  output=$(run_tt workspace init "$repo" "$virtual" --force 2>&1) || exit_code=$?
  assert_success "with --force succeeds" "$exit_code"
}


test_workspace_init__tt_file_without_force() {
  setup_workspace "init-ttfile"
  repo="$_TEST_ROOT/init-ttfile-alt/repo"
  virtual="$_TEST_ROOT/init-ttfile-alt/virtual"
  mkdir -p "$repo" "$virtual"
  echo "not-a-dir" > "$repo/.tt"
  jj git init "$repo" >/dev/null 2>&1
  cd "$repo"
  echo "initial" > README.md
  jj -R "$repo" commit -m "Initial commit" >/dev/null 2>&1
  jj -R "$repo" bookmark set main >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt workspace init "$repo" "$virtual" 2>&1) || exit_code=$?
  assert_failure ".tt file without --force rejected" "$exit_code"

  exit_code=0
  output=$(run_tt workspace init "$repo" "$virtual" --force 2>&1) || exit_code=$?
  assert_success "with --force succeeds" "$exit_code"
  assert_file_exists ".tt is now a directory" "$repo/.tt/config.toml"
}


run_tests "tt workspace init"
