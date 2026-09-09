#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for hook execution in lib/hook.sh
# ---------------------------------------------------------------------------

# Helper: create an executable hook named NAME in REPO whose body is BODY.
_make_hook() {
  local repo="$1" name="$2" body="$3"
  mkdir -p "$repo/.tt/hooks"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$repo/.tt/hooks/$name"
  chmod +x "$repo/.tt/hooks/$name"
}

test__hook__run__runs_hook_with_env_vars() {
  local repo
  repo="$(mktemp -d)"
  trap 'rm -rf "$repo"' RETURN
  _make_hook "$repo" "test-hook" \
    'printf "%s|%s|%s\n" "$TT_WORKSPACE_DIR" "$TT_WORKTREE_DIR" "$TT_EXTRA" > "$(dirname "$0")/../../out"'

  _hook__run "$repo" "test-hook" false "/wt/dir" "/ws/dir" "TT_EXTRA=extra-value"

  assert_file_exists "hook ran" "$repo/out"
  assert_eq "hook received env vars" "$(cat "$repo/out")" "/ws/dir|/wt/dir|extra-value"
}

test__hook__run__missing_hook_is_noop() {
  local repo
  repo="$(mktemp -d)"
  trap 'rm -rf "$repo"' RETURN

  local out exit_code=0
  out="$(_hook__run "$repo" "no-such-hook" true "/wt/dir" "/ws/dir" 2>&1)" || exit_code=$?
  assert_success "missing hook returns 0" "$exit_code"
  assert_output_empty "no output for missing hook" "$out"
}

test__hook__run__nonblocking_failure_warns_and_returns_zero() {
  local repo
  repo="$(mktemp -d)"
  trap 'rm -rf "$repo"' RETURN
  _make_hook "$repo" "test-hook" 'exit 3'

  local out exit_code=0
  out="$(_hook__run "$repo" "test-hook" false "/wt/dir" "/ws/dir" 2>&1)" || exit_code=$?
  assert_success "non-blocking failure returns 0" "$exit_code"
  assert_contains "warning names the hook and exit code" "$out" \
    "Warning: Hook 'test-hook' failed (exit 3; non-blocking)."
}

test__hook__run__blocking_failure_exits_nonzero() {
  local repo
  repo="$(mktemp -d)"
  trap 'rm -rf "$repo"' RETURN
  _make_hook "$repo" "test-hook" 'exit 3'

  local out exit_code=0
  out="$(_hook__run "$repo" "test-hook" true "/wt/dir" "/ws/dir" 2>&1)" || exit_code=$?
  assert_exit_code "blocking failure aborts" 1 "$exit_code"
  assert_contains "error names the hook and exit code" "$out" \
    "Error: Hook 'test-hook' failed (exit 3); aborting."
}

test__hook__run__successful_blocking_hook_returns_zero() {
  local repo
  repo="$(mktemp -d)"
  trap 'rm -rf "$repo"' RETURN
  _make_hook "$repo" "test-hook" 'exit 0'

  local exit_code=0
  _hook__run "$repo" "test-hook" true "/wt/dir" "/ws/dir" || exit_code=$?
  assert_success "successful blocking hook" "$exit_code"
}

run_tests "tt lib/hook (unit)"
