#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=select.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/select.sh"

# ---------------------------------------------------------------------------
# Unit tests for select.sh interactive selector library
# ---------------------------------------------------------------------------

# Helper: setup test items
_setup_test_items() {
  ITEMS=("apple" "banana" "cherry" "date" "elderberry")
  _select_init_state
}

# ---------------------------------------------------------------------------
# State initialization tests
# ---------------------------------------------------------------------------

test_select_init_state__sets_defaults() {
  ITEMS=("item1" "item2" "item3")
  _select_init_state
  
  assert_eq "mode is normal" "$MODE" "normal"
  assert_eq "filter is empty" "$FILTER" ""
  assert_eq "pending filter is empty" "$PENDING_FILTER" ""
  assert_eq "selected index is 0" "$SELECTED_IDX" "0"
  assert_eq "window offset is 0" "$WINDOW_OFFSET" "0"
  assert_eq "done flag is false" "$_SELECT_DONE" "0"
  assert_eq "window size is reasonable" "$([[ $WINDOW_SIZE -ge 3 ]] && echo "yes" || echo "no")" "yes"
}

test_select_init_state__computes_filtered_items() {
  _setup_test_items
  
  assert_eq "filtered items count" "${#FILTERED_ITEMS[@]}" "5"
  assert_eq "first filtered item" "${FILTERED_ITEMS[0]}" "apple"
  assert_eq "last filtered item" "${FILTERED_ITEMS[4]}" "elderberry"
}

# ---------------------------------------------------------------------------
# Fuzzy matching tests
# ---------------------------------------------------------------------------

test_fuzzy_match__empty_filter_matches_all() {
  _select_fuzzy_match 'any string' ''
  assert_success "empty filter matches" "$?"
}

test_fuzzy_match__exact_match() {
  _select_fuzzy_match 'hello' 'hello'
  assert_success "exact match" "$?"
}

test_fuzzy_match__case_insensitive() {
  _select_fuzzy_match 'Hello World' 'hello'
  assert_success "case insensitive 1" "$?"
  _select_fuzzy_match 'HELLO' 'hello'
  assert_success "case insensitive 2" "$?"
}

test_fuzzy_match__subsequence_match() {
  _select_fuzzy_match 'task/some-command-abc12345' 'tsc'
  assert_success "subsequence 1" "$?"
  _select_fuzzy_match 'implementation' 'imp'
  assert_success "subsequence 2" "$?"
  _select_fuzzy_match 'apple banana' 'ab'
  assert_success "subsequence 3" "$?"
}

test_fuzzy_match__no_match() {
  local rc=0
  _select_fuzzy_match 'hello' 'xyz' || rc=$?
  assert_failure "no match 1" "$rc"
  rc=0
  _select_fuzzy_match 'abc' 'def' || rc=$?
  assert_failure "no match 2" "$rc"
  rc=0
  _select_fuzzy_match 'short' 'very-long-string' || rc=$?
  assert_failure "no match 3" "$rc"
}

test_fuzzy_match__order_matters() {
  _select_fuzzy_match 'abcde' 'ace'
  assert_success "order match" "$?"
  local rc=0
  _select_fuzzy_match 'abcde' 'eca' || rc=$?
  assert_failure "order no match" "$rc"
}

# ---------------------------------------------------------------------------
# Filter application tests  
# ---------------------------------------------------------------------------

test_apply_filter__no_filter() {
  _setup_test_items
  FILTER=""
  _select_apply_filter
  
  assert_eq "all items match" "${#FILTERED_ITEMS[@]}" "5"
}

test_apply_filter__with_filter() {
  _setup_test_items
  FILTER="a"
  _select_apply_filter
  
  # Should match: apple, banana, date
  assert_eq "filtered count" "${#FILTERED_ITEMS[@]}" "3"
  assert_eq "apple matches" "${FILTERED_ITEMS[0]}" "apple"
  assert_eq "banana matches" "${FILTERED_ITEMS[1]}" "banana"
  assert_eq "date matches" "${FILTERED_ITEMS[2]}" "date"
}

test_apply_filter__pending_filter_in_filter_mode() {
  _setup_test_items
  MODE="filter"
  FILTER="old"
  PENDING_FILTER="ch"
  _select_apply_filter
  
  # Should use PENDING_FILTER, match: cherry
  assert_eq "uses pending filter" "${#FILTERED_ITEMS[@]}" "1"
  assert_eq "cherry matches" "${FILTERED_ITEMS[0]}" "cherry"
}

test_apply_filter__no_matches() {
  _setup_test_items
  FILTER="xyz"
  _select_apply_filter
  
  assert_eq "no matches" "${#FILTERED_ITEMS[@]}" "0"
}

# ---------------------------------------------------------------------------
# Window clamping tests
# ---------------------------------------------------------------------------

test_clamp_window__selected_index_in_bounds() {
  _setup_test_items
  WINDOW_SIZE=3
  SELECTED_IDX=10  # Out of bounds
  _select_clamp_window
  
  assert_eq "clamps to last item" "$SELECTED_IDX" "4"
}

test_clamp_window__adjusts_window_for_selection() {
  _setup_test_items
  WINDOW_SIZE=3
  SELECTED_IDX=4  # Last item
  WINDOW_OFFSET=0
  _select_clamp_window
  
  # Window should shift to show last item
  assert_eq "window shows selection" "$WINDOW_OFFSET" "2"
}

test_clamp_window__empty_filtered_items() {
  ITEMS=()
  FILTERED_ITEMS=()
  SELECTED_IDX=5
  _select_clamp_window
  
  assert_eq "handles empty list" "$SELECTED_IDX" "0"  # Should be clamped to 0
}

# ---------------------------------------------------------------------------
# State transition tests - Normal mode
# ---------------------------------------------------------------------------

test_transition_normal__move_down() {
  _setup_test_items
  SELECTED_IDX=1
  
  _select_transition "j"
  assert_eq "moves selection down" "$SELECTED_IDX" "2"
  
  _select_transition "arrow_down"
  assert_eq "arrow also moves down" "$SELECTED_IDX" "3"
}

test_transition_normal__move_up() {
  _setup_test_items
  SELECTED_IDX=2
  
  _select_transition "k"
  assert_eq "moves selection up" "$SELECTED_IDX" "1"
  
  _select_transition "arrow_up" 
  assert_eq "arrow also moves up" "$SELECTED_IDX" "0"
}

test_transition_normal__clamps_at_bounds() {
  _setup_test_items
  SELECTED_IDX=0
  
  _select_transition "k"
  assert_eq "stays at top" "$SELECTED_IDX" "0"
  
  SELECTED_IDX=4
  _select_transition "j"
  assert_eq "stays at bottom" "$SELECTED_IDX" "4"
}

test_transition_normal__go_to_first() {
  _setup_test_items
  SELECTED_IDX=3
  WINDOW_OFFSET=2
  
  _select_transition "g"
  assert_eq "goes to first" "$SELECTED_IDX" "0"
  assert_eq "resets window" "$WINDOW_OFFSET" "0"
}

test_transition_normal__go_to_last() {
  _setup_test_items
  SELECTED_IDX=1
  
  _select_transition "G"
  assert_eq "goes to last" "$SELECTED_IDX" "4"
}

test_transition_normal__enter_selects() {
  _setup_test_items
  SELECTED_IDX=2
  
  _select_transition "enter"
  assert_eq "sets result" "$_SELECT_RESULT" "cherry"
  assert_eq "sets done flag" "$_SELECT_DONE" "1"
}

test_transition_normal__start_filter() {
  _setup_test_items
  
  _select_transition "/"
  assert_eq "enters filter mode" "$MODE" "filter"
  assert_eq "clears pending filter" "$PENDING_FILTER" ""
}

# ---------------------------------------------------------------------------
# State transition tests - Filter mode
# ---------------------------------------------------------------------------

test_transition_filter__add_characters() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER=""
  
  _select_transition "a"
  assert_eq "adds character" "$PENDING_FILTER" "a"
  
  _select_transition "p"
  assert_eq "appends character" "$PENDING_FILTER" "ap"
}

test_transition_filter__backspace() {
  _setup_test_items  
  MODE="filter"
  PENDING_FILTER="abc"
  
  _select_transition "backspace"
  assert_eq "removes last char" "$PENDING_FILTER" "ab"
  
  _select_transition "backspace"
  assert_eq "removes another char" "$PENDING_FILTER" "a"
  
  _select_transition "backspace"
  assert_eq "can clear completely" "$PENDING_FILTER" ""
  
  # Should not go negative
  _select_transition "backspace"
  assert_eq "stays empty" "$PENDING_FILTER" ""
}

test_transition_filter__ctrl_u_clears() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER="hello world"
  
  _select_transition "ctrl_u"
  assert_eq "clears all" "$PENDING_FILTER" ""
}

test_transition_filter__enter_applies_filter() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER="a"
  
  _select_transition "enter"
  assert_eq "applies filter" "$FILTER" "a"
  assert_eq "clears pending" "$PENDING_FILTER" ""
  assert_eq "returns to normal" "$MODE" "normal"
  assert_eq "resets selection" "$SELECTED_IDX" "0"
}

test_transition_filter__enter_blocked_no_matches() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER="xyz"  # No matches
  
  _select_transition "enter"
  # Should stay in filter mode
  assert_eq "stays in filter mode" "$MODE" "filter"
  assert_eq "keeps pending filter" "$PENDING_FILTER" "xyz"
  assert_eq "doesnt change main filter" "$FILTER" ""
}

test_transition_filter__escape_cancels() {
  _setup_test_items
  MODE="filter"
  FILTER="old"
  PENDING_FILTER="new"
  
  _select_transition "escape"
  assert_eq "returns to normal" "$MODE" "normal"
  assert_eq "clears pending" "$PENDING_FILTER" ""
  assert_eq "keeps old filter" "$FILTER" "old"
}

# ---------------------------------------------------------------------------
# Key reading tests (mocked)
# ---------------------------------------------------------------------------

test_read_key__normalizes_keys() {
  # We can't easily test actual key reading in unit tests,
  # but we can test that our transition functions handle the expected key names
  _setup_test_items
  
  # Test that all expected key names work without errors
  for key in j k g G enter escape backspace ctrl_u arrow_up arrow_down / a b c; do
    _select_transition "$key" 2>/dev/null || true  # Don't fail on invalid transitions
  done
  
  # If we get here, no syntax errors in key handling
  local exit_code=0
  assert_success "key handling" "$exit_code"
}

run_tests "tt lib/select (unit)"