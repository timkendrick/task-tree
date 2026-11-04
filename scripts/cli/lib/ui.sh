# User interaction helpers for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _ui__log               — print diagnostic output to stderr
#   _ui__check_color       — test whether stdout accepts ANSI color sequences
#   _ui__check_log_level   — test whether a given log level is active
#   _ui__log_command       — trace a command line to stderr, shell-quoted
#   _ui__run_command       — run a command, tracing it when its level is active
#   _ui__prompt_raw        — open an editor on a template, return raw content
#   _ui__prompt            — open an editor on a template, return cleaned content
#
# Public constants:
#   _UI__LOG_LEVEL_OFF / _INFO / _VERBOSE — diagnostic log levels
#   _UI__OUTPUT_CAPTURE / _QUIET          — _ui__run_command output policies
#
# This module is also the designated home for NO_COLOR/color handling.

_ui__log() {
  printf '%s\n' "$*" >&2
}

# Usage: _ui__check_color
# Returns 0 when stdout is a terminal and NO_COLOR is unset or empty.
_ui__check_color() {
  [[ -t 1 && -z "${NO_COLOR:-}" ]]
}

# ---------------------------------------------------------------------------
# Command tracing
#
# TT_LOG selects how much of tt's underlying VCS activity is narrated to
# stderr:
#
#   unset (or any unrecognized value)  nothing is traced
#   info                               the mutations tt performs on the
#                                      repository, and their own output
#   verbose                            every underlying command, including
#                                      reads and internal plumbing
#
# Levels are numeric so that a caller expresses the threshold at which its
# invocation becomes interesting, rather than the executor having to classify
# the command itself. A read passes _UI__LOG_LEVEL_VERBOSE; a user-visible
# mutation passes _UI__LOG_LEVEL_INFO.
#
# TT_LOG affects diagnostics only. Under _UI__OUTPUT_CAPTURE the command's
# stdout is never redirected, and the exit status is the command's own at
# every level, so no value of TT_LOG can change what tt does or prints on
# stdout.
# ---------------------------------------------------------------------------

_UI__LOG_LEVEL_OFF=0
_UI__LOG_LEVEL_INFO=1
_UI__LOG_LEVEL_VERBOSE=2

# Output policies for _ui__run_command.
_UI__OUTPUT_CAPTURE=capture   # stdout is the caller's return value
_UI__OUTPUT_QUIET=quiet       # stdout is not wanted

# Usage: _ui__check_log_level LEVEL
# Returns 0 when the active TT_LOG log level is at least LEVEL.
#_UI__LOG_LEVEL_OFF always returns 1.
# Unrecognized TT_LOG values return 1.
_ui__check_log_level() {
  local want="$1" active
  case "${TT_LOG:-}" in
    info)    active="$_UI__LOG_LEVEL_INFO" ;;
    verbose) active="$_UI__LOG_LEVEL_VERBOSE" ;;
    *)       active="$_UI__LOG_LEVEL_OFF" ;;
  esac
  [[ "$want" -gt "$_UI__LOG_LEVEL_OFF" && "$active" -ge "$want" ]]
}

# Usage: _ui__log_command CMD ARG...
# Echoes "+ CMD ARG..." to stderr with every word shell-quoted, so the traced
# line can be pasted back into a shell and re-run verbatim. Quoting uses
# printf %q: it is backslash-heavy for arguments rich in metacharacters (VCS
# revsets, notably) but is the only rendering guaranteed to round-trip.
_ui__log_command() {
  { printf '+'; printf ' %q' "$@"; printf '\n'; } >&2
}

# Usage: _ui__run_command LEVEL OUTPUT CMD ARG...
#   LEVEL   log level at which this invocation is traced (_UI__LOG_LEVEL_*)
#   OUTPUT  _UI__OUTPUT_CAPTURE — stdout is the caller's return value and is
#                                 never redirected, at any log level
#           _UI__OUTPUT_QUIET   — stdout is not wanted
#
# Runs CMD ARG..., tracing the command line to stderr first when LEVEL is
# active and forwarding output the command would otherwise have had discarded.
# When LEVEL is not active the command's stderr — and, under _UI__OUTPUT_QUIET,
# its stdout — is discarded.
#
# The command runs in the caller's working directory. A caller needing it to
# run elsewhere wraps the call in its own subshell, so that the reason for the
# directory change is stated where that reason applies.
#
# Never logs anything else and never exits; returns the command's exit status.
_ui__run_command() {
  local level="$1" output="$2"; shift 2
  # The traced argv and the executed argv are the same "$@", so the trace
  # cannot drift from what actually runs.
  if _ui__check_log_level "$level"; then
    _ui__log_command "$@"
    if [[ "$output" == "$_UI__OUTPUT_QUIET" ]]; then "$@" >&2; else "$@"; fi
  else
    if [[ "$output" == "$_UI__OUTPUT_QUIET" ]]; then "$@" >/dev/null 2>&1; else "$@" 2>/dev/null; fi
  fi
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
