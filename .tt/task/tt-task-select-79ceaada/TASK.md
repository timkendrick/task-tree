---
title: "Implement `tt task select` CLI command"
status: TODO
created: 2026-06-14T10:03:51Z
updated: 2026-06-14T10:03:51Z
---
Many `tt task` commands rely on knowing a specific task ID. This can be cumbersome as the unique task identifiers are not particularly human-friendly.

Let's add a `tt task select` command that when in an interactive TTY terminal allows the user to interactively select active (non-completed) task and project IDs, sorted alphabetically. The selected item will be printed to stdout.

When not in an interactive TTY terminal, the command should exit with an error.

All the interactive behavior should be extracted out into a common `scripts/cli/lib/select.sh` helper module that exposes a `select_value` function that accepts via stdin a list of newline-separated string values, and returns the single selected item via stdout.

Make sure the following modal selection behavior is implemented:

- 'normal' mode (default mode) - allows interactively scrolling through the list to select an item:
  - Presents the user with a visual list of the first N values (ordered as per the stdin list)
  - Shows the actively highlighted task in bold via ANSI escape codes to indicate current selection (defaults to selecting the first item)
  - Whenever an active selection change would move the actively highlighted task outside the current window of N values, the window shifts minimally to ensure the active item is visible, clamping to first/last item rather than overflowing
  - There is an internal filter value that allows fuzzy filtering of the list of values that are displayed (intially empty; i.e. all values are displayed). This filter can be updated by entering 'interactive filter' mode (see below).
  - Shortcut keys:
    - `j`/`k` keys (or down/up arrow keys respectively) allow the user to select the next/previous item respectively
    - `g` or `G` keys respectively selects the first or last item (and updates view accordingly)
    - Enter key prints the selected item to stdout and exits the function cleanly
    - `/` enters 'interactive filter' mode
- 'interactive filter' mode - allows the user to fuzzy-filter the list
  - the 'pending interactive filter' (initially empty) is a filter string that filters the visible window to include only values that include all the typed characters in that order, but not necessarily consecutively (no regex or reordering of values for now)
  - all matching values have the matched characters underlined via ANSI escape codes
  - this mode covers filtering, not selection: while in this mode there is no actively highlighted value
  - arrow keys / text character keys have their normal text-editing behavior rather than special list selection behavior
  - 'normal mode' shortcut keys are not active
  - Shortcut keys:
    - Enter key sets the 'normal' mode filter value to the 'pending interactive filter' value, returns to 'normal' mode, and clears the 'pending interactive filter' state 
    - Escape key returns to 'normal' mode (without changing the 'normal' mode filter value), and clears the 'pending interactive filter' state

The implementation should model the interactions entirely via state machine transitions and re-render the output on every state transition (immediate mode).

This file should be thoroughly unit tested: the module is complex with lots of stateful logic so all state transitions should be comprehensively covered by unit tests.
