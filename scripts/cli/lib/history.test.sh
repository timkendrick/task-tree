#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"
# shellcheck source=common.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# ---------------------------------------------------------------------------
# Unit tests for transaction history management in lib/history.sh
# ---------------------------------------------------------------------------

_COMMON_SH="$(cd "${BASH_SOURCE[0]%/*}" && pwd)/common.sh"

# Usage: run_command REPO BODY
#
# Runs BODY as a tt command would run: a separate bash process under
# `set -euo pipefail` that has sourced the library and owns no transaction yet.
# BODY sees the repository root as $1 and the sub-command script (below) as
# $TT_TEST_SUBCOMMAND. Returns the process's exit status.
#
# A separate process rather than a subshell, because bash disables errexit
# inside a compound command that is the left operand of `||` — which is how a
# test captures an exit status — and a `set -e` failure is exactly what several
# of these tests are about.
run_command() {
  local repo="$1" body="$2"
  env -u TT_TRANSACTION_ID TT_TEST_COMMON_SH="$_COMMON_SH" \
    bash -c "set -euo pipefail; . \"\$TT_TEST_COMMON_SH\"; $body" bash "$repo"
}

# Usage: write_subcommand
# Writes the script that stands in for a tt sub-command and exports its path as
# TT_TEST_SUBCOMMAND, for a command body to invoke as "$TT_TEST_SUBCOMMAND"
# <repo> <exit-status>. It behaves as any tt command does: it begins a
# transaction — a no-op while TT_TRANSACTION_ID reaches it through the
# environment — commits it on success, and exits with the status it was given.
write_subcommand() {
  export TT_TEST_SUBCOMMAND="$_TEST_ROOT/subcommand.sh"
  cat > "$TT_TEST_SUBCOMMAND" <<'SUBCOMMAND'
#!/usr/bin/env bash
set -euo pipefail
. "$TT_TEST_COMMON_SH"
_history__begin_transaction "$1"
status="${2:-0}"
[[ "$status" -eq 0 ]] && _history__commit_transaction "$1"
exit "$status"
SUBCOMMAND
  chmod +x "$TT_TEST_SUBCOMMAND"
}

# Usage: record_commit REPO MESSAGE
# Shell snippet for a command body: writes a file and commits it, so the test
# can look for the commit afterwards to tell a rollback from a completed run.
_RECORD_COMMIT='printf %s\\n x > "$1/txn-work.txt"; jj -R "$1" commit -m'

test__history__transaction__begin_commit_round_trip() {
  setup_workspace "history-begin-commit"

  local before_op
  before_op="$(get_jj_op)"

  (
    unset TT_TRANSACTION_ID
    _history__begin_transaction "$REPO"
    edit_file "$REPO/work.txt" "work"
    jj_commit "history txn work"
    _history__commit_transaction "$REPO"
  )

  get_history_lines
  assert_eq "exactly one completed entry recorded" "${#HISTORY_LINES[@]}" "1"
  local entry="${HISTORY_LINES[0]}"
  assert_eq "before-op captured at begin" "$(history_before_op "$entry")" "$before_op"
  assert_eq "after-op is the current jj op" "$(history_after_op "$entry")" "$(get_jj_op)"
  assert_no_pending_transaction "entry is completed (non-empty after-op)"
  assert_file_not_exists "the history lock is released" "$REPO/.tt/history.lock"
}

test__history__transaction__begin_refuses_in_progress() {
  setup_workspace "history-begin-locked"

  # Simulate a crashed process: an in-progress entry with an empty after-op-id.
  printf '%s:\n' "deadbeefdeadbeef" >> "$REPO/.tt/history"

  local out exit_code=0
  out="$( (unset TT_TRANSACTION_ID; _history__begin_transaction "$REPO") 2>&1 )" || exit_code=$?
  assert_exit_code "begin aborts when a transaction is in progress" 1 "$exit_code"
  assert_contains "error names the incomplete transaction" "$out" \
    "Error: Another tt command is in progress (incomplete transaction)."
  assert_contains "suggests undo --force" "$out" \
    "To revert a crashed process: tt history undo --force"
  assert_contains "suggests unlock --force" "$out" \
    "Or to keep the current state: tt history unlock --force"
  assert_history_count "no new entry appended" 1
}

test__history__transaction__concurrent_begins_admit_one() {
  setup_workspace "history-concurrent"

  # Each command holds its transaction open long enough for the other to reach
  # its in-progress check while it is still running.
  local body='
    _history__begin_transaction "$1"
    sleep 3
    _history__commit_transaction "$1"
  '
  local out_a="$_TEST_ROOT/concurrent-a.txt" out_b="$_TEST_ROOT/concurrent-b.txt"
  local pid_a pid_b status_a=0 status_b=0
  run_command "$REPO" "$body" >"$out_a" 2>&1 &
  pid_a=$!
  run_command "$REPO" "$body" >"$out_b" 2>&1 &
  pid_b=$!
  wait "$pid_a" || status_a=$?
  wait "$pid_b" || status_b=$?

  assert_eq "exactly one command succeeds" \
    "$(( (status_a == 0) + (status_b == 0) ))" "1"
  local refused_output
  if [[ "$status_a" -eq 0 ]]; then
    refused_output="$(<"$out_b")"
  else
    refused_output="$(<"$out_a")"
  fi
  assert_contains "the other refuses on the in-progress entry" "$refused_output" \
    "Error: Another tt command is in progress (incomplete transaction)."
  assert_history_count "only the successful command is recorded" 1
  assert_no_pending_transaction "the recorded entry is completed"
  assert_file_not_exists "the history lock is released" "$REPO/.tt/history.lock"
}

test__history__transaction__begin_times_out_on_held_lock() {
  setup_workspace "history-begin-lock-held"
  mkdir "$REPO/.tt/history.lock"

  local out exit_code=0
  out="$( (unset TT_TRANSACTION_ID; _history__begin_transaction "$REPO") 2>&1 )" || exit_code=$?
  assert_exit_code "begin aborts when the lock is held" 1 "$exit_code"
  assert_contains "error reports the timeout" "$out" \
    "Error: Timed out after 5s waiting for the history lock:"
  assert_contains "error names the lock directory" "$out" ".tt/history.lock"
  assert_contains "suggests unlock --force" "$out" \
    "To clear a leftover lock: tt history unlock --force"
  assert_history_count "no entry appended" 0
  assert_file_exists "the held lock is left in place" "$REPO/.tt/history.lock"
}

test__history__transaction__rollback_restores_op_and_removes_entry() {
  setup_workspace "history-rollback"

  (
    unset TT_TRANSACTION_ID
    _history__begin_transaction "$REPO"
    edit_file "$REPO/rollback.txt" "x"
    jj_commit "history txn rollback"
    _history__rollback_transaction "$REPO" 2>/dev/null
  )

  local descriptions
  descriptions="$(get_commit_message 'all()')"
  assert_not_contains "rolled-back commit is gone from the op state" \
    "$descriptions" "history txn rollback"
  assert_history_count "in-progress line removed from history" 0
  assert_file_not_exists "the history lock is released" "$REPO/.tt/history.lock"
}

test__history__transaction__failed_exit_rolls_back() {
  setup_workspace "history-exit-fail"

  local exit_code=0
  # `exit` is how every command reports a failed precondition, and an ERR trap
  # does not fire for it: only the EXIT half of the abort trap catches this.
  run_command "$REPO" '
    _history__begin_transaction "$1"
    '"$_RECORD_COMMIT"' "history txn aborted" >/dev/null 2>&1
    exit 3
  ' 2>/dev/null || exit_code=$?

  assert_eq "the command's own exit status survives the rollback" "$exit_code" "3"
  assert_not_contains "the aborted commit is gone" "$(get_commit_message 'all()')" \
    "history txn aborted"
  assert_history_count "no in-progress entry left behind" 0
}

test__history__transaction__successful_exit_rolls_back() {
  setup_workspace "history-exit-zero"

  local exit_code=0
  # Exiting zero without committing the transaction is a bug in the command,
  # and leaving the entry open would lock every later command out.
  run_command "$REPO" '
    _history__begin_transaction "$1"
    '"$_RECORD_COMMIT"' "history txn never committed" >/dev/null 2>&1
    exit 0
  ' 2>/dev/null || exit_code=$?

  assert_success "a zero exit stays zero" "$exit_code"
  assert_not_contains "the uncommitted work is rolled back" \
    "$(get_commit_message 'all()')" "history txn never committed"
  assert_history_count "no in-progress entry left behind" 0
}

test__history__transaction__set_e_failure_rolls_back_once() {
  setup_workspace "history-set-e"

  local err_file="$_TEST_ROOT/set-e-stderr.txt"
  local exit_code=0
  # A failing command fires ERR and then EXIT: the handler must disarm both so
  # that the rollback runs exactly once.
  run_command "$REPO" '
    _history__begin_transaction "$1"
    '"$_RECORD_COMMIT"' "history txn set e" >/dev/null 2>&1
    false
    echo "unreachable"
  ' >/dev/null 2>"$err_file" || exit_code=$?

  assert_failure "the failure status survives the rollback" "$exit_code"
  assert_not_contains "the work of the failed run is rolled back" \
    "$(get_commit_message 'all()')" "history txn set e"
  assert_history_count "no in-progress entry left behind" 0
  assert_eq "rolled back exactly once" \
    "$(grep -c 'Rolling back transaction' "$err_file" || true)" "1"
}

test__history__transaction__commit_disarms_the_abort_trap() {
  setup_workspace "history-commit-disarm"

  local exit_code=0
  # Whatever happens after the commit, the committed work stands: the
  # transaction is closed and no longer has anything to roll back.
  run_command "$REPO" '
    _history__begin_transaction "$1"
    '"$_RECORD_COMMIT"' "history txn kept" >/dev/null 2>&1
    _history__commit_transaction "$1"
    exit 4
  ' 2>/dev/null || exit_code=$?

  assert_eq "the later failure status is reported" "$exit_code" "4"
  assert_contains "committed work survives" "$(get_commit_message 'all()')" \
    "history txn kept"
  assert_history_count "the completed entry stands" 1
}

test__history__transaction__begin_snapshots_working_copy() {
  setup_workspace "history-snapshot"

  # Capture the op ID BEFORE creating the pending file: the harness helper
  # itself snapshots the working copy, so calling it with the file already on
  # disk would fold the file into a snapshot op of its own.
  local before_op
  before_op="$(get_jj_op)"
  # A file jj has never snapshotted: only the transaction's own snapshot can
  # capture it into the working-copy commit.
  edit_file "$REPO/pending.txt" "pending"

  (
    unset TT_TRANSACTION_ID
    _history__begin_transaction "$REPO"
    # The before-op ID must be recorded ahead of the snapshot, so that
    # undoing the transaction also reverts the snapshot operation.
    get_history_lines
    assert_eq "before-op recorded is the pre-snapshot op" \
      "$(history_before_op "${HISTORY_LINES[${#HISTORY_LINES[@]}-1]}")" \
      "$before_op"
    assert_neq "snapshot advanced the op log inside the transaction" \
      "$(get_jj_op)" "$before_op"
    assert_contains "pending file captured in the working-copy commit" \
      "$(jj -R "$REPO" --ignore-working-copy diff -r '@' --name-only 2>/dev/null)" \
      "pending.txt"
    _history__rollback_transaction "$REPO" 2>/dev/null
  )

  # Rollback restores the pre-transaction state, but the user's uncommitted
  # work survives: the file stays on disk (re-applied onto the restored
  # working-copy commit rather than stripped by the operation restore).
  assert_file_exists "pending file still on disk after rollback" "$REPO/pending.txt"
  assert_eq "pending content intact after rollback" \
    "$(cat "$REPO/pending.txt")" "pending"
  assert_history_count "in-progress line removed by rollback" 0
}

test__history__transaction__nested_begin_is_noop() {
  setup_workspace "history-nested"

  local exit_code=0
  ( export TT_TRANSACTION_ID="already-set"; _history__begin_transaction "$REPO" ) || exit_code=$?
  assert_success "nested begin returns 0" "$exit_code"
  assert_history_count "nested begin appends no entry" 0
}

test__history__transaction__nested_exit_leaves_the_parent_running() {
  setup_workspace "history-nested-exit"
  write_subcommand

  local exit_code=0
  # A sub-command runs to completion and exits. Its own begin is a no-op and it
  # owns nothing, so its exit must neither roll the parent's transaction back
  # nor close its entry.
  run_command "$REPO" '
    _history__begin_transaction "$1"
    '"$_RECORD_COMMIT"' "history txn parent work" >/dev/null 2>&1
    "$TT_TEST_SUBCOMMAND" "$1" 0
    _history__commit_transaction "$1"
  ' 2>/dev/null || exit_code=$?

  assert_success "the run completes" "$exit_code"
  assert_contains "work done before the sub-command survives" \
    "$(get_commit_message 'all()')" "history txn parent work"
  assert_history_count "one completed entry for the whole run" 1
  assert_history_integrity "history after a nested sub-command"
}

test__history__transaction__work_after_the_commit_is_recorded_separately() {
  setup_workspace "history-after-commit"
  write_subcommand

  local exit_code=0
  # A command that keeps working past its own commit — as a check-in does when
  # it propagates to the siblings — must not leave its sub-commands believing
  # they are nested: their work needs a transaction of its own.
  run_command "$REPO" '
    _history__begin_transaction "$1"
    '"$_RECORD_COMMIT"' "history txn committed work" >/dev/null 2>&1
    _history__commit_transaction "$1"
    "$TT_TEST_SUBCOMMAND" "$1" 0
  ' 2>/dev/null || exit_code=$?

  assert_success "the run completes" "$exit_code"
  assert_history_count "the sub-command recorded a transaction of its own" 2
  assert_history_integrity "history after post-commit sub-command work"
}

test__history__transaction__failure_after_the_commit_unwinds_only_the_later_work() {
  setup_workspace "history-after-commit-failure"
  write_subcommand

  local exit_code=0
  run_command "$REPO" '
    _history__begin_transaction "$1"
    '"$_RECORD_COMMIT"' "history txn committed work" >/dev/null 2>&1
    _history__commit_transaction "$1"
    "$TT_TEST_SUBCOMMAND" "$1" 1
  ' 2>/dev/null || exit_code=$?

  assert_failure "the sub-command's failure is reported" "$exit_code"
  assert_contains "work committed before it still stands" \
    "$(get_commit_message 'all()')" "history txn committed work"
  assert_history_count "the committed transaction survives alone" 1
  assert_no_pending_transaction "the sub-command left no open transaction"
}

test__history__transaction__nested_failure_rolls_the_parent_back_once() {
  setup_workspace "history-nested-failure"
  write_subcommand

  local err_file="$_TEST_ROOT/nested-stderr.txt"
  local exit_code=0
  # The sub-command fails after the owner has written. It can roll nothing back
  # itself, so the failure travels up and the owner rolls back, once.
  run_command "$REPO" '
    _history__begin_transaction "$1"
    '"$_RECORD_COMMIT"' "history txn nested work" >/dev/null 2>&1
    "$TT_TEST_SUBCOMMAND" "$1" 1
    _history__commit_transaction "$1"
  ' >/dev/null 2>"$err_file" || exit_code=$?

  assert_failure "the sub-command's failure is fatal to the run" "$exit_code"
  assert_not_contains "the work of the failed run is rolled back" \
    "$(get_commit_message 'all()')" "history txn nested work"
  assert_history_count "no in-progress entry left behind" 0
  assert_eq "rolled back exactly once" \
    "$(grep -c 'Rolling back transaction' "$err_file" || true)" "1"
}

# ---------------------------------------------------------------------------
# A rollback whose restore fails
# ---------------------------------------------------------------------------

# Body fragment: make the invoking workspace stale from inside a command, by
# snapshotting a marker file and then bare-rewriting it back out of the
# working-copy commit. A bare rewrite leaves the files on disk untouched, so
# they no longer match the commit and every command that loads the working
# copy is refused -- `op restore` among them.
_GO_STALE='
  printf x > "$1/.tt-stale-marker"
  jj -R "$1" log -r @ --no-graph -T "" >/dev/null 2>&1
  jj -R "$1" --ignore-working-copy restore --from "root()" --into "@" \
    .tt-stale-marker >/dev/null 2>&1
'

test__history__transaction__failed_restore_keeps_the_entry() {
  setup_workspace "history-restore-fails"

  local output exit_code=0
  output="$(run_command "$REPO" '
    _history__begin_transaction "$1"
    '"$_RECORD_COMMIT"' "history txn unrestorable" >/dev/null 2>&1
    '"$_GO_STALE"'
    exit 3
  ' 2>&1)" || exit_code=$?

  assert_eq "the command's own exit status is unaffected" "$exit_code" "3"

  # The entry survives as a lock, rather than being deleted as it is when the
  # restore succeeds.
  assert_history_count "the in-progress entry is kept" 1
  get_history_lines
  assert_eq "the kept entry is still in progress (no after-op)" \
    "$(history_after_op "${HISTORY_LINES[0]}")" ""

  assert_contains "the failure is reported as an error, not a warning" "$output" \
    "Error: Could not restore the VCS operation state."
  assert_contains "the report says the repository was left mid-transaction" "$output" \
    "left mid-transaction at operation"
  assert_contains "the report carries the full operation ID" "$output" \
    "$(history_before_op "${HISTORY_LINES[0]}")"
  assert_contains "the report says the transaction is still recorded" "$output" \
    "the next tt command will refuse"
  assert_contains "the report offers the retry route" "$output" \
    "tt history undo --force"
  assert_contains "the report offers the manual-recovery route" "$output" \
    "tt history unlock --force"
}

test__history__transaction__failed_restore_locks_the_next_command() {
  setup_workspace "history-restore-lock"

  run_command "$REPO" '
    _history__begin_transaction "$1"
    '"$_RECORD_COMMIT"' "history txn unrestorable" >/dev/null 2>&1
    '"$_GO_STALE"'
    exit 3
  ' >/dev/null 2>&1 || true

  assert_history_count "the lock is in place" 1

  # Recover the workspace so the next command fails on the lock rather than on
  # the staleness that caused it.
  run_tt worktree refresh --root --force >/dev/null 2>&1

  local output exit_code=0
  output="$(run_tt task create --project --slug "blocked" --title "Blocked" <<< "" 2>&1)" || exit_code=$?
  assert_failure "the next command refuses" "$exit_code"
  assert_contains "it refuses because of the kept entry" "$output" \
    "Another tt command is in progress"
}

run_tests "tt lib/history (unit)"
