#!/usr/bin/env bash
# Interactive selector library for tt CLI
# 
# Provides an interactive terminal-based selector that reads items from stdin
# and allows the user to select one using keyboard navigation and filtering.
#
# Features:
# - Vim-style navigation (j/k, arrow keys)
# - Fuzzy filtering with '/' key
# - Case-insensitive subsequence matching
# - Visual highlighting of matched characters in filter mode
# - Proper terminal cleanup and error handling
#
# Usage:
#   echo -e "item1\nitem2\nitem3" | select_value
#
# Key bindings:
#   j/↓     - Move selection down
#   k/↑     - Move selection up  
#   g       - Go to first item
#   G       - Go to last item
#   /       - Start filtering
#   Enter   - Select current item (or apply filter)
#   Escape  - Cancel filter (return to normal mode)
#   Backspace - Remove last filter character
#   Ctrl-U  - Clear entire filter

set -euo pipefail

# =============================================================================
# PUBLIC API
# =============================================================================

# select_value - Interactive selector that reads items from stdin and returns selection to stdout
# Usage: echo -e "item1\nitem2\nitem3" | select_value
select_value() {
  # Read all input items into array
  local items=()
  while IFS= read -r line; do
    items+=("$line")
  done

  # Validate input
  if [[ ${#items[@]} -eq 0 ]]; then
    echo "Error: No items to select from" >&2
    return 1
  fi

  # Check if we have a TTY for input/output
  if [[ ! -t 2 ]]; then
    echo "Error: select_value requires a TTY (stderr) for interactive display" >&2
    return 1
  fi
  
  # Check for /dev/tty access
  if [[ ! -e /dev/tty ]]; then
    echo "Error: /dev/tty not available" >&2
    return 1
  fi

  # Initialize state machine
  ITEMS=("${items[@]}")
  _select_init_state
  
  # Setup terminal
  _select_setup_terminal
  trap '_select_cleanup_terminal' EXIT
  
  # Main event loop
  _SELECT_KEY=""
  while [[ "${_SELECT_DONE:-0}" != "1" ]]; do
    _select_render
    _select_read_key
    _select_transition "$_SELECT_KEY"
  done
  
  # Clean up terminal before printing result so stdout isn't mixed with /dev/tty
  _select_cleanup_terminal
  trap - EXIT
  
  echo "${_SELECT_RESULT}"
  return 0
}

# =============================================================================
# STATE VARIABLES
# =============================================================================

# Core state machine variables
MODE="normal"
ITEMS=()
FILTER=""
PENDING_FILTER=""
SELECTED_IDX=0
WINDOW_OFFSET=0
WINDOW_SIZE=10
FILTERED_ITEMS=()

# Control variables
_SELECT_DONE=0
_SELECT_RESULT=""
_SELECT_KEY=""
_SELECT_PREV_LINES=0
_SELECT_ORIG_STTY=""

# =============================================================================
# STATE MACHINE FUNCTIONS
# =============================================================================

# Initialize state variables from items array
_select_init_state() {
  MODE="normal"
  FILTER=""
  PENDING_FILTER=""
  SELECTED_IDX=0
  WINDOW_OFFSET=0
  _SELECT_DONE=0
  _SELECT_RESULT=""
  _SELECT_PREV_LINES=0
  
  # Calculate window size (terminal height - 2 for prompt/status)
  local term_height
  term_height="$(tput lines 2>/dev/null || echo 24)"
  WINDOW_SIZE=$((term_height - 2))
  if [[ $WINDOW_SIZE -lt 3 ]]; then
    WINDOW_SIZE=3
  fi
  
  _select_apply_filter
}

# Compute FILTERED_ITEMS from ITEMS + current filter
_select_apply_filter() {
  FILTERED_ITEMS=()
  local filter_to_use="$FILTER"
  if [[ "$MODE" == "filter" ]]; then
    filter_to_use="$PENDING_FILTER"
  fi
  
  for item in "${ITEMS[@]}"; do
    if _select_fuzzy_match "$item" "$filter_to_use"; then
      FILTERED_ITEMS+=("$item")
    fi
  done
}

# Check if value matches filter (case-insensitive subsequence)
# Returns 0 if match, 1 if no match
# TODO: Also output match positions for rendering
_select_fuzzy_match() {
  local value="$1"
  local filter="$2"
  
  # Empty filter matches everything
  if [[ -z "$filter" ]]; then
    return 0
  fi
  
  # Simple case-insensitive subsequence check
  local value_len=${#value}
  local filter_len=${#filter}
  local filter_pos=0
  
  for ((i = 0; i < value_len && filter_pos < filter_len; i++)); do
    local v_char="${value:i:1}"
    local f_char="${filter:filter_pos:1}"
    
    # Simple case conversion for ASCII characters
    case "$v_char" in
      A) v_char="a" ;; B) v_char="b" ;; C) v_char="c" ;; D) v_char="d" ;; E) v_char="e" ;;
      F) v_char="f" ;; G) v_char="g" ;; H) v_char="h" ;; I) v_char="i" ;; J) v_char="j" ;;
      K) v_char="k" ;; L) v_char="l" ;; M) v_char="m" ;; N) v_char="n" ;; O) v_char="o" ;;
      P) v_char="p" ;; Q) v_char="q" ;; R) v_char="r" ;; S) v_char="s" ;; T) v_char="t" ;;
      U) v_char="u" ;; V) v_char="v" ;; W) v_char="w" ;; X) v_char="x" ;; Y) v_char="y" ;;
      Z) v_char="z" ;;
    esac
    
    case "$f_char" in
      A) f_char="a" ;; B) f_char="b" ;; C) f_char="c" ;; D) f_char="d" ;; E) f_char="e" ;;
      F) f_char="f" ;; G) f_char="g" ;; H) f_char="h" ;; I) f_char="i" ;; J) f_char="j" ;;
      K) f_char="k" ;; L) f_char="l" ;; M) f_char="m" ;; N) f_char="n" ;; O) f_char="o" ;;
      P) f_char="p" ;; Q) f_char="q" ;; R) f_char="r" ;; S) f_char="s" ;; T) f_char="t" ;;
      U) f_char="u" ;; V) f_char="v" ;; W) f_char="w" ;; X) f_char="x" ;; Y) f_char="y" ;;
      Z) f_char="z" ;;
    esac
    
    if [[ "$v_char" == "$f_char" ]]; then
      ((filter_pos++))
    fi
  done
  
  [[ $filter_pos -eq $filter_len ]]
}

# Adjust WINDOW_OFFSET so SELECTED_IDX is visible
_select_clamp_window() {
  local filtered_count=${#FILTERED_ITEMS[@]}
  
  # Handle empty list
  if [[ $filtered_count -eq 0 ]]; then
    SELECTED_IDX=0
    WINDOW_OFFSET=0
    return
  fi
  
  # Ensure SELECTED_IDX is within bounds
  if [[ $SELECTED_IDX -ge $filtered_count ]]; then
    SELECTED_IDX=$((filtered_count - 1))
  fi
  if [[ $SELECTED_IDX -lt 0 ]]; then
    SELECTED_IDX=0
  fi
  
  # Adjust window to keep selection visible
  if [[ $SELECTED_IDX -lt $WINDOW_OFFSET ]]; then
    WINDOW_OFFSET=$SELECTED_IDX
  elif [[ $SELECTED_IDX -ge $((WINDOW_OFFSET + WINDOW_SIZE)) ]]; then
    WINDOW_OFFSET=$((SELECTED_IDX - WINDOW_SIZE + 1))
  fi
  
  # Clamp window offset to valid range
  if [[ $WINDOW_OFFSET -lt 0 ]]; then
    WINDOW_OFFSET=0
  fi
  local max_offset=$((filtered_count - WINDOW_SIZE))
  if [[ $max_offset -lt 0 ]]; then
    max_offset=0
  fi
  if [[ $WINDOW_OFFSET -gt $max_offset ]]; then
    WINDOW_OFFSET=$max_offset
  fi
}

# Process a keypress and update state
_select_transition() {
  local key="$1"
  
  if [[ "$MODE" == "normal" ]]; then
    _select_transition_normal "$key"
  elif [[ "$MODE" == "filter" ]]; then
    _select_transition_filter "$key"
  fi
}

# Handle keys in normal mode
_select_transition_normal() {
  local key="$1"
  local filtered_count=${#FILTERED_ITEMS[@]}
  
  case "$key" in
    "j"|"arrow_down")
      if [[ $filtered_count -gt 0 ]]; then
        SELECTED_IDX=$((SELECTED_IDX + 1))
        if [[ $SELECTED_IDX -ge $filtered_count ]]; then
          SELECTED_IDX=$((filtered_count - 1))
        fi
        _select_clamp_window
      fi
      ;;
    "k"|"arrow_up")
      if [[ $filtered_count -gt 0 ]]; then
        SELECTED_IDX=$((SELECTED_IDX - 1))
        if [[ $SELECTED_IDX -lt 0 ]]; then
          SELECTED_IDX=0
        fi
        _select_clamp_window
      fi
      ;;
    "g")
      SELECTED_IDX=0
      WINDOW_OFFSET=0
      ;;
    "G")
      if [[ $filtered_count -gt 0 ]]; then
        SELECTED_IDX=$((filtered_count - 1))
        _select_clamp_window
      fi
      ;;
    "enter")
      if [[ $filtered_count -gt 0 ]]; then
        _SELECT_RESULT="${FILTERED_ITEMS[$SELECTED_IDX]}"
        _SELECT_DONE=1
      fi
      ;;
    "/")
      MODE="filter"
      PENDING_FILTER=""
      ;;
    "escape")
      if [[ -n "$FILTER" ]]; then
        FILTER=""
        SELECTED_IDX=0
        WINDOW_OFFSET=0
        _select_apply_filter
        _select_clamp_window
      fi
      ;;
  esac
}

# Handle keys in filter mode
_select_transition_filter() {
  local key="$1"
  
  case "$key" in
    "enter")
      # Apply filter if there are matches
      _select_apply_filter
      if [[ ${#FILTERED_ITEMS[@]} -gt 0 ]]; then
        FILTER="$PENDING_FILTER"
        PENDING_FILTER=""
        MODE="normal"
        SELECTED_IDX=0
        WINDOW_OFFSET=0
        _select_apply_filter
        _select_clamp_window
      fi
      ;;
    "escape")
      PENDING_FILTER=""
      MODE="normal"
      _select_apply_filter
      _select_clamp_window
      ;;
    "backspace")
      if [[ ${#PENDING_FILTER} -gt 0 ]]; then
        PENDING_FILTER="${PENDING_FILTER%?}"
        _select_apply_filter
        _select_clamp_window
      fi
      ;;
    "ctrl_u")
      PENDING_FILTER=""
      _select_apply_filter
      _select_clamp_window
      ;;
    *)
      # Add printable characters to filter
      if [[ ${#key} -eq 1 && "$key" =~ [[:print:]] ]]; then
        PENDING_FILTER="${PENDING_FILTER}${key}"
        _select_apply_filter
        _select_clamp_window
      fi
      ;;
  esac
}

# =============================================================================
# RENDERING FUNCTIONS
# =============================================================================

# Render current state to /dev/tty
_select_render() {
  # Clear previous output
  _select_clear_display
  
  # Recompute filtered items and window
  _select_apply_filter
  _select_clamp_window
  
  local output_lines=0
  local filtered_count=${#FILTERED_ITEMS[@]}
  
  # Show items in current window
  if [[ $filtered_count -eq 0 ]]; then
    printf "\033[2mNo matches\033[0m\r\n" > /dev/tty
    output_lines=$((output_lines + 1))
  else
    local window_end=$((WINDOW_OFFSET + WINDOW_SIZE))
    if [[ $window_end -gt $filtered_count ]]; then
      window_end=$filtered_count
    fi
    
    for ((i = WINDOW_OFFSET; i < window_end; i++)); do
      local item="${FILTERED_ITEMS[$i]}"
      if [[ "$MODE" == "normal" && $i -eq $SELECTED_IDX ]]; then
        _select_render_item "$item" "selected"
      else
        _select_render_item "$item" "normal"
      fi
      output_lines=$((output_lines + 1))
    done
  fi
  
  # Show status/prompt line
  if [[ "$MODE" == "filter" ]]; then
    printf "\033[2mfilter: \033[0m%s" "$PENDING_FILTER" > /dev/tty
  elif [[ -n "$FILTER" ]]; then
    printf "\033[2mfilter: %s\033[0m" "$FILTER" > /dev/tty
  else
    printf "\033[2mpress \"/\" to filter %s\033[0m" > /dev/tty
  fi
  output_lines=$((output_lines + 1))
  
  _SELECT_PREV_LINES=$output_lines
}

# Render single item with appropriate formatting
_select_render_item() {
  local item="$1"
  local style="$2"
  
  if [[ "$MODE" == "filter" && -n "$PENDING_FILTER" ]]; then
    # In filter mode, highlight matching characters
    local rendered_item
    rendered_item="$(_select_highlight_matches "$item" "$PENDING_FILTER")"
    if [[ "$style" == "selected" ]]; then
      printf "> \033[1m%b\033[0m\r\n" "$rendered_item" > /dev/tty
    else
      printf "  %b\r\n" "$rendered_item" > /dev/tty
    fi
  else
    # Normal rendering
    if [[ "$style" == "selected" ]]; then
      printf "> \033[1m%s\033[0m\r\n" "$item" > /dev/tty
    else
      printf "  %s\r\n" "$item" > /dev/tty
    fi
  fi
}

# Clear previous render
_select_clear_display() {
  if [[ $_SELECT_PREV_LINES -gt 0 ]]; then
    # Clear current line (status/prompt), then move up and clear each item line
    printf "\r\033[2K" > /dev/tty
    local i
    for ((i = 1; i < _SELECT_PREV_LINES; i++)); do
      printf "\033[A\033[2K" > /dev/tty
    done
  fi
}

# Highlight matching characters in an item for filter display
_select_highlight_matches() {
  local item="$1"
  local filter="$2"
  
  if [[ -z "$filter" ]]; then
    printf '%s' "$item"
    return
  fi
  
  local result=""
  local item_len=${#item}
  local filter_len=${#filter}
  local filter_pos=0
  
  for ((i = 0; i < item_len && filter_pos < filter_len; i++)); do
    local char="${item:i:1}"
    local filter_char="${filter:filter_pos:1}"
    
    # Convert to lowercase for comparison (same logic as fuzzy match)
    local char_lower="$char"
    local filter_char_lower="$filter_char"
    
    case "$char" in
      A) char_lower="a" ;; B) char_lower="b" ;; C) char_lower="c" ;; D) char_lower="d" ;; E) char_lower="e" ;;
      F) char_lower="f" ;; G) char_lower="g" ;; H) char_lower="h" ;; I) char_lower="i" ;; J) char_lower="j" ;;
      K) char_lower="k" ;; L) char_lower="l" ;; M) char_lower="m" ;; N) char_lower="n" ;; O) char_lower="o" ;;
      P) char_lower="p" ;; Q) char_lower="q" ;; R) char_lower="r" ;; S) char_lower="s" ;; T) char_lower="t" ;;
      U) char_lower="u" ;; V) char_lower="v" ;; W) char_lower="w" ;; X) char_lower="x" ;; Y) char_lower="y" ;;
      Z) char_lower="z" ;;
    esac
    
    case "$filter_char" in
      A) filter_char_lower="a" ;; B) filter_char_lower="b" ;; C) filter_char_lower="c" ;; D) filter_char_lower="d" ;; E) filter_char_lower="e" ;;
      F) filter_char_lower="f" ;; G) filter_char_lower="g" ;; H) filter_char_lower="h" ;; I) filter_char_lower="i" ;; J) filter_char_lower="j" ;;
      K) filter_char_lower="k" ;; L) filter_char_lower="l" ;; M) filter_char_lower="m" ;; N) filter_char_lower="n" ;; O) filter_char_lower="o" ;;
      P) filter_char_lower="p" ;; Q) filter_char_lower="q" ;; R) filter_char_lower="r" ;; S) filter_char_lower="s" ;; T) filter_char_lower="t" ;;
      U) filter_char_lower="u" ;; V) filter_char_lower="v" ;; W) filter_char_lower="w" ;; X) filter_char_lower="x" ;; Y) filter_char_lower="y" ;;
      Z) filter_char_lower="z" ;;
    esac
    
    if [[ "$char_lower" == "$filter_char_lower" ]]; then
      # Highlight this character
      result+="\033[4m${char}\033[24m"
      ((filter_pos++))
    else
      result+="$char"
    fi
  done
  
  # Add any remaining characters
  if [[ $i -lt $item_len ]]; then
    result+="${item:i}"
  fi
  
  printf '%s' "$result"
}

# =============================================================================
# INPUT/TERMINAL FUNCTIONS
# =============================================================================

# Read one keypress and normalize to standard key names.
# Sets the global _SELECT_KEY variable.
_select_read_key() {
  local char
  
  # Read single character
  read -rsn1 char < /dev/tty
  
  case "$char" in
    $'\x1b') # Escape sequence or ESC key
      # Arrow keys send 3 bytes: \x1b [ A/B. Read the next two bytes.
      # bash 3.2's read -t doesn't work reliably in raw mode, so we
      # use a blocking read with a very short TMOUT-based approach:
      # just read the next char (the terminal sends them in a burst).
      local seq1="" seq2=""
      read -rsn1 seq1 < /dev/tty
      if [[ "$seq1" == "[" ]]; then
        read -rsn1 seq2 < /dev/tty
        case "$seq2" in
          'A') _SELECT_KEY="arrow_up" ;;
          'B') _SELECT_KEY="arrow_down" ;;
          *) _SELECT_KEY="escape" ;;
        esac
      else
        _SELECT_KEY="escape"
      fi
      ;;
    $'\n'|'') _SELECT_KEY="enter" ;;
    $'\x7f'|$'\x08') _SELECT_KEY="backspace" ;;
    $'\x15') _SELECT_KEY="ctrl_u" ;;
    *) _SELECT_KEY="$char" ;;
  esac
}

# Setup terminal for interactive use
_select_setup_terminal() {
  # Save current terminal state (operate on /dev/tty, not stdin which may be a pipe)
  _SELECT_ORIG_STTY="$(stty -g < /dev/tty)"
  
  # Set raw mode without echo
  stty raw -echo < /dev/tty
  
  # Hide cursor
  printf "\033[?25l" > /dev/tty
}

# Restore terminal state
_select_cleanup_terminal() {
  # Clear any remaining output
  _select_clear_display
  
  # Show cursor
  printf "\033[?25h" > /dev/tty 2>/dev/null || true
  
  # Restore terminal state
  if [[ -n "${_SELECT_ORIG_STTY:-}" ]]; then
    stty "$_SELECT_ORIG_STTY" < /dev/tty 2>/dev/null || true
  fi
}
