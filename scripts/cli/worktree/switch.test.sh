#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


test_worktree_switch__non_workspace_path_rejected() {
  setup_workspace "switch-invalid"
  output="" exit_code=0
  output=$(run_tt worktree switch "/tmp/nonexistent-path" 2>&1) || exit_code=$?
  assert_failure "non-workspace path rejected" "$exit_code"
  assert_contains "error mentions worktree" "$output" "is not a worktree in this repository"
}


test_worktree_switch__switches_to_existing_worktree() {
  setup_workspace "switch-worktree"
  local proj_id task_id
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_id=$(create_task "my-task" "My Task") || true

  # Check out the task with a dedicated worktree
  local worktree_path="$_TEST_ROOT/switch-worktree-task-wt"
  run_tt task checkout "$task_id" --worktree="$worktree_path" >/dev/null 2>&1 || true

  # Switch back to the main repo WC on the project branch
  jj -R "$REPO" new "$proj_id" >/dev/null 2>&1 || true

  # Now switch HEAD to the task worktree via tt worktree switch
  output="" exit_code=0
  output=$(run_tt worktree switch "$worktree_path" 2>&1) || exit_code=$?
  assert_success "worktree switch succeeds" "$exit_code"

  # HEAD symlink should now resolve to the task worktree
  local virtual_dir
  virtual_dir="$(readlink "$REPO/.tt/workspace")"
  local head_target resolved_head
  head_target="$(readlink "$virtual_dir/HEAD" 2>/dev/null || true)"
  if [[ "$head_target" != /* ]]; then
    head_target="$virtual_dir/$head_target"
  fi
  resolved_head="$(cd "$head_target" 2>/dev/null && pwd -P)" || true
  local canonical_worktree
  canonical_worktree="$(cd "$worktree_path" 2>/dev/null && pwd -P)" || true
  assert_eq "HEAD points to task worktree" "$resolved_head" "$canonical_worktree"
}


test_worktree_switch__help() {
  setup_workspace "switch-help"
  output="" exit_code=0
  output=$(run_tt worktree switch --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt worktree switch"
  assert_required_usage_argument "argument: [<worktree-path>]" "$output" "[<worktree-path>]"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}

test_worktree_switch__defaults_to_current_worktree() {
  setup_workspace "switch-default-cwd"
  local proj_id task_id
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_id=$(create_task "my-task" "My Task") || true

  # Check out the task with a dedicated worktree
  local worktree_path="$_TEST_ROOT/switch-default-cwd-task-wt"
  run_tt task checkout "$task_id" --worktree="$worktree_path" >/dev/null 2>&1 || true

  # Switch HEAD back to main repo so we can test switching to the worktree
  jj -R "$REPO" new "$proj_id" >/dev/null 2>&1 || true
  run_tt worktree switch "$REPO" >/dev/null 2>&1 || true

  # Now invoke switch with no args from within the task worktree
  output="" exit_code=0
  output=$(run_tt_in_worktree "$worktree_path" worktree switch 2>&1) || exit_code=$?
  assert_success "switch with no arg from worktree succeeds" "$exit_code"

  # HEAD symlink should now resolve to the task worktree
  local virtual_dir
  virtual_dir="$(readlink "$REPO/.tt/workspace")"
  local head_target
  head_target="$(readlink "$virtual_dir/HEAD" 2>/dev/null || true)"
  if [[ "$head_target" != /* ]]; then
    head_target="$virtual_dir/$head_target"
  fi
  local resolved_head canonical_worktree
  resolved_head="$(cd "$head_target" 2>/dev/null && pwd -P)" || true
  canonical_worktree="$(cd "$worktree_path" 2>/dev/null && pwd -P)" || true
  assert_eq "HEAD points to task worktree" "$resolved_head" "$canonical_worktree"
}

test_worktree_switch__previous_task_comes_from_the_head_worktree() {
  # A switch moves HEAD, so the task it leaves behind is the one the HEAD
  # worktree holds — not the one the worktree running the command holds.
  setup_workspace "switch-previous-task"
  local proj_id task_a task_b wt_b
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null 2>&1 || true
  task_a=$(create_task "a" "A") || true
  task_b=$(create_task "b" "B") || true
  create_task_worktree "$task_a" --switch >/dev/null
  wt_b=$(create_task_worktree "$task_b")

  # HEAD is on task A's worktree; the repo worktree, where the command runs,
  # still holds the project.
  assert_task_symlink "the invoking worktree holds the project" "$proj_id"

  local record="$_TEST_ROOT/switch-previous-task.txt"
  mkdir -p "$REPO/.tt/hooks"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$TT_PREVIOUS_TASK_ID" > "%s"\n' "$record" \
    > "$REPO/.tt/hooks/pre-checkout"
  chmod +x "$REPO/.tt/hooks/pre-checkout"

  output="" exit_code=0
  output=$(run_tt worktree switch "$wt_b" 2>&1) || exit_code=$?
  assert_success "switch succeeds" "$exit_code"
  assert_eq "the outgoing task is the one HEAD pointed at" \
    "$(cat "$record" 2>/dev/null)" "$task_a"
}


test_worktree_switch__no_arg_outside_worktree_fails() {
  setup_workspace "switch-no-arg-outside"
  # Run switch with no arg from a temp dir that is not inside any jj workspace
  output="" exit_code=0
  output=$(run_tt_in_worktree "/tmp" worktree switch 2>&1) || exit_code=$?
  assert_failure "switch with no arg outside worktree fails" "$exit_code"
  assert_contains "error message" "$output" "could not detect current worktree"
}


run_tests "tt worktree switch"
