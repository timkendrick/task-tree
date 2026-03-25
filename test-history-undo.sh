#!/usr/bin/env bash
#
# Comprehensive test suite for `tt history undo`
#
# Creates a fresh jj repo + tt workspace in a temp directory, then runs
# a battery of test scenarios exercising tt task undo across realistic
# workflows. Each scenario is self-contained: it records the commands
# that lead to a failure, then continues to the next scenario.
#
# Usage:
#   ./test-history-undo.sh               # run all tests
#   ./test-history-undo.sh 2 12 30       # run only tests 2, 12, and 30
#   ./test-history-undo.sh 5-10          # run tests 5 through 10
#   ./test-history-undo.sh 1 5-8 30      # mix of individual and ranges
#   ./test-history-undo.sh --list        # list available tests
#
# Output:
#   - PASS / FAIL for each scenario
#   - On failure: the exact sequence of commands that failed
#   - Summary at end
#
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
REAL_REPO="$(cd "$(dirname "$0")" && pwd)"
TT="$REAL_REPO/scripts/cli/tt"

# ── Temp dir for all test workspaces ─────────────────────────────────────────
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
echo "Test root: $TEST_ROOT"

# ── Counters ─────────────────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -a FAILURES=()

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────

log_header() {
  printf '\n%b══════════════════════════════════════════════════════════════%b\n' "$CYAN" "$RESET"
  printf '%b  %s%b\n' "$BOLD" "$1" "$RESET"
  printf '%b══════════════════════════════════════════════════════════════%b\n' "$CYAN" "$RESET"
}

log_pass() {
  printf '%b  ✓ PASS: %s%b\n' "$GREEN" "$1" "$RESET"
  PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
  local scenario="$1"
  shift
  printf '%b  ✗ FAIL: %s%b\n' "$RED" "$scenario" "$RESET"
  printf '%b    Reason: %s%b\n' "$RED" "$*" "$RESET"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILURES+=("$scenario: $*")
}

log_skip() {
  printf '%b  ⊘ SKIP: %s%b\n' "$YELLOW" "$1" "$RESET"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

log_info() {
  printf '    %s\n' "$*"
}

# Create a fresh jj repo + tt workspace for a test scenario.
# Sets REPO, VIRTUAL, and changes CWD to REPO.
# Usage: setup_workspace "scenario-name"
setup_workspace() {
  local name="$1"
  REPO="$TEST_ROOT/$name/repo"
  VIRTUAL="$TEST_ROOT/$name/virtual"
  mkdir -p "$REPO"

  # Initialize jj repo
  jj git init "$REPO" 2>/dev/null
  cd "$REPO"

  # Create an initial commit so we have a non-empty repo
  echo "initial" > README.md
  jj -R "$REPO" commit -m "Initial commit" 2>/dev/null
  jj -R "$REPO" bookmark set main 2>/dev/null

  # Initialize tt workspace
  "$TT" workspace init "$REPO" "$VIRTUAL" 2>/dev/null
}

# Get current jj operation ID
get_jj_op() {
  jj -R "$REPO" op log --no-graph -T id -n 1 2>/dev/null
}

# Get the number of lines in the history file
history_line_count() {
  local hf="$REPO/.tt/history"
  if [[ -f "$hf" && -s "$hf" ]]; then
    wc -l < "$hf" | tr -d ' '
  else
    echo 0
  fi
}

# Read the last line of the history file
history_last_line() {
  local hf="$REPO/.tt/history"
  if [[ -f "$hf" && -s "$hf" ]]; then
    tail -n 1 "$hf"
  else
    echo ""
  fi
}

# Parse before-op from a history line
history_before_op() {
  echo "${1%%:*}"
}

# Parse after-op from a history line
history_after_op() {
  echo "${1#*:}"
}

# Read all history lines into an array
read_history() {
  local hf="$REPO/.tt/history"
  HISTORY_LINES=()
  if [[ -f "$hf" && -s "$hf" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && HISTORY_LINES+=("$line")
    done < "$hf"
  fi
}

# Verify history integrity: each entry's after-op should be the next entry's before-op,
# and the last after-op should match the current jj op.
verify_history_integrity() {
  local label="$1"
  read_history
  local current_op
  current_op="$(get_jj_op)"

  local count=${#HISTORY_LINES[@]}
  if [[ $count -eq 0 ]]; then
    # Empty history: nothing to check (current op can be anything)
    return 0
  fi

  # Check chain: entry[j].after == entry[j+1].before
  local j
  for ((j=0; j < count - 1; j++)); do
    local this_after next_before
    this_after="$(history_after_op "${HISTORY_LINES[$j]}")"
    next_before="$(history_before_op "${HISTORY_LINES[$((j+1))]}")"
    if [[ "$this_after" != "$next_before" ]]; then
      log_fail "$label" "History chain broken at entry $j: after-op ($this_after) != next before-op ($next_before)"
      return 1
    fi
  done

  # Check last after-op matches current jj op
  local last_after
  last_after="$(history_after_op "${HISTORY_LINES[$((count-1))]}")"
  if [[ -z "$last_after" ]]; then
    log_fail "$label" "Last history entry has empty after-op (in-progress transaction?)"
    return 1
  fi
  if [[ "$last_after" != "$current_op" ]]; then
    log_fail "$label" "Last after-op (${last_after:0:12}) != current jj op (${current_op:0:12})"
    return 1
  fi

  return 0
}

# Run a tt command, capturing output. Suppresses the jj operation ID log.
# Returns the exit code of the tt command.
run_tt() {
  local output exit_code=0
  output=$("$TT" "$@" 2>&1) || exit_code=$?
  # Filter out the "jj operation ID before command:" log line for cleaner output
  echo "$output" | grep -v "^jj operation ID before command:" || true
  return $exit_code
}

# Create a task (non-interactive) and return its ID
create_task() {
  local slug="$1"
  local title="$2"
  shift 2
  local output
  output=$(run_tt task create --slug "$slug" --title "$title" "$@" <<< "Task body for $title" 2>&1) || {
    echo "FAILED: tt task create --slug $slug --title '$title' $*" >&2
    echo "$output" >&2
    return 1
  }
  # The last line of output should be the task ID
  echo "$output" | tail -1
}

# Record a command sequence for failure reporting
declare -a CMD_LOG=()
cmd_log_reset() { CMD_LOG=(); }
cmd_log_add() { CMD_LOG+=("$*"); }
cmd_log_dump() {
  printf '    Command sequence:\n'
  for cmd in "${CMD_LOG[@]}"; do
    printf '      %s\n' "$cmd"
  done
}


# ══════════════════════════════════════════════════════════════════════════════
# TEST SCENARIOS
# ══════════════════════════════════════════════════════════════════════════════

# ── Scenario 1: Basic checkpoint + undo ──────────────────────────────────────
test_basic_checkpoint_undo() {
  local scenario="1: Basic checkpoint + undo"
  log_header "$scenario"
  setup_workspace "s01"
  cmd_log_reset

  # Create a project and task
  cmd_log_add "tt task create --project --slug proj1 --title 'Project 1'"
  local proj_id
  proj_id=$(create_task "proj1" "Project 1" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }
  log_info "Created project: $proj_id"

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Checkout project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task create --slug task1 --title 'Task 1'"
  local task_id
  task_id=$(create_task "task1" "Task 1" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create task failed"; cmd_log_dump; return; }
  log_info "Created task: $task_id"

  # Record state before checkpoint
  local op_before_checkpoint
  op_before_checkpoint="$(get_jj_op)"
  local history_count_before
  history_count_before=$(history_line_count)

  # Do a checkpoint
  cmd_log_add "tt task checkpoint -m 'First checkpoint'"
  run_tt task checkpoint -m "First checkpoint" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Checkpoint failed"; cmd_log_dump; return; }
  log_info "Checkpoint done"

  local history_count_after
  history_count_after=$(history_line_count)

  # Verify history grew by 1
  if [[ $((history_count_after - history_count_before)) -ne 1 ]]; then
    log_fail "$scenario" "History didn't grow by 1 after checkpoint (was $history_count_before, now $history_count_after)"
    cmd_log_dump
    return
  fi

  # Verify history integrity
  if ! verify_history_integrity "$scenario (post-checkpoint)"; then
    cmd_log_dump
    return
  fi

  # Undo the checkpoint
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo failed"; cmd_log_dump; return; }
  log_info "Undo done"

  # Verify op was restored
  local op_after_undo
  op_after_undo="$(get_jj_op)"

  # History should be back to previous count (entry was popped)
  local history_count_final
  history_count_final=$(history_line_count)
  if [[ $history_count_final -ne $history_count_before ]]; then
    log_fail "$scenario" "History count after undo ($history_count_final) != before checkpoint ($history_count_before)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 2: Multiple checkpoints + multiple undos ────────────────────────
test_multiple_checkpoints_undos() {
  local scenario="2: Multiple checkpoints + multiple undos"
  log_header "$scenario"
  setup_workspace "s02"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj2 --title 'Project 2'"
  local proj_id
  proj_id=$(create_task "proj2" "Project 2" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug task2 --title 'Task 2' --checkout"
  local task_id
  task_id=$(create_task "task2" "Task 2" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create task failed"; cmd_log_dump; return; }

  # Record operations at each step
  local -a ops_at_step=()
  ops_at_step+=("$(get_jj_op)")

  # 3 checkpoints
  for _ci in 1 2 3; do
    cmd_log_add "tt task checkpoint -m 'Checkpoint $_ci'"
    run_tt task checkpoint -m "Checkpoint $_ci" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Checkpoint $_ci failed"; cmd_log_dump; return; }
    ops_at_step+=("$(get_jj_op)")
  done

  if ! verify_history_integrity "$scenario (post-3-checkpoints)"; then
    cmd_log_dump
    return
  fi

  # Undo all 3
  for _ci in 3 2 1; do
    cmd_log_add "tt undo"
    run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo #$_ci failed"; cmd_log_dump; return; }
    log_info "Undo #$((4-_ci)) done"
  done

  # Verify we have the right history count (should still have entries from create + checkout)
  if ! verify_history_integrity "$scenario (post-3-undos)"; then
    # History might be empty at this point — that's OK too
    local hc
    hc=$(history_line_count)
    if [[ $hc -gt 0 ]]; then
      cmd_log_dump
      return
    fi
  fi

  log_pass "$scenario"
}

# ── Scenario 3: Undo task create ─────────────────────────────────────────────
test_undo_task_create() {
  local scenario="3: Undo task create"
  log_header "$scenario"
  setup_workspace "s03"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj3 --title 'Project 3'"
  local proj_id
  proj_id=$(create_task "proj3" "Project 3" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (pre-create)"; then
    cmd_log_dump
    return
  fi

  local op_before_create
  op_before_create="$(get_jj_op)"
  local hc_before
  hc_before=$(history_line_count)

  # Create a child task (without --checkout)
  cmd_log_add "tt task create --slug child3 --title 'Child 3'"
  local child_id
  child_id=$(create_task "child3" "Child 3" --repo "$REPO") || { log_fail "$scenario" "Create child task failed"; cmd_log_dump; return; }
  log_info "Created child: $child_id"

  if ! verify_history_integrity "$scenario (post-create)"; then
    cmd_log_dump
    return
  fi

  # Verify child bookmark exists
  if ! jj -R "$REPO" log -r "$child_id" --no-graph -T '' 2>/dev/null; then
    log_fail "$scenario" "Child bookmark not found after create"
    cmd_log_dump
    return
  fi

  # Undo the create
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo create failed"; cmd_log_dump; return; }
  log_info "Undo done"

  # Verify child bookmark no longer exists
  if jj -R "$REPO" log -r "$child_id" --no-graph -T '' 2>/dev/null; then
    log_fail "$scenario" "Child bookmark still exists after undo"
    cmd_log_dump
    return
  fi

  local hc_after
  hc_after=$(history_line_count)
  if [[ $hc_after -ne $hc_before ]]; then
    log_fail "$scenario" "History count after undo ($hc_after) != before create ($hc_before)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 4: Undo checkout (begin task) ───────────────────────────────────
test_undo_checkout() {
  local scenario="4: Undo checkout (begin task)"
  log_header "$scenario"
  setup_workspace "s04"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj4 --title 'Project 4'"
  local proj_id
  proj_id=$(create_task "proj4" "Project 4" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child4 --title 'Child 4'"
  local child_id
  child_id=$(create_task "child4" "Child 4" --repo "$REPO") || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (pre-checkout)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Checkout the child task
  cmd_log_add "tt task checkout $child_id"
  run_tt task checkout "$child_id" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Checkout child failed"; cmd_log_dump; return; }
  log_info "Checked out child"

  if ! verify_history_integrity "$scenario (post-checkout)"; then
    cmd_log_dump
    return
  fi

  # Undo the checkout
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo checkout failed"; cmd_log_dump; return; }
  log_info "Undo done"

  local hc_after
  hc_after=$(history_line_count)
  if [[ $hc_after -ne $hc_before ]]; then
    log_fail "$scenario" "History count mismatch after undo checkout ($hc_after != $hc_before)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 5: Undo complete ────────────────────────────────────────────────
test_undo_complete() {
  local scenario="5: Undo complete"
  log_header "$scenario"
  setup_workspace "s05"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj5 --title 'Project 5'"
  local proj_id
  proj_id=$(create_task "proj5" "Project 5" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child5 --title 'Child 5' --checkout"
  local child_id
  child_id=$(create_task "child5" "Child 5" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkpoint -m 'Work done'"
  run_tt task checkpoint -m "Work done" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (pre-complete)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Complete the task
  cmd_log_add "tt task complete"
  run_tt task complete --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Complete failed"; cmd_log_dump; return; }
  log_info "Complete done"

  if ! verify_history_integrity "$scenario (post-complete)"; then
    cmd_log_dump
    return
  fi

  # Undo the complete
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo complete failed"; cmd_log_dump; return; }
  log_info "Undo done"

  local hc_after
  hc_after=$(history_line_count)
  if [[ $hc_after -ne $hc_before ]]; then
    log_fail "$scenario" "History count mismatch ($hc_after != $hc_before)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 6: Undo checkin ─────────────────────────────────────────────────
test_undo_checkin() {
  local scenario="6: Undo checkin"
  log_header "$scenario"
  setup_workspace "s06"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj6 --title 'Project 6'"
  local proj_id
  proj_id=$(create_task "proj6" "Project 6" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child6 --title 'Child 6' --checkout"
  local child_id
  child_id=$(create_task "child6" "Child 6" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkpoint -m 'Work done'"
  run_tt task checkpoint -m "Work done" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task complete"
  run_tt task complete --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (pre-checkin)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Checkin the completed task
  cmd_log_add "tt task checkin $child_id"
  run_tt task checkin "$child_id" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Checkin failed"; cmd_log_dump; return; }
  log_info "Checkin done"

  if ! verify_history_integrity "$scenario (post-checkin)"; then
    cmd_log_dump
    return
  fi

  # Undo the checkin
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo checkin failed"; cmd_log_dump; return; }
  log_info "Undo done"

  local hc_after
  hc_after=$(history_line_count)
  if [[ $hc_after -ne $hc_before ]]; then
    log_fail "$scenario" "History count mismatch ($hc_after != $hc_before)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 7: Undo with --force when op ID mismatches ─────────────────────
test_undo_force_op_mismatch() {
  local scenario="7: Undo --force when op ID mismatches"
  log_header "$scenario"
  setup_workspace "s07"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj7 --title 'Project 7'"
  local proj_id
  proj_id=$(create_task "proj7" "Project 7" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkpoint -m 'Some work'"
  run_tt task checkpoint -m "Some work" --repo "$REPO" >/dev/null 2>&1

  # Modify repo outside of tt (creates a new jj op that doesn't match history)
  cmd_log_add "echo 'extra' > README.md && jj commit -m 'External change'"
  echo "extra" > "$REPO/README.md"
  jj -R "$REPO" commit -m "External change" 2>/dev/null

  # Normal undo should fail
  cmd_log_add "tt undo (expecting failure)"
  if run_tt undo --repo "$REPO" >/dev/null 2>&1; then
    log_fail "$scenario" "Undo should have failed due to op ID mismatch"
    cmd_log_dump
    return
  fi
  log_info "Normal undo correctly rejected"

  # Force undo should succeed
  cmd_log_add "tt undo --force"
  run_tt undo --force --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Force undo failed"; cmd_log_dump; return; }
  log_info "Force undo succeeded"

  log_pass "$scenario"
}

# ── Scenario 8: Undo with dirty working copy ────────────────────────────────
test_undo_dirty_wc() {
  local scenario="8: Undo with dirty working copy"
  log_header "$scenario"
  setup_workspace "s08"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj8 --title 'Project 8'"
  local proj_id
  proj_id=$(create_task "proj8" "Project 8" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkpoint -m 'Checkpoint'"
  run_tt task checkpoint -m "Checkpoint" --repo "$REPO" >/dev/null 2>&1

  # Dirty the working copy
  cmd_log_add "echo 'dirty' > dirty.txt"
  echo "dirty" > "$REPO/dirty.txt"

  # Normal undo should fail (dirty WC)
  cmd_log_add "tt undo (expecting failure - dirty WC)"
  if run_tt undo --repo "$REPO" >/dev/null 2>&1; then
    log_fail "$scenario" "Undo should have failed due to dirty WC"
    cmd_log_dump
    return
  fi
  log_info "Normal undo correctly rejected for dirty WC"

  # Force undo should succeed
  cmd_log_add "tt undo --force"
  run_tt undo --force --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Force undo failed"; cmd_log_dump; return; }
  log_info "Force undo succeeded"

  log_pass "$scenario"
}

# ── Scenario 9: Undo on empty history ────────────────────────────────────────
test_undo_empty_history() {
  local scenario="9: Undo on empty history"
  log_header "$scenario"
  setup_workspace "s09"
  cmd_log_reset

  # History should be empty right after workspace init (or at least contain only non-tt ops)
  # Truncate history to simulate fresh
  : > "$REPO/.tt/history"

  cmd_log_add "tt undo (expecting failure - empty history)"
  if run_tt undo --repo "$REPO" >/dev/null 2>&1; then
    log_fail "$scenario" "Undo should have failed on empty history"
    cmd_log_dump
    return
  fi
  log_info "Correctly rejected undo on empty history"

  log_pass "$scenario"
}

# ── Scenario 10: Consecutive undos past all history ──────────────────────────
test_undo_past_all_history() {
  local scenario="10: Consecutive undos past all history"
  log_header "$scenario"
  setup_workspace "s10"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj10 --title 'Project 10'"
  local proj_id
  proj_id=$(create_task "proj10" "Project 10" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkpoint -m 'CP1'"
  run_tt task checkpoint -m "CP1" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkpoint -m 'CP2'"
  run_tt task checkpoint -m "CP2" --repo "$REPO" >/dev/null 2>&1

  local total_history
  total_history=$(history_line_count)
  log_info "Total history entries: $total_history"

  # Undo all entries
  local undo_count=0
  while true; do
    cmd_log_add "tt undo (iteration $((undo_count+1)))"
    if ! run_tt undo --repo "$REPO" >/dev/null 2>&1; then
      break
    fi
    undo_count=$((undo_count + 1))
    if [[ $undo_count -gt 20 ]]; then
      log_fail "$scenario" "Undo loop exceeded 20 iterations"
      cmd_log_dump
      return
    fi
  done
  log_info "Undid $undo_count operations before failure"

  # Should have emptied history
  local final_count
  final_count=$(history_line_count)
  if [[ $final_count -ne 0 ]]; then
    log_fail "$scenario" "History should be empty after all undos (has $final_count entries)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 11: create --checkout + undo ────────────────────────────────────
test_undo_create_with_checkout() {
  local scenario="11: Undo create --checkout (compound operation)"
  log_header "$scenario"
  setup_workspace "s11"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj11 --title 'Project 11'"
  local proj_id
  proj_id=$(create_task "proj11" "Project 11" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (pre-create-checkout)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Create with --checkout (compound: create + checkout in one transaction)
  cmd_log_add "tt task create --slug child11 --title 'Child 11' --checkout"
  local child_id
  child_id=$(create_task "child11" "Child 11" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create+checkout failed"; cmd_log_dump; return; }
  log_info "Created+checked out: $child_id"

  if ! verify_history_integrity "$scenario (post-create-checkout)"; then
    cmd_log_dump
    return
  fi

  # This should be ONE transaction (nested)
  local hc_after_create
  hc_after_create=$(history_line_count)
  if [[ $((hc_after_create - hc_before)) -ne 1 ]]; then
    log_fail "$scenario" "create --checkout should be 1 transaction, but got $((hc_after_create - hc_before)) new entries"
    cmd_log_dump
    return
  fi

  # Undo should revert both create and checkout in one go
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo failed"; cmd_log_dump; return; }

  # Verify the child bookmark is gone
  if jj -R "$REPO" log -r "$child_id" --no-graph -T '' 2>/dev/null; then
    log_fail "$scenario" "Child bookmark still exists after undoing create --checkout"
    cmd_log_dump
    return
  fi

  local hc_final
  hc_final=$(history_line_count)
  if [[ $hc_final -ne $hc_before ]]; then
    log_fail "$scenario" "History count mismatch ($hc_final != $hc_before)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 12: Interleaved create/checkpoint/undo ──────────────────────────
test_interleaved_create_checkpoint_undo() {
  local scenario="12: Interleaved create/checkpoint/undo"
  log_header "$scenario"
  setup_workspace "s12"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj12 --title 'Project 12'"
  local proj_id
  proj_id=$(create_task "proj12" "Project 12" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug t12a --title 'Task A' --checkout"
  local task_a
  task_a=$(create_task "t12a" "Task A" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create task A failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after create task A)"; then
    cmd_log_dump
    return
  fi

  cmd_log_add "tt task checkpoint -m 'CP-A1'"
  run_tt task checkpoint -m "CP-A1" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after CP-A1)"; then
    cmd_log_dump
    return
  fi

  cmd_log_add "tt task checkpoint -m 'CP-A2'"
  run_tt task checkpoint -m "CP-A2" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after CP-A2)"; then
    cmd_log_dump
    return
  fi

  # Undo last checkpoint
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo CP-A2 failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo CP-A2)"; then
    cmd_log_dump
    return
  fi

  # Do another checkpoint (after undoing the previous one)
  cmd_log_add "tt task checkpoint -m 'CP-A3'"
  run_tt task checkpoint -m "CP-A3" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after CP-A3)"; then
    cmd_log_dump
    return
  fi

  # Undo twice more (CP-A3 + CP-A1)
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo CP-A3 failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo CP-A3)"; then
    cmd_log_dump
    return
  fi

  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo CP-A1 failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo CP-A1)"; then
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 13: Undo after checkin --complete (compound) ────────────────────
test_undo_checkin_complete() {
  local scenario="13: Undo checkin --complete"
  log_header "$scenario"
  setup_workspace "s13"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj13 --title 'Project 13'"
  local proj_id
  proj_id=$(create_task "proj13" "Project 13" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child13 --title 'Child 13' --checkout"
  local child_id
  child_id=$(create_task "child13" "Child 13" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkpoint -m 'Do some work'"
  run_tt task checkpoint -m "Do some work" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (pre-checkin-complete)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Checkin --complete: compound (complete + checkin in one transaction)
  cmd_log_add "tt task checkin --complete $child_id"
  run_tt task checkin --complete "$child_id" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Checkin --complete failed"; cmd_log_dump; return; }
  log_info "Checkin --complete done"

  if ! verify_history_integrity "$scenario (post-checkin-complete)"; then
    cmd_log_dump
    return
  fi

  # Undo
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo failed"; cmd_log_dump; return; }
  log_info "Undo done"

  local hc_after
  hc_after=$(history_line_count)
  if [[ $hc_after -ne $hc_before ]]; then
    log_fail "$scenario" "History count mismatch ($hc_after != $hc_before)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 14: create --propagate + undo ───────────────────────────────────
test_undo_create_with_propagate() {
  local scenario="14: Undo create --propagate"
  log_header "$scenario"
  setup_workspace "s14"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj14 --title 'Project 14'"
  local proj_id
  proj_id=$(create_task "proj14" "Project 14" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  # Create first child
  cmd_log_add "tt task create --slug sibling --title 'Sibling' --checkout"
  local sibling_id
  sibling_id=$(create_task "sibling" "Sibling" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create sibling failed"; cmd_log_dump; return; }

  # Go back to parent
  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (pre-create-propagate)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Create second child with --propagate (should update sibling)
  cmd_log_add "tt task create --slug child14 --title 'Child 14' --propagate"
  local child_id
  child_id=$(create_task "child14" "Child 14" --repo "$REPO" --propagate) || { log_fail "$scenario" "Create+propagate failed"; cmd_log_dump; return; }
  log_info "Created with propagate: $child_id"

  if ! verify_history_integrity "$scenario (post-create-propagate)"; then
    cmd_log_dump
    return
  fi

  # Should be 1 transaction (create + propagate nested)
  local hc_after
  hc_after=$(history_line_count)
  if [[ $((hc_after - hc_before)) -ne 1 ]]; then
    log_fail "$scenario" "create --propagate should be 1 transaction, but got $((hc_after - hc_before)) entries"
    cmd_log_dump
    return
  fi

  # Undo
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo failed"; cmd_log_dump; return; }

  # Child should be gone
  if jj -R "$REPO" log -r "$child_id" --no-graph -T '' 2>/dev/null; then
    log_fail "$scenario" "Child bookmark still exists after undo"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 15: Undo rename ─────────────────────────────────────────────────
test_undo_rename() {
  local scenario="15: Undo rename"
  log_header "$scenario"
  setup_workspace "s15"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj15 --title 'Project 15'"
  local proj_id
  proj_id=$(create_task "proj15" "Project 15" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child15 --title 'Child 15' --checkout"
  local child_id
  child_id=$(create_task "child15" "Child 15" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (pre-rename)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Rename the task
  cmd_log_add "tt task rename --slug renamed15"
  run_tt task rename --slug "renamed15" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Rename failed"; cmd_log_dump; return; }
  log_info "Rename done"

  if ! verify_history_integrity "$scenario (post-rename)"; then
    cmd_log_dump
    return
  fi

  # Undo the rename
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo rename failed"; cmd_log_dump; return; }
  log_info "Undo done"

  local hc_after
  hc_after=$(history_line_count)
  if [[ $hc_after -ne $hc_before ]]; then
    log_fail "$scenario" "History count mismatch ($hc_after != $hc_before)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 16: Undo edit ───────────────────────────────────────────────────
test_undo_edit() {
  local scenario="16: Undo edit"
  log_header "$scenario"
  setup_workspace "s16"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj16 --title 'Project 16'"
  local proj_id
  proj_id=$(create_task "proj16" "Project 16" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child16 --title 'Child 16' --checkout"
  local child_id
  child_id=$(create_task "child16" "Child 16" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (pre-edit)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Edit the task title
  cmd_log_add "tt task edit --title 'Updated Title 16'"
  run_tt task edit --title "Updated Title 16" --repo "$REPO" <<< "Updated body" >/dev/null 2>&1 || { log_fail "$scenario" "Edit failed"; cmd_log_dump; return; }
  log_info "Edit done"

  if ! verify_history_integrity "$scenario (post-edit)"; then
    cmd_log_dump
    return
  fi

  # Undo the edit
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo edit failed"; cmd_log_dump; return; }
  log_info "Undo done"

  log_pass "$scenario"
}

# ── Scenario 17: Undo delete ─────────────────────────────────────────────────
test_undo_delete() {
  local scenario="17: Undo delete"
  log_header "$scenario"
  setup_workspace "s17"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj17 --title 'Project 17'"
  local proj_id
  proj_id=$(create_task "proj17" "Project 17" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child17 --title 'Child 17' --checkout"
  local child_id
  child_id=$(create_task "child17" "Child 17" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkpoint -m 'Work'"
  run_tt task checkpoint -m "Work" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task complete"
  run_tt task complete --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (pre-delete)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Delete the completed task
  cmd_log_add "tt task delete $child_id"
  run_tt task delete "$child_id" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Delete failed"; cmd_log_dump; return; }
  log_info "Delete done"

  if ! verify_history_integrity "$scenario (post-delete)"; then
    cmd_log_dump
    return
  fi

  # Undo the delete
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo delete failed"; cmd_log_dump; return; }
  log_info "Undo done"

  # Bookmark should be back
  if ! jj -R "$REPO" log -r "$child_id" --no-graph -T '' 2>/dev/null; then
    log_fail "$scenario" "Child bookmark not restored after undo delete"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 18: Full lifecycle: create → checkout → checkpoint → complete → checkin → undo-all ──
test_full_lifecycle_undo_all() {
  local scenario="18: Full lifecycle then undo everything"
  log_header "$scenario"
  setup_workspace "s18"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj18 --title 'Project 18'"
  local proj_id
  proj_id=$(create_task "proj18" "Project 18" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child18 --title 'Child 18'"
  local child_id
  child_id=$(create_task "child18" "Child 18" --repo "$REPO") || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $child_id"
  run_tt task checkout "$child_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkpoint -m 'Step 1'"
  run_tt task checkpoint -m "Step 1" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkpoint -m 'Step 2'"
  run_tt task checkpoint -m "Step 2" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task complete"
  run_tt task complete --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkin $child_id"
  run_tt task checkin "$child_id" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (full lifecycle done)"; then
    cmd_log_dump
    return
  fi

  local total
  total=$(history_line_count)
  log_info "Total history entries: $total"

  # Undo EVERYTHING
  local undo_count=0
  while run_tt undo --repo "$REPO" >/dev/null 2>&1; do
    undo_count=$((undo_count + 1))
    cmd_log_add "tt undo (iteration $undo_count)"
    if [[ $undo_count -gt 30 ]]; then
      log_fail "$scenario" "Undo loop exceeded 30 iterations"
      cmd_log_dump
      return
    fi
  done
  log_info "Undid $undo_count operations"

  local final_count
  final_count=$(history_line_count)
  if [[ $final_count -ne 0 ]]; then
    log_fail "$scenario" "History should be empty after all undos (has $final_count entries)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 19: Two children, interleaved work + undo ───────────────────────
test_two_children_interleaved_undo() {
  local scenario="19: Two children, interleaved work + undo"
  log_header "$scenario"
  setup_workspace "s19"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj19 --title 'Project 19'"
  local proj_id
  proj_id=$(create_task "proj19" "Project 19" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  # Create two children
  cmd_log_add "tt task create --slug child-a --title 'Child A'"
  local child_a
  child_a=$(create_task "child-a" "Child A" --repo "$REPO") || { log_fail "$scenario" "Create child A failed"; cmd_log_dump; return; }

  cmd_log_add "tt task create --slug child-b --title 'Child B'"
  local child_b
  child_b=$(create_task "child-b" "Child B" --repo "$REPO") || { log_fail "$scenario" "Create child B failed"; cmd_log_dump; return; }

  # Work on child A
  cmd_log_add "tt task checkout $child_a"
  run_tt task checkout "$child_a" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkpoint -m 'A-CP1'"
  run_tt task checkpoint -m "A-CP1" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after A-CP1)"; then
    cmd_log_dump
    return
  fi

  # Switch to child B
  cmd_log_add "tt task checkout $child_b"
  run_tt task checkout "$child_b" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkpoint -m 'B-CP1'"
  run_tt task checkpoint -m "B-CP1" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after B-CP1)"; then
    cmd_log_dump
    return
  fi

  # Undo B-CP1
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo B-CP1 failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo B-CP1)"; then
    cmd_log_dump
    return
  fi

  # Undo checkout B
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo checkout B failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo checkout B)"; then
    cmd_log_dump
    return
  fi

  # Now we should be back on child A with 1 checkpoint
  # Do another checkpoint on A
  cmd_log_add "tt task checkpoint -m 'A-CP2'"
  run_tt task checkpoint -m "A-CP2" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after A-CP2)"; then
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 20: Undo context add ───────────────────────────────────────────
test_undo_context_add() {
  local scenario="20: Undo context add"
  log_header "$scenario"
  setup_workspace "s20"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj20 --title 'Project 20'"
  local proj_id
  proj_id=$(create_task "proj20" "Project 20" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child20 --title 'Child 20' --checkout"
  local child_id
  child_id=$(create_task "child20" "Child 20" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (pre-context-add)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Add context
  cmd_log_add "tt task context add --title 'Research notes' --body 'Some research'"
  run_tt task context add --title "Research notes" --body "Some research" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Context add failed"; cmd_log_dump; return; }
  log_info "Context add done"

  if ! verify_history_integrity "$scenario (post-context-add)"; then
    cmd_log_dump
    return
  fi

  # Undo
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo context add failed"; cmd_log_dump; return; }
  log_info "Undo done"

  local hc_after
  hc_after=$(history_line_count)
  if [[ $hc_after -ne $hc_before ]]; then
    log_fail "$scenario" "History count mismatch ($hc_after != $hc_before)"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 21: Rapid consecutive undos (stress test) ───────────────────────
test_rapid_consecutive_undos() {
  local scenario="21: Rapid consecutive undos (5 checkpoints then 5 undos)"
  log_header "$scenario"
  setup_workspace "s21"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj21 --title 'Project 21'"
  local proj_id
  proj_id=$(create_task "proj21" "Project 21" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug stress --title 'Stress' --checkout"
  local task_id
  task_id=$(create_task "stress" "Stress" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create task failed"; cmd_log_dump; return; }

  # 5 checkpoints
  for _ci in $(seq 1 5); do
    cmd_log_add "tt task checkpoint -m 'CP-$_ci'"
    run_tt task checkpoint -m "CP-$_ci" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Checkpoint $_ci failed"; cmd_log_dump; return; }
  done

  if ! verify_history_integrity "$scenario (after 5 checkpoints)"; then
    cmd_log_dump
    return
  fi

  # 5 consecutive undos
  for _ci in $(seq 1 5); do
    cmd_log_add "tt undo"
    run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo #$_ci failed"; cmd_log_dump; return; }
    if ! verify_history_integrity "$scenario (after undo #$_ci)"; then
      cmd_log_dump
      return
    fi
  done

  log_pass "$scenario"
}

# ── Scenario 22: Undo after create + propagate + undo + new work ─────────────
test_undo_after_propagate_and_new_work() {
  local scenario="22: Undo/redo with propagate interleaved"
  log_header "$scenario"
  setup_workspace "s22"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj22 --title 'Project 22'"
  local proj_id
  proj_id=$(create_task "proj22" "Project 22" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  # Create child A
  cmd_log_add "tt task create --slug ch-a --title 'Child A' --checkout"
  local child_a
  child_a=$(create_task "ch-a" "Child A" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child A failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkpoint -m 'A-work'"
  run_tt task checkpoint -m "A-work" --repo "$REPO" >/dev/null 2>&1

  # Go back to project and create child B with propagate
  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug ch-b --title 'Child B' --propagate"
  local child_b
  child_b=$(create_task "ch-b" "Child B" --repo "$REPO" --propagate) || { log_fail "$scenario" "Create child B failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after create B with propagate)"; then
    cmd_log_dump
    return
  fi

  # Undo the create+propagate
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo create B failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo create B)"; then
    cmd_log_dump
    return
  fi

  # Do more work (checkpoint on A)
  cmd_log_add "tt task checkout $child_a"
  run_tt task checkout "$child_a" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkpoint -m 'A-more-work'"
  run_tt task checkpoint -m "A-more-work" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after more work on A)"; then
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 23: Undo context delete ─────────────────────────────────────────
test_undo_context_delete() {
  local scenario="23: Undo context delete"
  log_header "$scenario"
  setup_workspace "s23"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj23 --title 'Project 23'"
  local proj_id
  proj_id=$(create_task "proj23" "Project 23" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child23 --title 'Child 23' --checkout"
  local child_id
  child_id=$(create_task "child23" "Child 23" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  # Add context
  cmd_log_add "tt task context add --title 'Notes' --body 'Some notes'"
  local ctx_output
  ctx_output=$(run_tt task context add --title "Notes" --body "Some notes" --repo "$REPO" 2>&1) || { log_fail "$scenario" "Context add failed"; cmd_log_dump; return; }
  log_info "Context add output: $ctx_output"

  # Get context ID from output
  local ctx_id
  ctx_id=$(echo "$ctx_output" | grep -o 'context/[^ ]*' | head -1) || true

  if [[ -z "$ctx_id" ]]; then
    # Try to find it from the task file
    ctx_id=$(jj -R "$REPO" file show -r "$child_id" -- ".tt/task/${child_id#task/}/TASK.md" 2>/dev/null | grep '^context:' | head -1 | awk '{print $2}') || true
  fi

  if [[ -z "$ctx_id" ]]; then
    log_skip "$scenario (could not determine context ID)"
    return
  fi

  if ! verify_history_integrity "$scenario (pre-context-delete)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Delete context
  cmd_log_add "tt task context delete $ctx_id"
  run_tt task context delete "$ctx_id" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Context delete failed"; cmd_log_dump; return; }
  log_info "Context delete done"

  if ! verify_history_integrity "$scenario (post-context-delete)"; then
    cmd_log_dump
    return
  fi

  # Undo
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo context delete failed"; cmd_log_dump; return; }

  log_pass "$scenario"
}

# ── Scenario 24: Undo complete, then redo complete, then checkin ─────────────
test_undo_redo_complete_then_checkin() {
  local scenario="24: Undo complete, redo complete, then checkin"
  log_header "$scenario"
  setup_workspace "s24"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj24 --title 'Project 24'"
  local proj_id
  proj_id=$(create_task "proj24" "Project 24" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child24 --title 'Child 24' --checkout"
  local child_id
  child_id=$(create_task "child24" "Child 24" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkpoint -m 'Work'"
  run_tt task checkpoint -m "Work" --repo "$REPO" >/dev/null 2>&1

  # Complete
  cmd_log_add "tt task complete"
  run_tt task complete --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after complete)"; then
    cmd_log_dump
    return
  fi

  # Undo complete
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo complete failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo complete)"; then
    cmd_log_dump
    return
  fi

  # Re-do complete
  cmd_log_add "tt task complete"
  run_tt task complete --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Re-complete failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after re-complete)"; then
    cmd_log_dump
    return
  fi

  # Checkin
  cmd_log_add "tt task checkin $child_id"
  run_tt task checkin "$child_id" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Checkin failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after checkin)"; then
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 25: Undo the very first tt command after workspace init ─────────
test_undo_first_command() {
  local scenario="25: Undo the very first mutating tt command"
  log_header "$scenario"
  setup_workspace "s25"
  cmd_log_reset

  # The first mutating command after workspace init
  cmd_log_add "tt task create --project --slug proj25 --title 'Project 25'"
  local proj_id
  proj_id=$(create_task "proj25" "Project 25" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after first create)"; then
    cmd_log_dump
    return
  fi

  # Undo it
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo first command failed"; cmd_log_dump; return; }

  # History should now be empty
  local hc
  hc=$(history_line_count)
  if [[ $hc -ne 0 ]]; then
    log_fail "$scenario" "History should be empty after undoing first command (has $hc entries)"
    cmd_log_dump
    return
  fi

  # Verify project bookmark is gone
  if jj -R "$REPO" log -r "$proj_id" --no-graph -T '' 2>/dev/null; then
    log_fail "$scenario" "Project bookmark still exists after undo"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 26: Undo with deeply nested task tree ───────────────────────────
test_undo_deep_tree() {
  local scenario="26: Undo in deep task tree (3 levels)"
  log_header "$scenario"
  setup_workspace "s26"
  cmd_log_reset

  # Create project → child → grandchild
  cmd_log_add "tt task create --project --slug proj26 --title 'Project 26'"
  local proj_id
  proj_id=$(create_task "proj26" "Project 26" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug child26 --title 'Child 26' --checkout"
  local child_id
  child_id=$(create_task "child26" "Child 26" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create child failed"; cmd_log_dump; return; }

  cmd_log_add "tt task create --slug grandchild --title 'Grandchild' --checkout"
  local gc_id
  gc_id=$(create_task "grandchild" "Grandchild" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create grandchild failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after 3-level tree)"; then
    cmd_log_dump
    return
  fi

  # Checkpoint on grandchild
  cmd_log_add "tt task checkpoint -m 'GC work'"
  run_tt task checkpoint -m "GC work" --repo "$REPO" >/dev/null 2>&1

  # Undo checkpoint
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo GC checkpoint failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo GC checkpoint)"; then
    cmd_log_dump
    return
  fi

  # Undo create grandchild
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo create GC failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo create GC)"; then
    cmd_log_dump
    return
  fi

  # Grandchild should be gone
  if jj -R "$REPO" log -r "$gc_id" --no-graph -T '' 2>/dev/null; then
    log_fail "$scenario" "Grandchild bookmark still exists after undo"
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 27: Undo propagate standalone ───────────────────────────────────
test_undo_propagate_standalone() {
  local scenario="27: Undo standalone propagate"
  log_header "$scenario"
  setup_workspace "s27"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj27 --title 'Project 27'"
  local proj_id
  proj_id=$(create_task "proj27" "Project 27" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  # Create two children
  cmd_log_add "tt task create --slug sib-a --title 'Sibling A'"
  local sib_a
  sib_a=$(create_task "sib-a" "Sibling A" --repo "$REPO") || { log_fail "$scenario" "Create sib A failed"; cmd_log_dump; return; }

  cmd_log_add "tt task create --slug sib-b --title 'Sibling B'"
  local sib_b
  sib_b=$(create_task "sib-b" "Sibling B" --repo "$REPO") || { log_fail "$scenario" "Create sib B failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (pre-propagate)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Standalone propagate
  cmd_log_add "tt task propagate --from $proj_id"
  run_tt task propagate --from "$proj_id" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Propagate failed"; cmd_log_dump; return; }
  log_info "Propagate done"

  if ! verify_history_integrity "$scenario (post-propagate)"; then
    cmd_log_dump
    return
  fi

  # Undo propagate
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo propagate failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo propagate)"; then
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 28: Undo, then do different work, then undo that ────────────────
test_undo_diverge_undo() {
  local scenario="28: Undo, diverge, undo"
  log_header "$scenario"
  setup_workspace "s28"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj28 --title 'Project 28'"
  local proj_id
  proj_id=$(create_task "proj28" "Project 28" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug path-a --title 'Path A' --checkout"
  local path_a
  path_a=$(create_task "path-a" "Path A" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create path A failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkpoint -m 'A work 1'"
  run_tt task checkpoint -m "A work 1" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task checkpoint -m 'A work 2'"
  run_tt task checkpoint -m "A work 2" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after A work 2)"; then
    cmd_log_dump
    return
  fi

  # Undo last checkpoint
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1

  # Do different work instead
  cmd_log_add "tt task checkpoint -m 'A work 2b (diverged)'"
  run_tt task checkpoint -m "A work 2b (diverged)" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after diverged work)"; then
    cmd_log_dump
    return
  fi

  # Undo the diverged work
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo diverged work failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo diverged)"; then
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 29: Move task + undo ───────────────────────────────────────────
test_undo_move() {
  local scenario="29: Undo move"
  log_header "$scenario"
  setup_workspace "s29"
  cmd_log_reset

  cmd_log_add "tt task create --project --slug proj29 --title 'Project 29'"
  local proj_id
  proj_id=$(create_task "proj29" "Project 29" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  # Create parent A and parent B
  cmd_log_add "tt task create --slug parent-a --title 'Parent A'"
  local parent_a
  parent_a=$(create_task "parent-a" "Parent A" --repo "$REPO") || { log_fail "$scenario" "Create parent A failed"; cmd_log_dump; return; }

  cmd_log_add "tt task create --slug parent-b --title 'Parent B'"
  local parent_b
  parent_b=$(create_task "parent-b" "Parent B" --repo "$REPO") || { log_fail "$scenario" "Create parent B failed"; cmd_log_dump; return; }

  # Create a child under parent A
  cmd_log_add "tt task checkout $parent_a"
  run_tt task checkout "$parent_a" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task create --slug moveable --title 'Moveable'"
  local moveable
  moveable=$(create_task "moveable" "Moveable" --repo "$REPO") || { log_fail "$scenario" "Create moveable failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (pre-move)"; then
    cmd_log_dump
    return
  fi

  local hc_before
  hc_before=$(history_line_count)

  # Move child from parent-a to parent-b
  cmd_log_add "tt task move $moveable --to $parent_b"
  run_tt task move "$moveable" --to "$parent_b" --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Move failed"; cmd_log_dump; return; }
  log_info "Move done"

  if ! verify_history_integrity "$scenario (post-move)"; then
    cmd_log_dump
    return
  fi

  # Undo move
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1 || { log_fail "$scenario" "Undo move failed"; cmd_log_dump; return; }

  if ! verify_history_integrity "$scenario (after undo move)"; then
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}

# ── Scenario 30: Complex: create→checkout→cp→cp→undo→cp→complete→undo→undo→redo-complete→checkin→undo ──
test_complex_realistic_workflow() {
  local scenario="30: Complex realistic workflow with undos"
  log_header "$scenario"
  setup_workspace "s30"
  cmd_log_reset

  # Setup project
  cmd_log_add "tt task create --project --slug proj30 --title 'Project 30'"
  local proj_id
  proj_id=$(create_task "proj30" "Project 30" --project --repo "$REPO") || { log_fail "$scenario" "Create project failed"; cmd_log_dump; return; }

  cmd_log_add "tt task checkout $proj_id"
  run_tt task checkout "$proj_id" --repo "$REPO" >/dev/null 2>&1

  # Create and work on task
  cmd_log_add "tt task create --slug feature --title 'Feature' --checkout"
  local feat_id
  feat_id=$(create_task "feature" "Feature" --repo "$REPO" --checkout) || { log_fail "$scenario" "Create feature failed"; cmd_log_dump; return; }

  # Checkpoint 1
  cmd_log_add "tt task checkpoint -m 'impl v1'"
  run_tt task checkpoint -m "impl v1" --repo "$REPO" >/dev/null 2>&1

  # Checkpoint 2
  cmd_log_add "tt task checkpoint -m 'impl v2'"
  run_tt task checkpoint -m "impl v2" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after 2 checkpoints)"; then
    cmd_log_dump
    return
  fi

  # Undo checkpoint 2 (changed my mind)
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1

  # Do different checkpoint
  cmd_log_add "tt task checkpoint -m 'impl v2-alt'"
  run_tt task checkpoint -m "impl v2-alt" --repo "$REPO" >/dev/null 2>&1

  # Complete
  cmd_log_add "tt task complete"
  run_tt task complete --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after complete)"; then
    cmd_log_dump
    return
  fi

  # Oops, undo the complete (forgot something)
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1

  # Undo the alt checkpoint too
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after 2 undos)"; then
    cmd_log_dump
    return
  fi

  # Do final work and complete properly
  cmd_log_add "tt task checkpoint -m 'impl v3-final'"
  run_tt task checkpoint -m "impl v3-final" --repo "$REPO" >/dev/null 2>&1

  cmd_log_add "tt task complete"
  run_tt task complete --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after final complete)"; then
    cmd_log_dump
    return
  fi

  # Checkin
  cmd_log_add "tt task checkin $feat_id"
  run_tt task checkin "$feat_id" --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after checkin)"; then
    cmd_log_dump
    return
  fi

  # Undo the checkin
  cmd_log_add "tt undo"
  run_tt undo --repo "$REPO" >/dev/null 2>&1

  if ! verify_history_integrity "$scenario (after undo checkin)"; then
    cmd_log_dump
    return
  fi

  log_pass "$scenario"
}


# ══════════════════════════════════════════════════════════════════════════════
# TEST REGISTRY & RUNNER
# ══════════════════════════════════════════════════════════════════════════════

# Ordered list of (number, function_name, description)
# Keep in sync with the test functions above.
declare -a TEST_NUMS=()
declare -a TEST_FUNCS=()
declare -a TEST_DESCS=()

register_test() { TEST_NUMS+=("$1"); TEST_FUNCS+=("$2"); TEST_DESCS+=("$3"); }

register_test  1 test_basic_checkpoint_undo            "Basic checkpoint + undo"
register_test  2 test_multiple_checkpoints_undos        "Multiple checkpoints + multiple undos"
register_test  3 test_undo_task_create                  "Undo task create"
register_test  4 test_undo_checkout                     "Undo checkout (begin task)"
register_test  5 test_undo_complete                     "Undo complete"
register_test  6 test_undo_checkin                      "Undo checkin"
register_test  7 test_undo_force_op_mismatch            "Undo --force when op ID mismatches"
register_test  8 test_undo_dirty_wc                     "Undo with dirty working copy"
register_test  9 test_undo_empty_history                "Undo on empty history"
register_test 10 test_undo_past_all_history             "Consecutive undos past all history"
register_test 11 test_undo_create_with_checkout         "Undo create --checkout (compound)"
register_test 12 test_interleaved_create_checkpoint_undo "Interleaved create/checkpoint/undo"
register_test 13 test_undo_checkin_complete             "Undo checkin --complete"
register_test 14 test_undo_create_with_propagate        "Undo create --propagate"
register_test 15 test_undo_rename                       "Undo rename"
register_test 16 test_undo_edit                         "Undo edit"
register_test 17 test_undo_delete                       "Undo delete"
register_test 18 test_full_lifecycle_undo_all           "Full lifecycle then undo everything"
register_test 19 test_two_children_interleaved_undo     "Two children, interleaved work + undo"
register_test 20 test_undo_context_add                  "Undo context add"
register_test 21 test_rapid_consecutive_undos           "Rapid consecutive undos (5+5)"
register_test 22 test_undo_after_propagate_and_new_work "Undo/redo with propagate interleaved"
register_test 23 test_undo_context_delete               "Undo context delete"
register_test 24 test_undo_redo_complete_then_checkin   "Undo complete, redo, then checkin"
register_test 25 test_undo_first_command                "Undo the very first mutating command"
register_test 26 test_undo_deep_tree                    "Undo in deep task tree (3 levels)"
register_test 27 test_undo_propagate_standalone         "Undo standalone propagate"
register_test 28 test_undo_diverge_undo                 "Undo, diverge, undo"
register_test 29 test_undo_move                         "Undo move"
register_test 30 test_complex_realistic_workflow        "Complex realistic workflow with undos"

# Parse filter arguments into a set of test numbers to run.
# Supports: bare numbers (2 12 30), ranges (5-10), or mix (1 5-8 30).
# Empty means "run all".
parse_filter() {
  local -a selected=()
  for arg in "$@"; do
    if [[ "$arg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local lo="${BASH_REMATCH[1]}" hi="${BASH_REMATCH[2]}"
      for ((n=lo; n<=hi; n++)); do selected+=("$n"); done
    elif [[ "$arg" =~ ^[0-9]+$ ]]; then
      selected+=("$arg")
    else
      echo "Error: Invalid filter argument: $arg" >&2
      echo "Usage: $0 [test-number | range ...]   e.g.  $0 2 12 5-8" >&2
      exit 2
    fi
  done
  # Deduplicate
  printf '%s\n' "${selected[@]}" | sort -un
}

should_run() {
  local num="$1"
  if [[ ${#RUN_FILTER[@]} -eq 0 ]]; then
    return 0  # no filter → run all
  fi
  for f in "${RUN_FILTER[@]}"; do
    [[ "$f" == "$num" ]] && return 0
  done
  return 1
}

list_tests() {
  printf '\nAvailable tests:\n\n'
  local i
  for ((i=0; i<${#TEST_NUMS[@]}; i++)); do
    printf '  %2d  %s\n' "${TEST_NUMS[$i]}" "${TEST_DESCS[$i]}"
  done
  printf '\nUsage: %s [test-number | range ...]\n' "$0"
  printf '  e.g.  %s 2 12 5-8\n\n' "$0"
}

main() {
  # Handle --list / -l
  if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    list_tests
    exit 0
  fi

  # Parse filter
  declare -a RUN_FILTER=()
  if [[ $# -gt 0 ]]; then
    while IFS= read -r _n; do
      RUN_FILTER+=("$_n")
    done < <(parse_filter "$@")
  fi

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║        tt history undo — Comprehensive Test Suite          ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  if [[ ${#RUN_FILTER[@]} -gt 0 ]]; then
    printf '  Running tests: %s\n' "${RUN_FILTER[*]}"
  fi
  echo ""

  local i
  for ((i=0; i<${#TEST_NUMS[@]}; i++)); do
    if should_run "${TEST_NUMS[$i]}"; then
      "${TEST_FUNCS[$i]}"
    fi
  done

  # ── Summary ──────────────────────────────────────────────────────────────
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  printf '%bResults: %d passed, %d failed, %d skipped%b\n' \
    "$BOLD" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$RESET"
  echo "══════════════════════════════════════════════════════════════"

  if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    printf '%bFailures:%b\n' "$RED" "$RESET"
    for f in "${FAILURES[@]}"; do
      printf '  • %s\n' "$f"
    done
  fi

  echo ""
  echo "Temp directory: $TEST_ROOT"

  if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
