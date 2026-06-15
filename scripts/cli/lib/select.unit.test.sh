#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=select.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/select.sh"

# ---------------------------------------------------------------------------
# Focused unit tests for select.sh core functions
# ---------------------------------------------------------------------------

# Test fuzzy matching function
test_fuzzy_match__basic_cases() {
  # Empty filter matches everything
  _select_fuzzy_match "anything" ""
  assert_success "empty filter" "$?"
  
  # Exact matches
  _select_fuzzy_match "hello" "hello"
  assert_success "exact match" "$?"
  
  # Case insensitive
  _select_fuzzy_match "Hello" "hello"
  assert_success "case insensitive" "$?"
  
  # Subsequence
  _select_fuzzy_match "apple" "ap"
  assert_success "subsequence" "$?"
  
  # No match - test separately to avoid potential hang
  if _select_fuzzy_match "hello" "xyz"; then
    assert_failure "no match should fail" "0"
  else
    assert_success "no match correctly fails" "0"
  fi
}

test_state_init() {
  ITEMS=("one" "two" "three")
  _select_init_state
  
  assert_eq "mode set" "$MODE" "normal"
  assert_eq "items copied" "${#FILTERED_ITEMS[@]}" "3"
  assert_eq "selection at start" "$SELECTED_IDX" "0"
}

test_filter_application() {
  ITEMS=("apple" "banana" "cherry")
  _select_init_state
  
  FILTER="a"
  _select_apply_filter
  
  # Should match apple and banana
  assert_eq "filter applied" "${#FILTERED_ITEMS[@]}" "2"
}

test_window_clamping() {
  ITEMS=("a" "b" "c" "d" "e")
  _select_init_state
  WINDOW_SIZE=3
  
  # Test moving selection to end
  SELECTED_IDX=4
  _select_clamp_window
  
  # Window should adjust to show selection
  assert_eq "selection in bounds" "$SELECTED_IDX" "4"
  assert_eq "window adjusted" "$WINDOW_OFFSET" "2"
}

run_tests "tt lib/select (unit core)"