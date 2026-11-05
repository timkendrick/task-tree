# Generic frontmatter parsing, formatting and in-place mutation helpers for tt
# bootstrap CLI scripts. Field names, field order and entry syntax belong to
# the callers (see lib/task.sh); this module knows only the delimited block of
# 'KEY: VALUE' lines and the body that follows it.
# Source this file; do not execute directly.
#
# Public surface:
#   _frontmatter__parse_body           — body after the closing frontmatter delimiter
#   _frontmatter__parse_fields         — extract requested fields in file order
#   _frontmatter__parse_field          — raw value of a single-valued field
#   _frontmatter__parse_quoted_field   — field value with matched quotes stripped
#   _frontmatter__parse_values         — values of several fields, lists count-prefixed
#   _frontmatter__decode               — the value a _frontmatter__parse_values line encodes
#   _frontmatter__parse_repeated_field — every value of a repeatable field
#   _frontmatter__quote                — encode a value as a quoted frontmatter string
#   _frontmatter__format_block         — delimited frontmatter block from key/value pairs
#   _frontmatter__set_field            — set a single-valued field
#   _frontmatter__set_entries          — replace every entry of a repeatable field
#   _frontmatter__add_entry            — add one entry of a repeatable field
#   _frontmatter__set_body             — replace the body after the frontmatter
#   _frontmatter__remove_entry         — remove every entry of a field with a given value
#   _frontmatter__replace_entry        — rewrite every entry of a field with a given value

# Usage: _frontmatter__parse_body CONTENT
# Outputs everything after the second "---" line (the frontmatter closing delimiter).
_frontmatter__parse_body() {
  local content="$1"
  local line sep=0 found=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$found" ]]; then
      printf '%s\n' "$line"
    elif [[ "$line" == '---' ]]; then
      sep=$(( sep + 1 ))
      [[ $sep -eq 2 ]] && found=1
    fi
  done <<< "$content"
}

# Usage: _frontmatter__parse_fields CONTENT FIELD...
# Extracts the requested frontmatter fields in a single pass, preserving file
# order. Emits one "FIELD:VALUE" line per matching frontmatter entry, with the
# key's leading whitespace stripped from VALUE but quotes preserved.
#
# The frontmatter block is strictly the leading delimited block: CONTENT must
# begin with a '---' line, and parsing stops at the closing '---'. Any '---'
# lines appearing later (e.g. inside a fenced code block in the body) are
# ignored, so body content can never be mistaken for frontmatter.
_frontmatter__parse_fields() {
  local content="$1"; shift
  local line sep=0 first=1 key val field
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$first" ]]; then
      first=''
      [[ "$line" == '---' ]] || return 0
    fi
    if [[ "$line" == '---' ]]; then
      sep=$(( sep + 1 ))
      [[ $sep -eq 2 ]] && return 0
      continue
    fi
    [[ $sep -eq 1 && "$line" == *:* ]] || continue
    key="${line%%:*}"
    for field in "$@"; do
      if [[ "$key" == "$field" ]]; then
        val="${line#"$key":}"
        val="${val#"${val%%[!$' \t']*}"}"
        printf '%s:%s\n' "$key" "$val"
        break
      fi
    done
  done <<< "$content"
}

# Usage: _frontmatter__parse_field CONTENT FIELD
# Extracts the raw value of a single-valued frontmatter field, preserving any
# quotes present in the original. If the field appears more than once, the
# first occurrence wins. Outputs nothing if the field is absent.
_frontmatter__parse_field() {
  local out first
  out="$(_frontmatter__parse_fields "$1" "$2")"
  [[ -z "$out" ]] && return 0
  first="${out%%$'\n'*}"
  printf '%s' "${first#"$2:"}"
}

# Usage: _frontmatter__parse_quoted_field CONTENT FIELD
# As _frontmatter__parse_field, but for a value written as a quoted string:
# strips a matched pair of surrounding double quotes and decodes the escapes
# _frontmatter__quote writes. A value without a matched pair is returned as
# it is.
_frontmatter__parse_quoted_field() {
  local value
  value="$(_frontmatter__parse_field "$1" "$2")"
  __frontmatter__unquote "$value"
}

# Usage: _frontmatter__parse_values CONTENT FIELD...
# Prints the requested frontmatter fields in a single pass, in argument order.
# Each FIELD is either a plain name or a name with a '[]' suffix:
#   NAME    one line: the first occurrence's value, decoded as
#           _frontmatter__parse_quoted_field does and then line-encoded (a
#           backslash as '\\', a newline as '\n'), or an empty line when the
#           field is absent. _frontmatter__decode recovers the value.
#   NAME[]  one line holding the number of occurrences N (0 when absent),
#           followed by N lines holding each raw value in file order. An
#           occurrence with an empty value gives an empty line.
#   ...     the body: everything after the closing delimiter, verbatim, as
#           _frontmatter__parse_body prints it. Allowed only as the last
#           request, so the body runs to the end of the output.
# A field requested more than once is printed once per request. Returns 1
# before printing anything when '...' is not the last request.
#
# No printed line holds a newline: the frontmatter format stores each raw
# value on one line, and a decoded NAME value is line-encoded. A caller reads
# exactly one line per NAME, then one count line and exactly that many entry
# lines per NAME[]. Command substitution strips trailing empty lines, so a
# read past the end of the captured output stands for an empty value:
#
#   { IFS= read -r title; IFS= read -r subtask_count
#     subtasks=()
#     for (( i = 0; i < subtask_count; i++ )); do
#       IFS= read -r subtask; subtasks+=("$subtask")
#     done
#   } <<< "$(_frontmatter__parse_values "$content" title 'subtask[]')" || true
#   title="$(_frontmatter__decode "$title")"
#
# The body follows the last field line; read it to the end of the input, and
# drop the newline the here-string appends:
#
#   { IFS= read -r title; IFS= read -r -d '' body; } \
#     <<< "$(_frontmatter__parse_values "$content" title '...')" || true
#   body="${body%$'\n'}"
_frontmatter__parse_values() {
  local content="$1"; shift
  local requests=("$@") names=() values=() found=() counts=() i
  local with_body=''
  for (( i = 0; i < ${#requests[@]}; i++ )); do
    [[ "${requests[i]}" == '...' ]] || continue
    if (( i != ${#requests[@]} - 1 )); then
      printf "Error: The body request '...' must be the last request.\n" >&2
      return 1
    fi
    with_body=1
    unset 'requests[i]'
  done
  for (( i = 0; i < ${#requests[@]}; i++ )); do
    names[i]="${requests[i]%\[\]}"
    values[i]=''
    found[i]=''
    counts[i]=0
  done

  local record key value
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    key="${record%%:*}"
    value="${record#"$key":}"
    for (( i = 0; i < ${#requests[@]}; i++ )); do
      [[ "${names[i]}" == "$key" ]] || continue
      if [[ "${requests[i]}" == *'[]' ]]; then
        values[i]+="$value"$'\n'
        counts[i]=$(( counts[i] + 1 ))
      elif [[ -z "${found[i]}" ]]; then
        value="$(__frontmatter__unquote "$value")"
        value="${value//\\/\\\\}"
        values[i]="${value//$'\n'/\\n}"
        found[i]=1
      fi
    done
  done < <(_frontmatter__parse_fields "$content" ${names[@]+"${names[@]}"})

  for (( i = 0; i < ${#requests[@]}; i++ )); do
    if [[ "${requests[i]}" == *'[]' ]]; then
      printf '%s\n%s' "${counts[i]}" "${values[i]}"
    else
      printf '%s\n' "${values[i]}"
    fi
  done
  if [[ -n "$with_body" ]]; then
    _frontmatter__parse_body "$content"
  fi
}

# Usage: _frontmatter__decode LINE
# Prints the value LINE encodes, LINE being a NAME line printed by
# _frontmatter__parse_values: '\\' becomes a backslash and '\n' a newline. A
# backslash before any other character, or at the end of LINE, is kept as
# written. A LINE with no backslash is printed unchanged.
_frontmatter__decode() {
  local line="$1"
  if [[ "$line" != *\\* ]]; then
    printf '%s' "$line"
    return 0
  fi
  local out='' rest="$line" next
  while [[ "$rest" == *\\* ]]; do
    out+="${rest%%\\*}"
    rest="${rest#*\\}"
    next="${rest:0:1}"
    case "$next" in
      '\') out+='\'; rest="${rest:1}" ;;
      n) out+=$'\n'; rest="${rest:1}" ;;
      *) out+='\' ;;
    esac
  done
  printf '%s' "$out$rest"
}

# Usage: _frontmatter__format_block [KEY VALUE]...
# Prints a '---'-delimited frontmatter block with one 'KEY: VALUE' line per
# pair, in argument order. A KEY given more than once gives one line per pair.
# Values are written raw; callers quote them with _frontmatter__quote.
_frontmatter__format_block() {
  printf -- '---\n'
  while [[ $# -ge 2 ]]; do
    printf '%s: %s\n' "$1" "$2"
    shift 2
  done
  printf -- '---\n'
}

# Usage: _frontmatter__quote VALUE
# Prints VALUE as a double-quoted string using JSON's basic escapes: a
# backslash and a double quote are backslash-escaped, and newline, carriage
# return, tab, backspace and form feed become \n, \r, \t, \b and \f, so the
# value fits on one frontmatter line and reads back unchanged.
_frontmatter__quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"
  printf '"%s"' "$value"
}

# Usage: __frontmatter__unquote TEXT
# The inverse of _frontmatter__quote for TEXT that is a matched pair of
# double quotes around a value: the quotes are removed and the escapes \" \\
# \/ \n \r \t \b \f are decoded. Any other escape — \uXXXX among them — is
# kept as written. A value with no backslash is returned as soon as the
# quotes are stripped; text without a matched pair is returned unchanged.
__frontmatter__unquote() {
  local text="$1"
  if [[ "$text" != \"*\" ]]; then
    printf '%s' "$text"
    return 0
  fi
  text="${text#\"}"
  text="${text%\"}"
  if [[ "$text" != *\\* ]]; then
    printf '%s' "$text"
    return 0
  fi
  local out='' i ch next
  for (( i = 0; i < ${#text}; i++ )); do
    ch="${text:$i:1}"
    if [[ "$ch" != '\' ]]; then
      out+="$ch"
      continue
    fi
    i=$(( i + 1 ))
    next="${text:$i:1}"
    case "$next" in
      '"') out+='"' ;;
      '\') out+='\' ;;
      '/') out+='/' ;;
      n) out+=$'\n' ;;
      r) out+=$'\r' ;;
      t) out+=$'\t' ;;
      b) out+=$'\b' ;;
      f) out+=$'\f' ;;
      *) out+="\\$next" ;;
    esac
  done
  printf '%s' "$out"
}

# Usage: _frontmatter__parse_repeated_field CONTENT FIELD
# Extracts every value of a repeatable frontmatter field, one per line, in
# file order. Outputs nothing if absent.
_frontmatter__parse_repeated_field() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line#"$2:"}"
  done < <(_frontmatter__parse_fields "$1" "$2")
}

# Usage: __frontmatter__rewrite FILE MODE KEY BEFORE [ARG...]
# Shared engine of the field mutators below. Rewrites FILE in place, in bash:
# the file is a staged copy nothing else reads. Only lines inside the leading
# frontmatter block are considered, and values are compared raw, with the
# leading whitespace after 'KEY:' stripped. A file that does not begin with a
# '---' line is left unchanged. BEFORE is a space-separated list of keys, used
# by set mode only. MODE is one of:
#   set VALUE...     the KEY lines are replaced by one 'KEY: VALUE' line per
#                    VALUE, placed at the first line whose key is KEY or one
#                    of BEFORE, or before the closing '---' when there is no
#                    such line. No VALUE removes every KEY line.
#   remove VALUE     every KEY line whose value is VALUE is dropped.
#   replace OLD NEW  every KEY line whose value is OLD becomes 'KEY: NEW'.
__frontmatter__rewrite() {
  local file="$1" mode="$2" key="$3" before=" $4 "
  shift 4
  local -a args=("$@")
  local line val sep=0 first=1 done_set='' out='' arg line_key
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$first" ]]; then
      first=''
      [[ "$line" == '---' ]] || return 0
    fi
    if [[ "$line" == '---' ]]; then
      sep=$(( sep + 1 ))
      if [[ $sep -eq 2 && "$mode" == set && -z "$done_set" ]]; then
        for arg in ${args[@]+"${args[@]}"}; do out+="$key: $arg"$'\n'; done
        done_set=1
      fi
    elif [[ $sep -eq 1 && "$mode" == set && -z "$done_set" && "$line" == *:* \
      && "${line%%:*}" != "$key" && "$before" == *" ${line%%:*} "* ]]; then
      for arg in ${args[@]+"${args[@]}"}; do out+="$key: $arg"$'\n'; done
      done_set=1
    elif [[ $sep -eq 1 && "$line" == *:* && "${line%%:*}" == "$key" ]]; then
      val="${line#"$key":}"
      val="${val#"${val%%[!$' \t']*}"}"
      case "$mode" in
        set)
          if [[ -z "$done_set" ]]; then
            for arg in ${args[@]+"${args[@]}"}; do out+="$key: $arg"$'\n'; done
            done_set=1
          fi
          continue ;;
        remove)
          [[ "$val" == "${args[0]}" ]] && continue ;;
        replace)
          [[ "$val" == "${args[0]}" ]] && line="$key: ${args[1]}" ;;
      esac
    fi
    out+="$line"$'\n'
  done < "$file"
  printf '%s' "$out" > "$file"
}

# Usage: _frontmatter__set_field [--before KEYS] FILE KEY VALUE
# Sets the single-valued field KEY to the raw VALUE in FILE's frontmatter, in
# place: the first KEY line is rewritten and any later KEY lines are dropped.
# When KEY is absent, 'KEY: VALUE' is inserted before the first line whose key
# is one of the space-separated KEYS, or before the closing '---'. A value
# written as a quoted string must be encoded by the caller (_frontmatter__quote).
_frontmatter__set_field() {
  local before=''
  if [[ "${1:-}" == --before ]]; then before="$2"; shift 2; fi
  __frontmatter__rewrite "$1" set "$2" "$before" "$3"
}

# Usage: _frontmatter__set_entries [--before KEYS] FILE KEY [VALUE...]
# Replaces every entry of the repeatable field KEY in FILE's frontmatter with
# one 'KEY: VALUE' line per raw VALUE, in argument order, in place. The new
# entries take the position of the first existing entry; when KEY is absent
# they are inserted before the first line whose key is one of the
# space-separated KEYS, or before the closing '---'. No VALUE removes every
# entry.
_frontmatter__set_entries() {
  local before=''
  if [[ "${1:-}" == --before ]]; then before="$2"; shift 2; fi
  local file="$1" key="$2"
  shift 2
  __frontmatter__rewrite "$file" set "$key" "$before" "$@"
}

# Usage: _frontmatter__add_entry [--before KEYS] FILE KEY VALUE
# Adds a 'KEY: VALUE' entry (VALUE raw) to FILE's frontmatter, in place: after
# the last existing KEY entry, or, when KEY is absent, before the first line
# whose key is one of the space-separated KEYS, or before the closing '---'.
# A file without a complete leading frontmatter block is left unchanged.
# Rewritten in bash: the file is a staged copy nothing else reads.
_frontmatter__add_entry() {
  local before=''
  if [[ "${1:-}" == --before ]]; then before=" $2 "; shift 2; fi
  local file="$1" key="$2" value="$3"
  local -a lines=()
  local line sep=0 first=1 n=0 last_key=-1 first_anchor=-1 closing=-1 line_key
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$first" ]]; then
      first=''
      [[ "$line" == '---' ]] || return 0
    fi
    lines[n]="$line"
    if [[ "$line" == '---' ]]; then
      sep=$(( sep + 1 ))
      [[ $sep -eq 2 && $closing -lt 0 ]] && closing=$n
    elif [[ $sep -eq 1 && "$line" == *:* ]]; then
      line_key="${line%%:*}"
      if [[ "$line_key" == "$key" ]]; then
        last_key=$n
      elif [[ $first_anchor -lt 0 && "$before" == *" $line_key "* ]]; then
        first_anchor=$n
      fi
    fi
    n=$(( n + 1 ))
  done < "$file"
  [[ $closing -ge 0 ]] || return 0

  local at
  if [[ $last_key -ge 0 ]]; then
    at=$(( last_key + 1 ))
  elif [[ $first_anchor -ge 0 ]]; then
    at=$first_anchor
  else
    at=$closing
  fi
  local out='' i
  for (( i = 0; i < n; i++ )); do
    [[ $i -eq $at ]] && out+="$key: $value"$'\n'
    out+="${lines[i]}"$'\n'
  done
  printf '%s' "$out" > "$file"
}

# Usage: _frontmatter__set_body FILE BODY
# Replaces everything after FILE's closing frontmatter delimiter with BODY
# followed by a newline, in place; an empty BODY leaves nothing after the
# delimiter. A file without a complete leading frontmatter block is left
# unchanged. Rewritten in bash: the file is a staged copy nothing else reads.
_frontmatter__set_body() {
  local file="$1" body="$2"
  local line sep=0 first=1 out=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$first" ]]; then
      first=''
      [[ "$line" == '---' ]] || return 0
    fi
    out+="$line"$'\n'
    if [[ "$line" == '---' ]]; then
      sep=$(( sep + 1 ))
      [[ $sep -eq 2 ]] && break
    fi
  done < "$file"
  [[ $sep -eq 2 ]] || return 0
  [[ -n "$body" ]] && out+="$body"$'\n'
  printf '%s' "$out" > "$file"
}

# Usage: _frontmatter__remove_entry FILE KEY VALUE
# Removes every KEY line whose raw value is VALUE from FILE's frontmatter, in
# place. Leaves the file unchanged and returns 0 when no entry matches.
_frontmatter__remove_entry() {
  __frontmatter__rewrite "$1" remove "$2" '' "$3"
}

# Usage: _frontmatter__replace_entry FILE KEY OLD NEW
# Rewrites every KEY line whose raw value is OLD to 'KEY: NEW' in FILE's
# frontmatter, in place, keeping its position. Leaves the file unchanged and
# returns 0 when no entry matches.
_frontmatter__replace_entry() {
  __frontmatter__rewrite "$1" replace "$2" '' "$3" "$4"
}
