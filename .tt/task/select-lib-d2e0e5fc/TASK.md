---
title: "Implement select.sh interactive selector library"
status: IN-PROGRESS
created: 2026-06-15T13:35:39Z
updated: 2026-06-15T13:35:40Z
subtask: [ ] task/select-lib-tests-e57aa273
---
# Implement `scripts/cli/lib/select.sh` — Interactive selector library

## Overview

Implement a self-contained, reusable interactive selector as a Bash library at `scripts/cli/lib/select.sh`. This module exposes a `select_value` function that accepts via stdin a list of newline-separated string values and returns the single selected item via stdout.

All interactive behavior is modeled as a state machine with immediate-mode rendering.

## Public API

```bash
select_value()  # Reads items from stdin, interactively selects one, prints to stdout
```

## State Machine

### State Variables

```
MODE            = "normal" | "filter"
ITEMS[]         = full list of items (immutable input)
FILTER          = active filter string (applied in normal mode)
PENDING_FILTER  = filter being typed (in filter mode)
SELECTED_IDX    = index into FILTERED_ITEMS of highlighted item
WINDOW_OFFSET   = index of first visible item in filtered list
WINDOW_SIZE     = number of visible rows (terminal height - 2)

Derived:
  FILTERED_ITEMS[] = items matching FILTER (fuzzy)
```

### State Transitions

**Normal mode:**
- `j` / ↓: `SELECTED_IDX = min(SELECTED_IDX + 1, len(FILTERED_ITEMS) - 1)`, adjust window
- `k` / ↑: `SELECTED_IDX = max(SELECTED_IDX - 1, 0)`, adjust window
- `g`: `SELECTED_IDX = 0`, `WINDOW_OFFSET = 0`
- `G`: `SELECTED_IDX = len(FILTERED_ITEMS) - 1`, adjust window to show last page
- Enter: output `FILTERED_ITEMS[SELECTED_IDX]` to stdout, exit 0
- `/`: `MODE = "filter"`, `PENDING_FILTER = ""`

**Filter mode:**
- printable char: append to `PENDING_FILTER`
- Backspace: remove last char from `PENDING_FILTER`
- Ctrl-U: clear `PENDING_FILTER`
- Enter (if matches > 0): `FILTER = PENDING_FILTER`, `PENDING_FILTER = ""`, `MODE = "normal"`, `SELECTED_IDX = 0`, `WINDOW_OFFSET = 0`
- Enter (if matches == 0): no-op (blocked)
- Escape: `PENDING_FILTER = ""`, `MODE = "normal"` (keep existing FILTER)

### Fuzzy Matching

A value matches a filter if all characters in the filter appear in order in the value (case-insensitive). Example: filter `tsc` matches `task/some-command-abc12345`.

### Window Clamping

Whenever an active selection change would move the highlighted item outside the current window of `WINDOW_SIZE` items, the window shifts minimally to ensure the active item is visible, clamping to first/last item rather than overflowing.

## Key Functions

```bash
# Internal — State Machine
_select_init_state()      # Initialize state variables from items array
_select_apply_filter()    # Compute FILTERED_ITEMS from ITEMS + filter string
_select_fuzzy_match()     # Check if value matches filter; output match positions
_select_clamp_window()    # Adjust WINDOW_OFFSET so SELECTED_IDX is visible
_select_transition()      # Process a keypress and update state

# Internal — Rendering
_select_render()          # Render current state to /dev/tty
_select_render_item()     # Render single item (bold/underline as needed)
_select_clear_display()   # Clear previous render

# Internal — Input
_select_read_key()        # Read one keypress (handling escape sequences)
```

## Rendering (immediate mode)

On every state transition:
1. Clear previous output (move cursor up N lines + clear each line)
2. Compute visible window of items
3. For each visible item:
   - Normal mode: bold if selected, plain otherwise
   - Filter mode: underline matched characters
4. Render filter/prompt line at bottom:
   - Normal mode with filter: dim `filter: <FILTER>`
   - Filter mode: `/ <PENDING_FILTER>` with cursor
   - No filter in normal mode: blank line (or omit)

## Key Reading

Use `read -rsn1` for single character, then detect escape sequences:
- `\x1b[A` = up, `\x1b[B` = down
- `\x1b` alone = Escape key (with timeout to distinguish from arrow keys)
- `\x7f` or `\x08` = Backspace
- `\x15` = Ctrl-U
- `\x0a` or empty string from `read` = Enter

## Terminal Setup

- `stty raw -echo` on entry, restore on exit (trap)
- All UI output to `/dev/tty` (stderr is for errors, stdout is for the selected value)
- Hide cursor on entry, show on exit

## Error Handling

- Empty input list: print error to stderr, exit 1
- Non-TTY: print error to stderr, exit 1

## Testability

All state transitions are testable by:
1. Setting state variables directly
2. Calling `_select_transition` with a key
3. Asserting resulting state variables

Rendering can be tested by capturing `_select_render` output.
