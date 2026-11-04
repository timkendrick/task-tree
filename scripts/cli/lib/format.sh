# Display formatting helpers for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _format__status_checkbox — map a task status field to a GFM checkbox string
#   _format__aligned_block   — '---'-delimited block of aligned 'KEY: VALUE' lines
#   _format__table           — aligned table of tab-separated rows, with an optional marker column

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

# Usage: _format__table [--marker] < ROWS
# Prints tab-separated ROWS as an aligned table. The first row is the header.
# Each column is padded to its widest cell and columns are separated by two
# spaces. The last column is not padded, and a row whose last cell is empty
# has no trailing spaces.
#
# With --marker, the first field of each row is a marker flag and every line
# starts with a two-character marker slot. A row whose flag is '*' starts with
# '* ' and is printed in bold when _ui__check_color passes. Every other row,
# including the header, starts with two spaces.
_format__table() {
  local marker=0
  if [[ "${1:-}" == '--marker' ]]; then
    marker=1
  fi
  local bold='' reset=''
  if (( marker )) && _ui__check_color; then
    bold=$'\033[1m'
    reset=$'\033[0m'
  fi
  awk -v marker="$marker" -v bold="$bold" -v reset="$reset" '
    BEGIN { FS = "\t"; first = marker ? 2 : 1 }
    {
      rows = NR
      flag[NR] = marker ? $1 : ""
      count[NR] = NF
      for (i = first; i <= NF; i++) {
        cell[NR, i] = $i
        if (length($i) > width[i]) width[i] = length($i)
      }
    }
    END {
      for (r = 1; r <= rows; r++) {
        line = ""
        last = count[r]
        while (last > first && cell[r, last] == "") last--
        for (i = first; i <= last; i++) {
          if (i > first) line = line "  "
          if (i < last) line = line sprintf("%-" width[i] "s", cell[r, i])
          else line = line cell[r, i]
        }
        if (!marker) print line
        else if (r > 1 && flag[r] == "*") print bold "* " line reset
        else print "  " line
      }
    }
  '
}
