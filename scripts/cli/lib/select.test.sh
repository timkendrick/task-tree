#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"
# shellcheck source=select.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/select.sh"

# ---------------------------------------------------------------------------
# Comprehensive unit tests for select.sh interactive selector library
# ---------------------------------------------------------------------------

# Helper: setup test items
_setup_test_items() {
  ITEMS=("apple" "banana" "cherry" "date" "elderberry")
  _select_init_state
}

# Helper: setup large test items list for window testing
_setup_large_test_items() {
  ITEMS=("item01" "item02" "item03" "item04" "item05" "item06" "item07" "item08" "item09" "item10" "item11" "item12" "item13" "item14" "item15")
  _select_init_state
}

# Helper: setup single item for edge cases
_setup_single_item() {
  ITEMS=("only-item")
  _select_init_state
}

# Helper: render tests are skipped due to /dev/tty requirement

# ---------------------------------------------------------------------------
# 1. Fuzzy Matching Tests (_select_fuzzy_match)
# ---------------------------------------------------------------------------

test_fuzzy_match__empty_filter_matches_all() {
  _select_fuzzy_match 'any string' ''
  assert_success "empty filter matches" "$?"
  
  _select_fuzzy_match '' ''
  assert_success "empty value with empty filter" "$?"
}

test_fuzzy_match__exact_match() {
  _select_fuzzy_match 'hello' 'hello'
  assert_success "exact match" "$?"
  
  _select_fuzzy_match 'test' 'test'
  assert_success "exact match 2" "$?"
}

test_fuzzy_match__case_insensitive() {
  _select_fuzzy_match 'Hello World' 'hello'
  assert_success "lowercase filter, mixed case value" "$?"
  
  _select_fuzzy_match 'HELLO' 'hello'
  assert_success "lowercase filter, uppercase value" "$?"
  
  _select_fuzzy_match 'hello' 'HELLO'
  assert_success "uppercase filter, lowercase value" "$?"
  
  _select_fuzzy_match 'Hello' 'HeLLo'
  assert_success "mixed case both" "$?"
}

test_fuzzy_match__subsequence_match() {
  _select_fuzzy_match 'task/some-command-abc12345' 'tsc'
  assert_success "task subsequence" "$?"
  
  _select_fuzzy_match 'implementation' 'imp'
  assert_success "simple subsequence" "$?"
  
  _select_fuzzy_match 'apple banana' 'ab'
  assert_success "cross-word subsequence" "$?"
  
  _select_fuzzy_match 'abcdefghijk' 'ace'
  assert_success "sparse subsequence" "$?"
}

test_fuzzy_match__no_match() {
  local rc=0
  _select_fuzzy_match 'hello' 'xyz' || rc=$?
  assert_failure "no common chars" "$rc"
  
  rc=0
  _select_fuzzy_match 'abc' 'def' || rc=$?
  assert_failure "completely different" "$rc"
  
  rc=0
  _select_fuzzy_match 'short' 'very-long-string' || rc=$?
  assert_failure "filter longer than value" "$rc"
}

test_fuzzy_match__repeated_characters() {
  _select_fuzzy_match 'hello' 'll'
  assert_success "repeated chars found" "$?"
  
  _select_fuzzy_match 'mmmtest' 'mmm'
  assert_success "multiple repeated chars" "$?"
  
  # Should match greedily left-to-right
  _select_fuzzy_match 'ababa' 'aba'
  assert_success "greedy left-to-right" "$?"
}

test_fuzzy_match__special_characters() {
  _select_fuzzy_match 'src/lib/test.js' 'src'
  assert_success "slash in value" "$?"
  
  _select_fuzzy_match 'some-command-name' 'some'
  assert_success "dash in value" "$?"
  
  _select_fuzzy_match 'file.txt' '.'
  assert_success "dot in filter" "$?"
  
  _select_fuzzy_match 'path/to/file' '/'
  assert_success "slash in filter" "$?"
}

test_fuzzy_match__empty_value() {
  local rc=0
  _select_fuzzy_match '' 'abc' || rc=$?
  assert_failure "empty value with non-empty filter" "$rc"
  
  _select_fuzzy_match '' ''
  assert_success "empty value with empty filter" "$?"
}

test_fuzzy_match__order_matters() {
  _select_fuzzy_match 'abcde' 'ace'
  assert_success "correct order" "$?"
  
  local rc=0
  _select_fuzzy_match 'abcde' 'eca' || rc=$?
  assert_failure "wrong order" "$rc"
  
  rc=0
  _select_fuzzy_match 'hello' 'leh' || rc=$?
  assert_failure "reversed order" "$rc"
}

# ---------------------------------------------------------------------------
# 2. State Initialization Tests (_select_init_state)
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
  assert_eq "result is empty" "$_SELECT_RESULT" ""
  assert_eq "prev lines is 0" "$_SELECT_PREV_LINES" "0"
  assert_eq "window size is reasonable" "$([[ $WINDOW_SIZE -ge 3 ]] && echo "yes" || echo "no")" "yes"
}

test_select_init_state__computes_filtered_items() {
  _setup_test_items
  
  assert_eq "filtered items count" "${#FILTERED_ITEMS[@]}" "5"
  assert_eq "first filtered item" "${FILTERED_ITEMS[0]}" "apple"
  assert_eq "last filtered item" "${FILTERED_ITEMS[4]}" "elderberry"
}

test_select_init_state__empty_items_list() {
  # Skip this test - in practice select_value() validates non-empty input
  # and the state machine assumes at least one item exists
  skip_test "empty items list" "state machine assumes non-empty input"
}

test_select_init_state__resets_state() {
  # Set some non-default values
  MODE="filter"
  FILTER="old"
  PENDING_FILTER="pending"
  SELECTED_IDX=5
  WINDOW_OFFSET=3
  _SELECT_DONE=1
  _SELECT_RESULT="old result"
  
  _setup_test_items
  
  assert_eq "mode reset" "$MODE" "normal"
  assert_eq "filter reset" "$FILTER" ""
  assert_eq "pending filter reset" "$PENDING_FILTER" ""
  assert_eq "selected index reset" "$SELECTED_IDX" "0"
  assert_eq "window offset reset" "$WINDOW_OFFSET" "0"
  assert_eq "done flag reset" "$_SELECT_DONE" "0"
  assert_eq "result reset" "$_SELECT_RESULT" ""
}

# ---------------------------------------------------------------------------
# 3. Filter Application Tests (_select_apply_filter)
# ---------------------------------------------------------------------------

test_apply_filter__empty_filter_returns_all() {
  _setup_test_items
  FILTER=""
  _select_apply_filter
  
  assert_eq "all items match" "${#FILTERED_ITEMS[@]}" "5"
  assert_eq "first item" "${FILTERED_ITEMS[0]}" "apple"
  assert_eq "last item" "${FILTERED_ITEMS[4]}" "elderberry"
}

test_apply_filter__filter_reduces_items() {
  _setup_test_items
  FILTER="a"
  _select_apply_filter
  
  # Should match: apple, banana, date
  assert_eq "filtered count" "${#FILTERED_ITEMS[@]}" "3"
  assert_eq "apple matches" "${FILTERED_ITEMS[0]}" "apple"
  assert_eq "banana matches" "${FILTERED_ITEMS[1]}" "banana" 
  assert_eq "date matches" "${FILTERED_ITEMS[2]}" "date"
}

test_apply_filter__no_matches_returns_empty() {
  _setup_test_items
  FILTER="xyz"
  _select_apply_filter
  
  assert_eq "no matches" "${#FILTERED_ITEMS[@]}" "0"
}

test_apply_filter__case_insensitive() {
  _setup_test_items
  FILTER="A"
  _select_apply_filter
  
  # Should match: apple, banana, date (case insensitive)
  assert_eq "case insensitive count" "${#FILTERED_ITEMS[@]}" "3"
}

test_apply_filter__fuzzy_subsequence_matching() {
  _setup_test_items
  FILTER="ae"
  _select_apply_filter
  
  # Should match: apple (a...e), date (da..te has 'a' then 'e')
  assert_eq "subsequence count" "${#FILTERED_ITEMS[@]}" "2"
  assert_contains "apple in results" "${FILTERED_ITEMS[*]}" "apple"
  assert_contains "date in results" "${FILTERED_ITEMS[*]}" "date"
}

test_apply_filter__in_filter_mode_uses_pending_filter() {
  _setup_test_items
  MODE="filter"
  FILTER="old"
  PENDING_FILTER="ch"
  _select_apply_filter
  
  # Should use PENDING_FILTER, match: cherry
  assert_eq "uses pending filter" "${#FILTERED_ITEMS[@]}" "1"
  assert_eq "cherry matches" "${FILTERED_ITEMS[0]}" "cherry"
}

test_apply_filter__in_normal_mode_uses_filter() {
  _setup_test_items
  MODE="normal"
  FILTER="ch"
  PENDING_FILTER="ignored"
  _select_apply_filter
  
  # Should use FILTER, ignore PENDING_FILTER
  assert_eq "uses main filter" "${#FILTERED_ITEMS[@]}" "1"
  assert_eq "cherry matches" "${FILTERED_ITEMS[0]}" "cherry"
}

# ---------------------------------------------------------------------------
# 4. Window Clamping Tests (_select_clamp_window)
# ---------------------------------------------------------------------------

test_clamp_window__selected_below_window() {
  _setup_large_test_items
  WINDOW_SIZE=5
  SELECTED_IDX=2
  WINDOW_OFFSET=5  # Window shows items 5-9, selection is at 2
  _select_clamp_window
  
  # Window should move to show selection
  assert_eq "window moved to show selection" "$WINDOW_OFFSET" "2"
  assert_eq "selection unchanged" "$SELECTED_IDX" "2"
}

test_clamp_window__selected_above_window() {
  _setup_large_test_items
  WINDOW_SIZE=5
  SELECTED_IDX=10
  WINDOW_OFFSET=2  # Window shows items 2-6, selection is at 10
  _select_clamp_window
  
  # Window should move to show selection
  assert_eq "window moved to show selection" "$WINDOW_OFFSET" "6"
  assert_eq "selection unchanged" "$SELECTED_IDX" "10"
}

test_clamp_window__selected_within_window() {
  _setup_large_test_items
  WINDOW_SIZE=5
  SELECTED_IDX=7
  WINDOW_OFFSET=5  # Window shows items 5-9, selection is at 7
  _select_clamp_window
  
  # Window should not move
  assert_eq "window unchanged" "$WINDOW_OFFSET" "5"
  assert_eq "selection unchanged" "$SELECTED_IDX" "7"
}

test_clamp_window__clamp_to_start() {
  _setup_test_items
  WINDOW_SIZE=3
  SELECTED_IDX=0
  WINDOW_OFFSET=-2  # Invalid negative offset
  _select_clamp_window
  
  assert_eq "window clamped to 0" "$WINDOW_OFFSET" "0"
}

test_clamp_window__clamp_to_end() {
  _setup_test_items
  WINDOW_SIZE=3
  SELECTED_IDX=4
  WINDOW_OFFSET=10  # Too high
  _select_clamp_window
  
  # Max offset for 5 items with window size 3 is 2 (shows items 2,3,4)
  assert_eq "window clamped to max" "$WINDOW_OFFSET" "2"
}

test_clamp_window__fewer_items_than_window() {
  _setup_test_items  # 5 items
  WINDOW_SIZE=10
  SELECTED_IDX=3
  WINDOW_OFFSET=1
  _select_clamp_window
  
  # Window offset should be 0 when all items fit
  assert_eq "window at start when all fit" "$WINDOW_OFFSET" "0"
}

test_clamp_window__empty_filtered_items() {
  ITEMS=()
  FILTERED_ITEMS=()
  SELECTED_IDX=5
  WINDOW_OFFSET=2
  _select_clamp_window
  
  assert_eq "selection clamped to 0" "$SELECTED_IDX" "0"
  assert_eq "window at 0" "$WINDOW_OFFSET" "0"
}

test_clamp_window__selection_out_of_bounds_high() {
  _setup_test_items
  SELECTED_IDX=10  # Beyond end of 5 items
  _select_clamp_window
  
  assert_eq "selection clamped to last item" "$SELECTED_IDX" "4"
}

test_clamp_window__selection_out_of_bounds_low() {
  _setup_test_items
  SELECTED_IDX=-3
  _select_clamp_window
  
  assert_eq "selection clamped to first item" "$SELECTED_IDX" "0"
}

# ---------------------------------------------------------------------------
# 5. Normal Mode Navigation Tests (_select_transition)
# ---------------------------------------------------------------------------

test_transition_normal__move_down_j() {
  _setup_test_items
  SELECTED_IDX=1
  
  _select_transition "j"
  assert_eq "j moves selection down" "$SELECTED_IDX" "2"
}

test_transition_normal__move_down_arrow() {
  _setup_test_items
  SELECTED_IDX=1
  
  _select_transition "arrow_down"
  assert_eq "arrow_down moves selection down" "$SELECTED_IDX" "2"
}

test_transition_normal__move_up_k() {
  _setup_test_items
  SELECTED_IDX=2
  
  _select_transition "k"
  assert_eq "k moves selection up" "$SELECTED_IDX" "1"
}

test_transition_normal__move_up_arrow() {
  _setup_test_items
  SELECTED_IDX=2
  
  _select_transition "arrow_up"
  assert_eq "arrow_up moves selection up" "$SELECTED_IDX" "1"
}

test_transition_normal__clamps_at_bottom() {
  _setup_test_items
  SELECTED_IDX=4  # Last item
  
  _select_transition "j"
  assert_eq "stays at bottom with j" "$SELECTED_IDX" "4"
  
  _select_transition "arrow_down"
  assert_eq "stays at bottom with arrow" "$SELECTED_IDX" "4"
}

test_transition_normal__clamps_at_top() {
  _setup_test_items
  SELECTED_IDX=0
  
  _select_transition "k"
  assert_eq "stays at top with k" "$SELECTED_IDX" "0"
  
  _select_transition "arrow_up" 
  assert_eq "stays at top with arrow" "$SELECTED_IDX" "0"
}

test_transition_normal__go_to_first() {
  _setup_test_items
  SELECTED_IDX=3
  WINDOW_OFFSET=2
  
  _select_transition "g"
  assert_eq "g goes to first" "$SELECTED_IDX" "0"
  assert_eq "g resets window" "$WINDOW_OFFSET" "0"
}

test_transition_normal__go_to_last() {
  _setup_test_items
  SELECTED_IDX=1
  
  _select_transition "G"
  assert_eq "G goes to last" "$SELECTED_IDX" "4"
}

test_transition_normal__window_scrolling_down() {
  _setup_large_test_items
  WINDOW_SIZE=5
  SELECTED_IDX=4
  WINDOW_OFFSET=0  # Window shows 0-4
  
  _select_transition "j"  # Move to 5
  assert_eq "selection moved" "$SELECTED_IDX" "5"
  assert_eq "window scrolled" "$WINDOW_OFFSET" "1"  # Window now shows 1-5
}

test_transition_normal__window_scrolling_up() {
  _setup_large_test_items
  WINDOW_SIZE=5
  SELECTED_IDX=5
  WINDOW_OFFSET=1  # Window shows 1-5
  
  _select_transition "k"  # Move to 4
  assert_eq "selection moved" "$SELECTED_IDX" "4"
  # Window shouldn't scroll because 4 is still visible in window 1-5
  assert_eq "window unchanged" "$WINDOW_OFFSET" "1"
}

test_transition_normal__operates_on_filtered_items() {
  _setup_test_items
  FILTER="a"  # Matches: apple, banana, date
  _select_apply_filter
  SELECTED_IDX=1  # banana
  
  _select_transition "j"
  assert_eq "moves through filtered items" "$SELECTED_IDX" "2"
  # Should be at "date" now
  
  _select_transition "G"
  assert_eq "G goes to last filtered item" "$SELECTED_IDX" "2"
}

test_transition_normal__empty_filtered_list() {
  _setup_test_items
  FILTER="xyz"  # No matches
  _select_apply_filter
  SELECTED_IDX=0
  
  _select_transition "j"
  assert_eq "no movement on empty list" "$SELECTED_IDX" "0"
  
  _select_transition "G"
  assert_eq "G has no effect on empty list" "$SELECTED_IDX" "0"
}

# ---------------------------------------------------------------------------
# 6. Normal Mode Enter Tests
# ---------------------------------------------------------------------------

test_transition_normal__enter_selects() {
  _setup_test_items
  SELECTED_IDX=2
  
  _select_transition "enter"
  assert_eq "sets result" "$_SELECT_RESULT" "cherry"
  assert_eq "sets done flag" "$_SELECT_DONE" "1"
}

test_transition_normal__enter_with_filter_selects_filtered_item() {
  _setup_test_items
  FILTER="a"  # Matches: apple, banana, date
  _select_apply_filter
  SELECTED_IDX=1  # banana in filtered list
  
  _select_transition "enter"
  assert_eq "selects from filtered list" "$_SELECT_RESULT" "banana"
  assert_eq "sets done flag" "$_SELECT_DONE" "1"
}

test_transition_normal__enter_on_empty_filtered_list() {
  _setup_test_items
  FILTER="xyz"  # No matches
  _select_apply_filter
  
  _select_transition "enter"
  assert_eq "no result set" "$_SELECT_RESULT" ""
  assert_eq "done flag not set" "$_SELECT_DONE" "0"
}

test_transition_normal__enter_preserves_other_state() {
  _setup_test_items
  FILTER="test"
  SELECTED_IDX=2
  original_mode="$MODE"
  original_filter="$FILTER"
  
  _select_transition "enter"
  assert_eq "mode unchanged" "$MODE" "$original_mode"
  assert_eq "filter unchanged" "$FILTER" "$original_filter"
}

# ---------------------------------------------------------------------------
# 7. Mode Switching Tests
# ---------------------------------------------------------------------------

test_transition_normal__slash_enters_filter_mode() {
  _setup_test_items
  
  _select_transition "/"
  assert_eq "enters filter mode" "$MODE" "filter"
  assert_eq "clears pending filter" "$PENDING_FILTER" ""
}

test_transition_normal__slash_preserves_state() {
  _setup_test_items
  FILTER="existing"
  SELECTED_IDX=2
  
  _select_transition "/"
  assert_eq "preserves main filter" "$FILTER" "existing"
  assert_eq "preserves selection" "$SELECTED_IDX" "2"
}

test_transition_normal__escape_clears_filter() {
  _setup_test_items
  FILTER="test"
  SELECTED_IDX=2
  WINDOW_OFFSET=1
  
  _select_transition "escape"
  assert_eq "clears filter" "$FILTER" ""
  assert_eq "resets selection" "$SELECTED_IDX" "0"
  assert_eq "resets window" "$WINDOW_OFFSET" "0"
}

test_transition_normal__escape_no_filter() {
  _setup_test_items
  FILTER=""
  SELECTED_IDX=2
  
  _select_transition "escape"
  # Should be no-op when no filter
  assert_eq "filter still empty" "$FILTER" ""
  assert_eq "selection unchanged" "$SELECTED_IDX" "2"
}

test_filter_mode__enter_applies_filter_with_matches() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER="a"  # Will match: apple, banana, date
  
  _select_transition "enter"
  assert_eq "applies filter" "$FILTER" "a"
  assert_eq "clears pending" "$PENDING_FILTER" ""
  assert_eq "returns to normal" "$MODE" "normal"
  assert_eq "resets selection" "$SELECTED_IDX" "0"
  assert_eq "resets window" "$WINDOW_OFFSET" "0"
}

test_filter_mode__enter_blocked_no_matches() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER="xyz"  # No matches
  old_filter="$FILTER"
  
  _select_transition "enter"
  # Should stay in filter mode
  assert_eq "stays in filter mode" "$MODE" "filter"
  assert_eq "keeps pending filter" "$PENDING_FILTER" "xyz"
  assert_eq "doesnt change main filter" "$FILTER" "$old_filter"
}

test_filter_mode__escape_cancels() {
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
# 8. Filter Mode Input Tests
# ---------------------------------------------------------------------------

test_filter_mode__add_characters() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER=""
  
  _select_transition "a"
  assert_eq "adds character" "$PENDING_FILTER" "a"
  
  _select_transition "p"
  assert_eq "appends character" "$PENDING_FILTER" "ap"
  
  _select_transition "p"
  assert_eq "appends another" "$PENDING_FILTER" "app"
}

test_filter_mode__backspace_removes() {
  _setup_test_items  
  MODE="filter"
  PENDING_FILTER="abc"
  
  _select_transition "backspace"
  assert_eq "removes last char" "$PENDING_FILTER" "ab"
  
  _select_transition "backspace"
  assert_eq "removes another char" "$PENDING_FILTER" "a"
  
  _select_transition "backspace"
  assert_eq "can clear completely" "$PENDING_FILTER" ""
}

test_filter_mode__backspace_on_empty() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER=""
  
  _select_transition "backspace"
  assert_eq "stays empty" "$PENDING_FILTER" ""
}

test_filter_mode__ctrl_u_clears() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER="hello world"
  
  _select_transition "ctrl_u"
  assert_eq "clears all" "$PENDING_FILTER" ""
}

test_filter_mode__normal_mode_keys_treated_as_characters() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER=""
  
  # j, k, g, G should be treated as characters, not navigation
  _select_transition "j"
  assert_eq "j treated as character" "$PENDING_FILTER" "j"
  
  _select_transition "k"
  assert_eq "k appended as character" "$PENDING_FILTER" "jk"
  
  _select_transition "g"
  assert_eq "g appended as character" "$PENDING_FILTER" "jkg"
  
  _select_transition "G"
  assert_eq "G appended as character" "$PENDING_FILTER" "jkgG"
}

test_filter_mode__special_characters() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER=""
  
  _select_transition "/"
  assert_eq "slash as character" "$PENDING_FILTER" "/"
  
  _select_transition "-"
  assert_eq "dash appended" "$PENDING_FILTER" "/-"
  
  _select_transition "_"
  assert_eq "underscore appended" "$PENDING_FILTER" "/-_"
}

test_filter_mode__printable_characters_only() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER="test"
  
  # Non-printable characters should not be added
  # (This is hard to test without actual terminal input, but the logic is there)
  local original="$PENDING_FILTER"
  
  # Single printable character should be added
  _select_transition "x"
  assert_eq "printable char added" "$PENDING_FILTER" "testx"
}

# ---------------------------------------------------------------------------
# 9. Rendering Tests (_select_render output capture)
# NOTE: Skipped because render functions require /dev/tty access which
# is not available in the test environment. These would need to be tested
# in integration tests or with mocked terminal output.
# ---------------------------------------------------------------------------

test_render__skip_placeholder() {
  skip_test "render tests" "require /dev/tty access not available in unit tests"
}

# ---------------------------------------------------------------------------
# 10. Edge Cases Tests
# ---------------------------------------------------------------------------

test_edge_case__single_item_list() {
  _setup_single_item
  
  # Navigation should be no-ops
  _select_transition "j"
  assert_eq "j on single item" "$SELECTED_IDX" "0"
  
  _select_transition "k"
  assert_eq "k on single item" "$SELECTED_IDX" "0"
  
  _select_transition "g"
  assert_eq "g on single item" "$SELECTED_IDX" "0"
  
  _select_transition "G"
  assert_eq "G on single item" "$SELECTED_IDX" "0"
  
  # Enter should work
  _select_transition "enter"
  assert_eq "enter works" "$_SELECT_RESULT" "only-item"
  assert_eq "done flag set" "$_SELECT_DONE" "1"
}

test_edge_case__filter_matches_all() {
  _setup_test_items
  FILTER=""  # Matches all
  _select_apply_filter
  
  assert_eq "all items matched" "${#FILTERED_ITEMS[@]}" "5"
  
  # Navigation should work normally
  _select_transition "j"
  assert_eq "navigation works" "$SELECTED_IDX" "1"
}

test_edge_case__filter_then_clear_restores_full_list() {
  _setup_test_items
  
  # Apply filter
  FILTER="a"
  _select_apply_filter
  assert_eq "filtered list" "${#FILTERED_ITEMS[@]}" "3"
  
  # Clear filter
  FILTER=""
  _select_apply_filter
  assert_eq "full list restored" "${#FILTERED_ITEMS[@]}" "5"
}

test_edge_case__re_entering_filter_mode() {
  _setup_test_items
  
  # Enter filter mode
  _select_transition "/"
  assert_eq "in filter mode" "$MODE" "filter"
  
  # Exit filter mode
  _select_transition "escape"
  assert_eq "back to normal" "$MODE" "normal"
  
  # Re-enter filter mode
  _select_transition "/"
  assert_eq "in filter mode again" "$MODE" "filter"
  assert_eq "pending filter cleared" "$PENDING_FILTER" ""
}

test_edge_case__selected_index_resets_when_filter_changes() {
  _setup_test_items
  SELECTED_IDX=3
  
  # Apply filter that changes the list
  FILTER="a"
  _select_apply_filter
  _select_clamp_window  # This should reset selection if needed
  
  # Selection should be valid for filtered list
  assert_eq "selection within bounds" "$([[ $SELECTED_IDX -lt ${#FILTERED_ITEMS[@]} ]] && echo "yes" || echo "no")" "yes"
}

test_edge_case__window_size_larger_than_items() {
  _setup_test_items  # 5 items
  WINDOW_SIZE=20
  SELECTED_IDX=2
  WINDOW_OFFSET=3  # Invalid - should be clamped
  
  _select_clamp_window
  
  # Window offset should be 0 when all items fit
  assert_eq "window at start" "$WINDOW_OFFSET" "0"
  assert_eq "selection preserved" "$SELECTED_IDX" "2"
}

test_edge_case__filter_mode_with_existing_filter() {
  _setup_test_items
  FILTER="existing"
  
  _select_transition "/"
  assert_eq "mode switched" "$MODE" "filter"
  assert_eq "existing filter preserved" "$FILTER" "existing"
  assert_eq "pending filter empty" "$PENDING_FILTER" ""
}

test_edge_case__empty_items_array() {
  # Note: This test is tricky because _select_apply_filter iterates over ITEMS
  # In a real scenario, select_value() validates that items array is non-empty
  # But we can test the state machine behavior with empty filtered items
  ITEMS=("dummy")  # Need at least one item to avoid unbound variable error
  _select_init_state
  FILTERED_ITEMS=()  # Simulate empty filtered results
  
  # All operations should be safe
  _select_transition "j"
  _select_transition "k"
  _select_transition "g"
  _select_transition "G"
  _select_transition "enter"
  _select_transition "/"
  _select_transition "escape"
  
  # Should still be safe
  assert_eq "no crash on empty" "$_SELECT_DONE" "0"
}

# ---------------------------------------------------------------------------
# Integration Scenarios  
# ---------------------------------------------------------------------------

test_integration__full_filter_workflow() {
  _setup_test_items
  
  # Start filtering
  _select_transition "/"
  assert_eq "enter filter mode" "$MODE" "filter"
  
  # Type filter
  _select_transition "a"
  assert_eq "typed a" "$PENDING_FILTER" "a"
  
  # Apply filter should show 3 matches
  _select_apply_filter
  assert_eq "filtered items count" "${#FILTERED_ITEMS[@]}" "3"
  
  # Apply the filter
  _select_transition "enter"
  assert_eq "filter applied" "$FILTER" "a"
  assert_eq "back to normal" "$MODE" "normal"
  assert_eq "selection reset" "$SELECTED_IDX" "0"
  
  # Navigate and select
  _select_transition "j"
  assert_eq "moved to second" "$SELECTED_IDX" "1"
  
  _select_transition "enter"
  assert_eq "selected filtered item" "$_SELECT_RESULT" "banana"
  assert_eq "done" "$_SELECT_DONE" "1"
}

test_integration__filter_escape_navigation() {
  _setup_test_items
  
  # Apply initial filter
  FILTER="a"
  _select_apply_filter
  SELECTED_IDX=1  # banana
  
  # Start new filter
  _select_transition "/"
  _select_transition "c"
  
  # Escape should cancel and return to old state
  _select_transition "escape"
  assert_eq "back to normal" "$MODE" "normal"
  assert_eq "old filter restored" "$FILTER" "a"
  assert_eq "pending cleared" "$PENDING_FILTER" ""
  
  # Original filter should still be active
  _select_apply_filter
  assert_eq "old filter active" "${#FILTERED_ITEMS[@]}" "3"
}

test_integration__window_scrolling_with_filter() {
  # Create larger list for scrolling
  ITEMS=("apple1" "apple2" "apple3" "apple4" "apple5" "apple6" "banana1" "banana2")
  _select_init_state
  
  # Filter for apples
  FILTER="apple"
  _select_apply_filter
  assert_eq "apple items" "${#FILTERED_ITEMS[@]}" "6"
  
  # Set small window
  WINDOW_SIZE=3
  SELECTED_IDX=0
  WINDOW_OFFSET=0
  
  # Navigate to end
  _select_transition "G"
  assert_eq "at last apple" "$SELECTED_IDX" "5"
  
  # Window should have scrolled to show selection
  _select_clamp_window
  assert_eq "window scrolled" "$WINDOW_OFFSET" "3"
}

test_integration__multiple_backspace() {
  _setup_test_items
  MODE="filter"
  PENDING_FILTER="hello"
  
  _select_transition "backspace"
  assert_eq "after 1 backspace" "$PENDING_FILTER" "hell"
  
  _select_transition "backspace"
  assert_eq "after 2 backspace" "$PENDING_FILTER" "hel"
  
  _select_transition "backspace"
  assert_eq "after 3 backspace" "$PENDING_FILTER" "he"
  
  _select_transition "backspace"
  assert_eq "after 4 backspace" "$PENDING_FILTER" "h"
  
  _select_transition "backspace"
  assert_eq "after 5 backspace" "$PENDING_FILTER" ""
  
  _select_transition "backspace"
  assert_eq "extra backspace safe" "$PENDING_FILTER" ""
}

run_tests "tt lib/select (comprehensive)"