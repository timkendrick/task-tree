# String, slug, ID, and timestamp helpers for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _string__first_line          — the first line of a multi-line string
#   _string__trim_text           — strip surrounding blank lines and trailing whitespace
#   _string__to_slug             — derive a slug from a free-form title
#   _string__validate_slug       — validate slug shape (errors to stderr)
#   _string__generate_hex        — random 8-character hex string for IDs
#   _string__generate_timestamp  — current ISO 8601 UTC timestamp

# Usage: _string__trim_text TEXT
# Prints TEXT without its leading blank lines (lines holding only whitespace
# count as blank), without trailing whitespace on each line, and without
# trailing blank lines or a final newline.
_string__trim_text() {
  local trimmed
  trimmed="$(printf '%s' "$1" | awk 'NF{found=1} found{print}' | sed -e 's/[[:space:]]*$//')"
  printf '%s' "$trimmed"
}

# Usage: _string__first_line TEXT
# Prints the first line of TEXT, without a trailing newline. Empty output for
# empty input.
#
# This is what a caller wanting one line of a line-oriented result uses, rather
# than piping it to `head`. Under `set -o pipefail` a truncated read is fatal:
# `head` closes the pipe once it has its line, the producer is killed by SIGPIPE
# on its next write, and the pipeline's status — 141 — fails the command that
# only wanted to look at the first line. Whether that happens depends on how
# much the producer still had to write and whether it fit the pipe buffer, so
# the bug surfaces only once a listing grows past one entry.
_string__first_line() {
  local text="$1"
  printf '%s' "${text%%$'\n'*}"
}

# Generate slug from title: replace non-alphanumeric with -, collapse consecutive, lowercase, trim.
_string__to_slug() {
  local t="$1"
  printf '%s' "$t" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | tr -s '-' | sed 's/^-//;s/-$//'
}

# Validate slug: only lowercase alphanumeric and single hyphens; no leading/trailing hyphens.
# Returns 0 if valid, 1 and logs error if invalid.
_string__validate_slug() {
  local s="$1"
  if [[ -z "$s" ]]; then
    _ui__log "Error: Slug cannot be empty"
    return 1
  fi
  if [[ "$s" =~ [A-Z] ]]; then
    _ui__log "Error: Slug must be lowercase: $s"
    return 1
  fi
  if [[ "$s" =~ ^- ]]; then
    _ui__log "Error: Slug cannot start with hyphen: $s"
    return 1
  fi
  if [[ "$s" =~ -$ ]]; then
    _ui__log "Error: Slug cannot end with hyphen: $s"
    return 1
  fi
  if [[ "$s" =~ -- ]]; then
    _ui__log "Error: Slug cannot contain consecutive hyphens: $s"
    return 1
  fi
  if [[ "$s" =~ [^a-z0-9-] ]]; then
    _ui__log "Error: Slug must contain only lowercase letters, digits, and hyphens: $s"
    return 1
  fi
  return 0
}

# Generate an 8-character random hex string for task/context IDs.
_string__generate_hex() {
  # Three draws of the shell's 15-bit generator, spread across 32 bits: the
  # ID only has to be unlikely to collide, and creation checks that it does
  # not.
  printf '%08x' "$(( ((RANDOM << 17) ^ (RANDOM << 2) ^ RANDOM) & 0xffffffff ))"
}

# Generate an ISO 8601 UTC timestamp (e.g. 2026-03-12T23:04:57Z).
_string__generate_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}
