#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


# Usage: in_transaction KEY COMMAND...
# Runs COMMAND with TT_TRANSACTION_ID exported as KEY, as a user does after
# `export TT_TRANSACTION_ID="$(tt lock)"`.
in_transaction() {
  local key="$1"; shift
  ( export TT_TRANSACTION_ID="$key"; "$@" )
}

# Usage: open_transaction
# Runs `tt history lock` and prints the key it returns.
open_transaction() {
  run_tt history lock 2>/dev/null
}


test_history_lock__prints_key_and_records_entry() {
  setup_workspace "lock-basic"
  create_project "proj" "Project" >/dev/null 2>&1
  local count_before op_before
  get_history_lines
  count_before="${#HISTORY_LINES[@]}"
  op_before="$(get_jj_op)"

  local key exit_code=0
  key="$(run_tt history lock 2>/dev/null)" || exit_code=$?
  assert_success "lock succeeds" "$exit_code"
  assert_eq "the key is the operation before the lock" "$key" "$op_before"

  get_history_lines
  assert_eq "one entry appended" "${#HISTORY_LINES[@]}" "$(( count_before + 1 ))"
  assert_eq "the entry is in progress under the key" \
    "${HISTORY_LINES[${#HISTORY_LINES[@]}-1]}" "${key}:"
  assert_file_not_exists "the history lock is released" "$REPO/.tt/history.lock"
}


test_history_lock__reports_how_to_close() {
  setup_workspace "lock-hint"

  local output exit_code=0
  output="$(run_tt history lock 2>&1 >/dev/null)" || exit_code=$?
  assert_success "lock succeeds" "$exit_code"
  assert_contains "hint: export the key" "$output" "export TT_TRANSACTION_ID="
  assert_contains "hint: commit" "$output" "tt history unlock --key"
  assert_contains "hint: revert" "$output" "tt history undo --key"
}


test_history_lock__refuses_inside_transaction() {
  setup_workspace "lock-nested"

  local output exit_code=0
  output="$(in_transaction "some-op" run_tt history lock 2>&1)" || exit_code=$?
  assert_failure "lock refuses" "$exit_code"
  assert_contains "error names the open transaction" "$output" \
    "Error: Already inside a transaction (TT_TRANSACTION_ID is set)."
  assert_history_count "no entry appended" 0
}


test_history_lock__refuses_while_transaction_in_progress() {
  setup_workspace "lock-in-progress"
  open_transaction >/dev/null

  local output exit_code=0
  output="$(run_tt history lock 2>&1)" || exit_code=$?
  assert_failure "a second lock refuses" "$exit_code"
  assert_contains "error names the in-progress transaction" "$output" \
    "Error: Another tt command is in progress (incomplete transaction)."
  assert_history_count "no second entry appended" 1
}


test_history_lock__refuses_stale_canonical() {
  setup_workspace "lock-stale-canonical"
  setup_stale_canonical "locked"
  assert_refuses_stale_canonical "$STALE_WORKTREE" history lock
}


test_history_lock__snapshots_working_copy() {
  setup_workspace "lock-snapshot"
  edit_file "pending.txt" "pending"

  local key
  key="$(open_transaction)"
  run_tt history undo --key "$key" >/dev/null 2>&1

  # The snapshot falls inside the transaction, so reverting it leaves the
  # file uncaptured: on disk, but absent from the working-copy commit.
  assert_file_exists "the file is still on disk" "$REPO/pending.txt"
  assert_not_contains "the snapshot was reverted" \
    "$(jj -R "$REPO" --ignore-working-copy diff -r @ --name-only 2>/dev/null)" "pending.txt"
}


test_history_lock__command_without_key_is_refused() {
  setup_workspace "lock-blocks"
  open_transaction >/dev/null

  local output exit_code=0
  output="$(run_tt task create --project --slug "blocked" --title "Blocked" <<< "" 2>&1)" || exit_code=$?
  assert_failure "the command refuses" "$exit_code"
  assert_contains "it refuses because of the open transaction" "$output" \
    "Another tt command is in progress"
}


test_history_lock__command_with_wrong_key_is_refused() {
  setup_workspace "lock-wrong-key"
  open_transaction >/dev/null

  local output exit_code=0
  output="$(in_transaction "not-the-key" \
    run_tt task create --project --slug "blocked" --title "Blocked" <<< "" 2>&1)" || exit_code=$?
  assert_failure "the command refuses" "$exit_code"
  assert_contains "it reports the mismatch" "$output" \
    "Error: TT_TRANSACTION_ID does not match the transaction in progress."
  assert_bookmark_not_exists "nothing was created" "project/blocked"
}


test_history_lock__unlock_key_commits_joined_commands() {
  setup_workspace "lock-commit"

  local key proj_id task_id
  key="$(open_transaction)"
  proj_id="$(in_transaction "$key" create_project "proj" "Project")"
  task_id="$(in_transaction "$key" create_task_under "$proj_id" "t" "T")"
  assert_bookmark_exists "the project was created" "$proj_id"
  assert_bookmark_exists "the task was created" "$task_id"

  get_history_lines
  assert_eq "the joined commands add no entries" "${#HISTORY_LINES[@]}" "1"
  assert_eq "the entry is still in progress" "${HISTORY_LINES[0]}" "${key}:"

  local exit_code=0
  run_tt history unlock --key "$key" >/dev/null 2>&1 || exit_code=$?
  assert_success "unlock --key succeeds" "$exit_code"
  get_history_lines
  assert_eq "one entry recorded for the whole transaction" "${#HISTORY_LINES[@]}" "1"
  assert_eq "the entry starts at the key" "$(history_before_op "${HISTORY_LINES[0]}")" "$key"
  assert_history_integrity "the history is complete and current"

  # The transaction is one history entry, so one undo reverts all of it.
  run_tt history undo >/dev/null 2>&1
  assert_bookmark_not_exists "undo removes the project" "$proj_id"
  assert_bookmark_not_exists "undo removes the task" "$task_id"
}


test_history_lock__undo_key_reverts_joined_commands() {
  setup_workspace "lock-revert"
  local base_id
  base_id="$(create_project "base" "Base")"

  local key proj_id
  key="$(open_transaction)"
  proj_id="$(in_transaction "$key" create_project "proj" "Project")"
  assert_bookmark_exists "the project was created" "$proj_id"

  local exit_code=0
  run_tt history undo --key "$key" >/dev/null 2>&1 || exit_code=$?
  assert_success "undo --key succeeds" "$exit_code"
  assert_bookmark_not_exists "the joined command is reverted" "$proj_id"
  assert_bookmark_exists "work before the lock is kept" "$base_id"
  assert_history_count "the transaction entry is removed" 1
  assert_history_integrity "the history is complete and current"
}


test_history_lock__aliases() {
  setup_workspace "lock-alias"

  local key exit_code=0
  key="$(run_tt lock 2>/dev/null)" || exit_code=$?
  assert_success "tt lock succeeds" "$exit_code"
  assert_history_count "tt lock opens a transaction" 1

  exit_code=0
  run_tt unlock --key "$key" >/dev/null 2>&1 || exit_code=$?
  assert_success "tt unlock --key succeeds" "$exit_code"
  assert_no_pending_transaction "tt unlock --key commits the transaction"
}


test_history_lock__help() {
  setup_workspace "lock-help"
  local output="" exit_code=0
  output=$(run_tt history lock --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt history lock"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt history lock"
