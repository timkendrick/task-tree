#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=select.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/select.sh"

# ---------------------------------------------------------------------------
# Integration tests for select.sh - testing key components together
# ---------------------------------------------------------------------------

# These tests don't require actual interactive input, they test the state machine

test_integration__basic_flow() {
  # Setup test items
  ITEMS=("first" "second" "third")
  _select_init_state
  
  # Initial state should have all items visible
  assert_eq "initial items count" "${#FILTERED_ITEMS[@]}" "3"
  assert_eq "initial selection" "$SELECTED_IDX" "0"
  assert_eq "initial mode" "$MODE" "normal"
  
  # Move down
  _select_transition "j"
  assert_eq "moved down" "$SELECTED_IDX" "1"
  
  # Move up  
  _select_transition "k"
  assert_eq "moved up" "$SELECTED_IDX" "0"
  
  # Go to last
  _select_transition "G"
  assert_eq "go to last" "$SELECTED_IDX" "2"
  
  # Select current item
  _select_transition "enter"
  assert_eq "selected item" "$_SELECT_RESULT" "third"
  assert_eq "done flag set" "$_SELECT_DONE" "1"
}

test_integration__filter_flow() {
  # Setup test items
  ITEMS=("apple" "banana" "apricot" "cherry")
  _select_init_state
  
  # Start filtering
  _select_transition "/"
  assert_eq "enter filter mode" "$MODE" "filter"
  
  # Type 'a'
  _select_transition "a"
  assert_eq "typed a" "$PENDING_FILTER" "a"
  
  # Apply filter should show items with 'a'
  _select_apply_filter
  assert_eq "filtered items count" "${#FILTERED_ITEMS[@]}" "3"  # apple, banana, apricot
  
  # Type 'p' to narrow to 'ap'
  _select_transition "p"
  assert_eq "typed ap" "$PENDING_FILTER" "ap"
  
  _select_apply_filter
  assert_eq "narrowed items count" "${#FILTERED_ITEMS[@]}" "2"  # apple, apricot
  
  # Apply the filter with enter
  _select_transition "enter"
  assert_eq "filter applied" "$FILTER" "ap"
  assert_eq "back to normal" "$MODE" "normal"
  assert_eq "selection reset" "$SELECTED_IDX" "0"
  assert_eq "filtered results" "${#FILTERED_ITEMS[@]}" "2"
}

test_integration__filter_escape() {
  # Setup test items
  ITEMS=("test1" "test2" "other")
  _select_init_state
  
  # Apply initial filter
  FILTER="test"
  _select_apply_filter
  assert_eq "initial filter applied" "${#FILTERED_ITEMS[@]}" "2"
  
  # Start new filter
  _select_transition "/"
  assert_eq "in filter mode" "$MODE" "filter"
  
  # Type something
  _select_transition "o"
  assert_eq "typed o" "$PENDING_FILTER" "o"
  
  # Escape should cancel
  _select_transition "escape"
  assert_eq "back to normal" "$MODE" "normal"
  assert_eq "pending cleared" "$PENDING_FILTER" ""
  assert_eq "old filter kept" "$FILTER" "test"
  assert_eq "old filter still active" "${#FILTERED_ITEMS[@]}" "2"
}

test_integration__backspace_and_ctrl_u() {
  # Setup test items  
  ITEMS=("hello" "world")
  _select_init_state
  
  _select_transition "/"
  _select_transition "h"
  _select_transition "e"
  _select_transition "l"
  assert_eq "typed hel" "$PENDING_FILTER" "hel"
  
  # Backspace
  _select_transition "backspace"
  assert_eq "backspaced to he" "$PENDING_FILTER" "he"
  
  # More characters
  _select_transition "l"
  _select_transition "l"
  assert_eq "typed hell" "$PENDING_FILTER" "hell"
  
  # Ctrl-U clears all
  _select_transition "ctrl_u"
  assert_eq "ctrl-u clears" "$PENDING_FILTER" ""
}

test_integration__no_matches_blocks_enter() {
  ITEMS=("apple" "banana")
  _select_init_state
  
  _select_transition "/"
  _select_transition "x"
  _select_transition "y"
  _select_transition "z"
  
  # Should have no matches
  _select_apply_filter
  assert_eq "no matches" "${#FILTERED_ITEMS[@]}" "0"
  
  # Enter should not apply filter
  _select_transition "enter"
  assert_eq "still in filter mode" "$MODE" "filter"
  assert_eq "pending filter unchanged" "$PENDING_FILTER" "xyz"
  assert_eq "main filter unchanged" "$FILTER" ""
}

run_tests "tt lib/select (integration)"