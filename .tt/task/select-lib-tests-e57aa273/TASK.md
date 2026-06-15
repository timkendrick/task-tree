---
title: "Unit tests for select.sh state machine"
status: DONE
created: 2026-06-15T13:35:46Z
updated: 2026-06-15T13:35:47Z
---
# Unit tests for `scripts/cli/lib/select.sh`

## Overview

Comprehensive unit test suite for the interactive selector state machine at `scripts/cli/lib/select.sh`. Tests are located at `scripts/cli/lib/select.test.sh`.

The test suite exercises all state machine transitions, fuzzy matching, window management, rendering, and edge cases.

## Test Harness

Follow the same `bats`-based test harness used by other tests in the project. Source `select.sh` and test internal functions directly by setting state variables, calling transition functions, and asserting results.

## Test Categories & Pseudocode

### 1. Fuzzy Matching (`_select_fuzzy_match`)

```
test "exact match returns success"
  → _select_fuzzy_match "hello" "hello" → exit 0

test "subsequence match returns success"
  → _select_fuzzy_match "task/some-command-abc12345" "tsc" → exit 0

test "no match returns failure"
  → _select_fuzzy_match "hello" "xyz" → exit 1

test "case-insensitive match"
  → _select_fuzzy_match "Hello World" "hw" → exit 0

test "empty filter matches everything"
  → _select_fuzzy_match "anything" "" → exit 0

test "filter longer than value fails"
  → _select_fuzzy_match "ab" "abc" → exit 1

test "match positions output — exact"
  → _select_fuzzy_match "hello" "hlo" → stdout contains positions "0 2 4" (or similar)

test "match positions output — subsequence"
  → _select_fuzzy_match "abcdef" "ace" → positions "0 2 4"

test "repeated characters match greedily left-to-right"
  → _select_fuzzy_match "aabaa" "aa" → positions "0 1"

test "special characters in filter"
  → _select_fuzzy_match "foo/bar-baz" "/b" → exit 0, positions for / and b

test "empty value with empty filter matches"
  → _select_fuzzy_match "" "" → exit 0

test "empty value with non-empty filter fails"
  → _select_fuzzy_match "" "a" → exit 1
```

### 2. State Initialization (`_select_init_state`)

```
test "initializes with correct defaults"
  → set ITEMS=(alpha beta gamma), call _select_init_state
  → MODE="normal", FILTER="", PENDING_FILTER="", SELECTED_IDX=0, WINDOW_OFFSET=0
  → FILTERED_ITEMS=(alpha beta gamma)

test "empty items list"
  → set ITEMS=(), call _select_init_state
  → FILTERED_ITEMS=(), SELECTED_IDX=0
```

### 3. Filter Application (`_select_apply_filter`)

```
test "empty filter returns all items"
  → ITEMS=(a b c), FILTER="", _select_apply_filter
  → FILTERED_ITEMS=(a b c)

test "filter reduces items"
  → ITEMS=(apple banana cherry), FILTER="an", _select_apply_filter
  → FILTERED_ITEMS=(banana)

test "filter with no matches returns empty"
  → ITEMS=(apple banana cherry), FILTER="xyz", _select_apply_filter
  → FILTERED_ITEMS=()

test "filter is case-insensitive"
  → ITEMS=(Apple BANANA cherry), FILTER="ap", _select_apply_filter
  → FILTERED_ITEMS=(Apple)

test "fuzzy filter matches subsequences"
  → ITEMS=(task/foo-abc task/bar-def proj/baz-ghi), FILTER="tf", _select_apply_filter
  → FILTERED_ITEMS=(task/foo-abc)
```

### 4. Window Clamping (`_select_clamp_window`)

```
test "selected below window scrolls down"
  → WINDOW_SIZE=3, WINDOW_OFFSET=0, SELECTED_IDX=4, FILTERED_ITEMS has 10 items
  → _select_clamp_window
  → WINDOW_OFFSET=2 (minimal shift: 4 - 3 + 1 = 2)

test "selected above window scrolls up"
  → WINDOW_SIZE=3, WINDOW_OFFSET=5, SELECTED_IDX=3
  → _select_clamp_window
  → WINDOW_OFFSET=3

test "selected within window — no change"
  → WINDOW_SIZE=3, WINDOW_OFFSET=2, SELECTED_IDX=3
  → _select_clamp_window
  → WINDOW_OFFSET=2 (unchanged)

test "clamp to start"
  → WINDOW_SIZE=3, WINDOW_OFFSET=5, SELECTED_IDX=0
  → _select_clamp_window
  → WINDOW_OFFSET=0

test "clamp to end"
  → WINDOW_SIZE=3, FILTERED_ITEMS has 10 items, SELECTED_IDX=9
  → _select_clamp_window
  → WINDOW_OFFSET=7 (10 - 3)

test "fewer items than window"
  → WINDOW_SIZE=10, FILTERED_ITEMS has 3 items, SELECTED_IDX=2
  → _select_clamp_window
  → WINDOW_OFFSET=0
```

### 5. Normal Mode Navigation (`_select_transition`)

```
test "j moves selection down"
  → MODE=normal, SELECTED_IDX=0, FILTERED_ITEMS has 5 items
  → _select_transition "j"
  → SELECTED_IDX=1

test "j at last item is no-op"
  → MODE=normal, SELECTED_IDX=4, FILTERED_ITEMS has 5 items
  → _select_transition "j"
  → SELECTED_IDX=4

test "k moves selection up"
  → MODE=normal, SELECTED_IDX=2
  → _select_transition "k"
  → SELECTED_IDX=1

test "k at first item is no-op"
  → MODE=normal, SELECTED_IDX=0
  → _select_transition "k"
  → SELECTED_IDX=0

test "down arrow moves selection down"
  → MODE=normal, SELECTED_IDX=0
  → _select_transition "arrow_down"
  → SELECTED_IDX=1

test "up arrow moves selection up"
  → MODE=normal, SELECTED_IDX=2
  → _select_transition "arrow_up"
  → SELECTED_IDX=1

test "g selects first item"
  → MODE=normal, SELECTED_IDX=5, WINDOW_OFFSET=3
  → _select_transition "g"
  → SELECTED_IDX=0, WINDOW_OFFSET=0

test "G selects last item"
  → MODE=normal, SELECTED_IDX=0, FILTERED_ITEMS has 10 items, WINDOW_SIZE=3
  → _select_transition "G"
  → SELECTED_IDX=9, WINDOW_OFFSET=7

test "j triggers window scroll when moving past visible area"
  → MODE=normal, WINDOW_SIZE=3, WINDOW_OFFSET=0, SELECTED_IDX=2, FILTERED_ITEMS has 10 items
  → _select_transition "j"
  → SELECTED_IDX=3, WINDOW_OFFSET=1

test "k triggers window scroll when moving above visible area"
  → MODE=normal, WINDOW_SIZE=3, WINDOW_OFFSET=3, SELECTED_IDX=3
  → _select_transition "k"
  → SELECTED_IDX=2, WINDOW_OFFSET=2

test "navigation with active filter operates on filtered items"
  → ITEMS=(apple banana cherry date), FILTER="a", apply filter
  → FILTERED_ITEMS=(apple banana date)
  → MODE=normal, SELECTED_IDX=0
  → _select_transition "j" → SELECTED_IDX=1 (banana)
  → _select_transition "G" → SELECTED_IDX=2 (date)
```

### 6. Normal Mode Enter

```
test "enter outputs selected item"
  → MODE=normal, SELECTED_IDX=1, FILTERED_ITEMS=(alpha beta gamma)
  → _select_transition "enter"
  → _SELECT_RESULT="beta", _SELECT_DONE=1

test "enter with filter outputs filtered item"
  → ITEMS=(apple banana cherry), FILTER="an"
  → FILTERED_ITEMS=(banana), SELECTED_IDX=0
  → _select_transition "enter"
  → _SELECT_RESULT="banana", _SELECT_DONE=1

test "enter on empty filtered list is no-op"
  → FILTERED_ITEMS=(), MODE=normal
  → _select_transition "enter"
  → _SELECT_DONE=0 (not set / blocked)
```

### 7. Mode Switching

```
test "/ enters filter mode"
  → MODE=normal
  → _select_transition "/"
  → MODE=filter, PENDING_FILTER=""

test "/ clears any previous pending filter"
  → MODE=normal, PENDING_FILTER="leftover"
  → _select_transition "/"
  → MODE=filter, PENDING_FILTER=""

test "escape in filter mode returns to normal"
  → MODE=filter, FILTER="existing", PENDING_FILTER="partial"
  → _select_transition "escape"
  → MODE=normal, FILTER="existing", PENDING_FILTER=""

test "enter in filter mode commits filter"
  → MODE=filter, PENDING_FILTER="ap", ITEMS=(apple banana apricot cherry)
  → _select_transition "enter"
  → MODE=normal, FILTER="ap", PENDING_FILTER=""
  → SELECTED_IDX=0, WINDOW_OFFSET=0
  → FILTERED_ITEMS=(apple apricot)

test "enter in filter mode with no matches is blocked"
  → MODE=filter, PENDING_FILTER="xyz", ITEMS=(apple banana)
  → _select_transition "enter"
  → MODE=filter (unchanged), PENDING_FILTER="xyz" (unchanged)
```

### 8. Filter Mode Input

```
test "character appends to pending filter"
  → MODE=filter, PENDING_FILTER="ab"
  → _select_transition "c"
  → PENDING_FILTER="abc"

test "backspace removes last character"
  → MODE=filter, PENDING_FILTER="abc"
  → _select_transition "backspace"
  → PENDING_FILTER="ab"

test "backspace on empty pending filter is no-op"
  → MODE=filter, PENDING_FILTER=""
  → _select_transition "backspace"
  → PENDING_FILTER=""

test "ctrl-u clears pending filter"
  → MODE=filter, PENDING_FILTER="hello"
  → _select_transition "ctrl_u"
  → PENDING_FILTER=""

test "normal mode keys are not active in filter mode"
  → MODE=filter, PENDING_FILTER=""
  → _select_transition "j" → PENDING_FILTER="j" (appended as character, not navigation)
  → _select_transition "k" → PENDING_FILTER="jk"
  → _select_transition "g" → PENDING_FILTER="jkg"
  → _select_transition "G" → PENDING_FILTER="jkgG"
```

### 9. Rendering

```
test "normal mode: selected item is bold"
  → MODE=normal, SELECTED_IDX=1, FILTERED_ITEMS=(a b c), WINDOW_OFFSET=0, WINDOW_SIZE=5
  → capture _select_render output
  → line 0: plain "a"
  → line 1: bold "b" (contains \e[1m...\e[0m)
  → line 2: plain "c"

test "filter mode: matched chars are underlined"
  → MODE=filter, PENDING_FILTER="ac", ITEMS=(abcdef xyz), compute matching
  → capture _select_render output
  → "abcdef" has 'a' and 'c' underlined (contains \e[4m)

test "filter mode: prompt line shows / <text>"
  → MODE=filter, PENDING_FILTER="hello"
  → capture _select_render output
  → last line contains "/ hello"

test "normal mode with filter: shows filter indicator"
  → MODE=normal, FILTER="abc"
  → capture _select_render output
  → contains "filter: abc" (dimmed)

test "no matches shows message"
  → MODE=filter, PENDING_FILTER="xyz", FILTERED_ITEMS=()
  → capture _select_render output
  → contains "No matches"

test "window shows correct subset"
  → WINDOW_SIZE=2, WINDOW_OFFSET=1, FILTERED_ITEMS=(a b c d e)
  → capture _select_render output
  → shows "b" and "c" only

test "normal mode no filter: no filter line"
  → MODE=normal, FILTER=""
  → capture _select_render output
  → no "filter:" line
```

### 10. Edge Cases

```
test "single item list — enter immediately selects it"
  → ITEMS=(only), init state
  → SELECTED_IDX=0
  → _select_transition "enter" → result="only"

test "single item — j and k are no-ops"
  → ITEMS=(only), SELECTED_IDX=0
  → _select_transition "j" → SELECTED_IDX=0
  → _select_transition "k" → SELECTED_IDX=0

test "filter that matches all items"
  → ITEMS=(aa ab ac), FILTER="a"
  → FILTERED_ITEMS=(aa ab ac)

test "filter then clear filter restores full list"
  → ITEMS=(apple banana cherry)
  → set FILTER="ap", apply → FILTERED_ITEMS=(apple)
  → enter filter mode, type nothing, enter → FILTER="", FILTERED_ITEMS=(apple banana cherry)

test "re-entering filter mode after previous filter"
  → FILTER="an", press "/", type "ch", enter
  → FILTER="ch", FILTERED_ITEMS=(cherry)

test "selected index resets when filter changes"
  → ITEMS=(alpha beta gamma), SELECTED_IDX=2
  → enter filter mode, type "b", enter
  → FILTER="b", SELECTED_IDX=0, FILTERED_ITEMS=(beta)

test "window size larger than items"
  → ITEMS=(a b), WINDOW_SIZE=10
  → WINDOW_OFFSET=0, all items visible, G → SELECTED_IDX=1, WINDOW_OFFSET=0
```

## Implementation Notes

- Source `select.sh` at top of test file
- Use helper functions to set up state (populate ITEMS, call `_select_init_state`)
- Test `_select_transition` by passing key names like "j", "k", "enter", "escape", "backspace", "ctrl_u", "arrow_up", "arrow_down", "/", or literal characters
- Test rendering by redirecting `_select_render` output to a variable and pattern-matching ANSI codes
- Override `WINDOW_SIZE` to small values (e.g. 3) for deterministic window tests
