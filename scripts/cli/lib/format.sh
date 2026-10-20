# Display formatting helpers for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _format__status_checkbox — map a task status field to a GFM checkbox string
#   _format__aligned_block   — '---'-delimited block of aligned 'KEY: VALUE' lines

# Map a task status field to a GFM checkbox string.
# TODO -> [ ], IN-PROGRESS -> [-], DONE/Done -> [x], else [ ]
_format__status_checkbox() {
  local s="$1"
  case "$s" in
    TODO)        printf '[ ]' ;;
    IN-PROGRESS) printf '[-]' ;;
    DONE|Done)   printf '[x]' ;;
    *)           printf '[?]' ;;
  esac
}

# Usage: _format__aligned_block [KEY VALUE]...
# Prints a '---'-delimited block of 'KEY: VALUE' lines for display, in argument
# order, with every value starting in the same column: one space past the
# longest 'KEY:'. Values are printed verbatim; callers omit the pairs they do
# not want shown.
_format__aligned_block() {
  local width=0 i
  local -a args=("$@")
  for (( i = 0; i < ${#args[@]}; i += 2 )); do
    (( ${#args[i]} + 1 > width )) && width=$(( ${#args[i]} + 1 ))
  done
  printf -- '---\n'
  for (( i = 0; i < ${#args[@]}; i += 2 )); do
    printf '%-*s %s\n' "$width" "${args[i]}:" "${args[i + 1]}"
  done
  printf -- '---\n'
}
