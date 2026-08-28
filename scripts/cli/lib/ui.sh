# User interaction helpers for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _ui__log         — print diagnostic output to stderr
#   _ui__prompt_raw  — open an editor on a template, return raw content
#   _ui__prompt      — open an editor on a template, return cleaned content
#   _ui__select_raw  — built-in minimal picker (renders to stderr, reads /dev/tty)
#   _ui__select      — interactive selection from newline-separated options
#
# This module is also the designated home for NO_COLOR/color handling. No
# command currently emits ANSI escape sequences, so that surface is
# intentionally empty for now.

_ui__log() {
  printf '%s\n' "$*" >&2
}

# Usage: raw=$(_ui__prompt_raw <<< "$template")
# Reads template from stdin, opens editor, returns raw file content (no stripping).
# Exits non-zero if editor exits non-zero.
# On editor failure, the temporary file is retained on disk and its path is
# printed to stderr so the user can recover any unsaved edits.
_ui__prompt_raw() {
  local editor
  # Note: we use `vim` rather than `vi` because to ensure POSIX compliance, when it is invoked as `vi`,
  # vim exits with a non-zero status when an error is encountered at any point during the editing session
  # see https://stackoverflow.com/q/46665403
  DEFAULT_EDITOR="vim"
  editor="${TT_EDITOR:-${GIT_EDITOR:-${VISUAL:-${EDITOR:-$DEFAULT_EDITOR}}}}"
  local tmpfile
  tmpfile="$(mktemp -t TT_EDITMSG)"
  trap 'rm -f "$tmpfile"' RETURN
  cat > "$tmpfile"
  "$editor" "$tmpfile" </dev/tty >/dev/tty || {
    trap - RETURN
    _ui__log "Error: Editor exited with non-zero status."
    _ui__log "  Editor contents: $tmpfile"
    return 1;
  }
  cat "$tmpfile"
}

# Usage: message=$(_ui__prompt <<< "$template")
# Reads template from stdin, opens editor, strips #-comment lines, trims trailing
# whitespace and surrounding blank lines, prints cleaned text to stdout (empty
# string if blank after stripping).
# Leading whitespace within a line is preserved, so indented content such as a
# nested task tree survives the round trip through the editor.
# Exits non-zero if editor exits non-zero.
_ui__prompt() {
  local raw
  raw="$(_ui__prompt_raw)" || return 1
  local msg
  msg="$(printf '%s' "$raw" | sed '/^#/d' | sed -e 's/[[:space:]]*$//')"
  # trim leading/trailing blank lines
  msg="$(printf '%s' "$msg" | awk 'NF{found=1} found{print}')"
  printf '%s' "$msg"
}

# Usage: _ui__select_raw OPTION...
# Renders the built-in minimal picker UI to stderr and reads one line from
# /dev/tty. The raw reply is printed to stdout (validation is the caller's job).
# Returns 1 if no interactive terminal is available or the read fails.
_ui__select_raw() {
  # /dev/tty exists as a device node even without a controlling terminal, so
  # test that it can actually be opened rather than relying on [[ -e ]].
  # Redirections are applied left to right, so stderr must be silenced *before*
  # the /dev/tty open is attempted or bash reports the failure itself.
  if ! : 2>/dev/null </dev/tty; then
    echo "Error: no interactive terminal available (set TT_SELECT to use a custom picker)" >&2
    return 1
  fi

  {
    printf 'Select an option:\n\n'
    printf '%s\n' "$@"
    printf '\n> '
  } >&2

  local reply
  IFS= read -r reply </dev/tty || return 1
  printf '%s\n' "$reply"
}

# Usage: printf '%s\n' item... | _ui__select
# Reads newline-separated options from stdin, presents a picker, and writes the
# selected option to stdout.
#
# When TT_SELECT is set it is run via `sh -c` as the picker: it receives the
# options on stdin and must write exactly one of them to stdout. Otherwise the
# built-in picker (_ui__select_raw) is used.
#
# Returns 1 if no options were provided, if the picker fails, or if the picker's
# output does not exactly match one of the provided options.
_ui__select() {
  local options=() line
  while IFS= read -r line; do
    [[ -n "$line" ]] && options+=("$line")
  done

  if [[ ${#options[@]} -eq 0 ]]; then
    echo "Error: no options provided" >&2
    return 1
  fi

  local choice
  if [[ -n "${TT_SELECT:-}" ]]; then
    choice="$(printf '%s\n' "${options[@]}" | sh -c "$TT_SELECT")" || {
      echo "Error: picker command failed: $TT_SELECT" >&2
      return 1
    }
  else
    choice="$(_ui__select_raw "${options[@]}")" || return 1
  fi

  local option
  for option in "${options[@]}"; do
    if [[ "$option" == "$choice" ]]; then
      printf '%s\n' "$choice"
      return 0
    fi
  done

  echo "Error: invalid selection: $choice" >&2
  return 1
}
