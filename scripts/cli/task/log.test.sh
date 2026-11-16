#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"

# Unicode glyphs, so assertions can name them without Nerd Font code points.
FORK=$'\342\221\202'
EDIT=$'\342\234\216'
CHECKOUT=$'\342\226\266'
CHECKPOINT=$'\342\232\221'
CONTEXT=$'\302\247'
BOOKMARK=$'\342\232\220'
WARNING=$'\342\232\240'

# Usage: run_log [ARGS...]
# Runs `tt task log` with Unicode glyphs.
run_log() {
  TT_LOG_ICONS=unicode run_tt task log "$@"
}

# Sets up a project with one checked-out task holding a checkpoint "w1".
# Sets PROJ_ID and TASK_ID.
_setup_task() {
  setup_workspace "$1"
  PROJ_ID=$(create_project "proj" "Project") || true
  checkout_task "$PROJ_ID" >/dev/null || true
  checkpoint_task "project work" >/dev/null || true
  TASK_ID=$(create_task "t" "T") || true
  checkout_task "$TASK_ID" >/dev/null || true
  echo w1 > "$TT_REPO/w1.txt"
  checkpoint_task "w1" >/dev/null || true
}


test_task_log__current_task_events() {
  _setup_task "log-current"

  output="" exit_code=0
  output=$(run_log 2>&1) || exit_code=$?
  assert_success "log succeeds" "$exit_code"
  assert_matches "fork shows the task ID" "$output" "^${FORK}  [k-z]{8}  ${TASK_ID}\$"
  assert_matches "edit shows only the glyph and change ID" "$output" "^${EDIT}  [k-z]{8}\$"
  assert_matches "checkout shows only the glyph and change ID" "$output" "^${CHECKOUT}  [k-z]{8}\$"
  assert_matches "checkpoint shows its message and the bookmark" "$output" \
    "^${CHECKPOINT}  [k-z]{8}  w1  ${BOOKMARK} ${TASK_ID}\$"
  assert_not_contains "parent-only work excluded" "$output" "project work"
  assert_not_contains "no raw tt commit messages" "$output" "[tt:"
}


test_task_log__trailing_commits_only_without_task() {
  _setup_task "log-trailing"
  commit_uncheckpointed_work

  output=""
  output=$(run_log --all 2>&1) || true
  assert_contains "current task includes trailing commits" "$output" "Uncheckpointed work"

  output=$(run_log --all --task "$TASK_ID" 2>&1) || true
  assert_not_contains "--task stops at the bookmark" "$output" "Uncheckpointed work"
  assert_contains "--task still shows the task's commits" "$output" "w1"
}


test_task_log__plain_commits_hidden_by_default() {
  _setup_task "log-hide-plain"
  echo side > "$TT_REPO/side.txt"
  jj -R "$TT_REPO" commit -m "Side work" >/dev/null 2>&1
  run_tt task checkpoint -m "w2" >/dev/null 2>&1 || true
  commit_uncheckpointed_work

  output="" exit_code=0
  output=$(run_log 2>&1) || exit_code=$?
  assert_success "log succeeds" "$exit_code"
  assert_not_contains "side chain hidden" "$output" "Side work"
  assert_not_contains "trailing commits hidden" "$output" "Uncheckpointed work"
  assert_contains "merge keeps its arm for a hidden side chain" "$output" "├─╮"
  assert_contains "hidden side chain drawn as elided revisions" "$output" "(elided revisions)"
  assert_not_contains "elided node renders without a template error" "$output" "Error"
  assert_matches "checkpoint event still shown" "$output" "^${CHECKPOINT}  [k-z]{8}  w2"
  assert_eq "trailing commits counted above the graph" \
    "$(printf '%s\n' "$output" | head -n 1)" "${WARNING}  1 uncheckpointed commit"

  output=$(run_log --all 2>&1) || true
  assert_contains "--all shows the side chain" "$output" "Side work"
  assert_contains "--all shows trailing commits" "$output" "Uncheckpointed work"
  assert_contains "--all draws the merge arm" "$output" "├─╮"
  assert_not_contains "--all shows no count line" "$output" "uncheckpointed commit"
}


test_task_log__limit_counts_shown_commits() {
  _setup_task "log-limit-shown"
  commit_uncheckpointed_work

  output="" exit_code=0
  output=$(run_log --limit 1 2>&1) || exit_code=$?
  assert_success "log succeeds" "$exit_code"
  assert_line_count "count line and one event commit" "$output" 2
  assert_eq "count line not limited" "$(printf '%s\n' "$output" | head -n 1)" "${WARNING}  1 uncheckpointed commit"
  assert_contains "newest event kept" "$output" "w1"
}


test_task_log__complete_range_spans_checkins() {
  _setup_task "log-complete-range"
  run_tt task checkin "$TASK_ID" >/dev/null 2>&1 || true
  checkout_task "$TASK_ID" >/dev/null || true
  echo w2 > "$TT_REPO/w2.txt"
  checkpoint_task "w2" >/dev/null || true

  output="" exit_code=0
  output=$(run_log --task "$TASK_ID" 2>&1) || exit_code=$?
  assert_success "log succeeds" "$exit_code"
  assert_contains "work before the checkin" "$output" "w1"
  assert_contains "work after the checkin" "$output" "w2"
  assert_not_contains "parent-only work excluded" "$output" "project work"
}


test_task_log__project_line() {
  _setup_task "log-project"
  run_tt task checkin "$TASK_ID" >/dev/null 2>&1 || true

  output="" exit_code=0
  output=$(run_log --task "$PROJ_ID" 2>&1) || exit_code=$?
  assert_success "log succeeds" "$exit_code"
  assert_contains "project work shown" "$output" "project work"
  assert_contains "checked-in task arm shown" "$output" "w1"
  assert_not_contains "history before the project excluded" "$output" "Initial commit"
}


test_task_log__context_label() {
  _setup_task "log-context"
  run_tt task context add --title "Notes" --slug "notes" <<< "Body" >/dev/null 2>&1 || true

  output=""
  output=$(run_log 2>&1) || true
  assert_matches "context event shows the context ID" "$output" "^${CONTEXT}  [k-z]{8}  context/notes-[0-9a-f]{8}( |$)"
}


test_task_log__limit() {
  _setup_task "log-limit"

  output="" exit_code=0
  output=$(run_log --task "$TASK_ID" --limit 1 2>&1) || exit_code=$?
  assert_success "log succeeds" "$exit_code"
  assert_line_count "one event commit" "$output" 1
  assert_contains "newest commit kept" "$output" "w1"
}


test_task_log__invalid_limit() {
  setup_workspace "log-invalid-limit"
  local value
  for value in 0 -1 abc; do
    exit_code=0
    run_tt task log --limit "$value" >/dev/null 2>&1 || exit_code=$?
    assert_failure "--limit $value rejected" "$exit_code"
  done
}


test_task_log__unknown_task() {
  _setup_task "log-unknown"

  output="" exit_code=0
  output=$(run_tt task log --task task/missing-0a1b2c3d 2>&1) || exit_code=$?
  assert_failure "missing task rejected" "$exit_code"
  assert_contains "error names the bookmark" "$output" "task/missing-0a1b2c3d"

  exit_code=0
  output=$(run_tt task log --task main 2>&1) || exit_code=$?
  assert_failure "non-task bookmark rejected" "$exit_code"
  assert_contains "error explains the rejection" "$output" "not a task or project branch"
}


test_task_log__no_color_when_piped() {
  _setup_task "log-no-color"

  output=""
  output=$(run_tt task log 2>&1) || true
  assert_not_contains "no escape sequences" "$output" $'\033'
}


test_task_log__nerd_font_icons_by_default() {
  _setup_task "log-nerd"

  output=""
  output=$(run_tt task log 2>&1) || true
  assert_contains "Nerd Font fork icon" "$output" $'\357\204\246'
  assert_not_contains "no Unicode fork glyph" "$output" "$FORK"
}


test_task_log__help() {
  setup_workspace "log-help"
  output="" exit_code=0
  output=$(run_tt task log --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_contains "usage line" "$output" "Usage: tt task log"
  assert_contains "documents the icon variable" "$output" "TT_LOG_ICONS"
  assert_contains "documents --all" "$output" "--all"
}


test_task_log__alias() {
  _setup_task "log-alias"

  canonical="" alias_output="" exit_code=0
  canonical=$(run_log 2>&1) || true
  alias_output=$(TT_LOG_ICONS=unicode run_tt log 2>&1) || exit_code=$?
  assert_success "alias succeeds" "$exit_code"
  assert_eq "alias matches canonical output" "$alias_output" "$canonical"
}

run_tests "tt task log"
