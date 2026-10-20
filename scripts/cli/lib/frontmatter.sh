# Task/context file frontmatter parsing and mutation helpers for tt bootstrap
# CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _frontmatter__parse_body           — body after the closing frontmatter delimiter
#   _frontmatter__parse_fields         — extract requested fields in file order
#   _frontmatter__parse_field          — raw value of a single-valued field
#   _frontmatter__parse_quoted_field   — field value with matched quotes stripped
#   _frontmatter__parse_values         — decoded values of several single-valued fields
#   _frontmatter__parse_repeated_field — every value of a repeatable field
#   _frontmatter__parse_task           — parse task content into PARSED_* globals
#   _frontmatter__write_task_file      — write a canonical task file
#   _frontmatter__write_context_file   — write a canonical context file
#   _frontmatter__insert_line          — insert a line into a frontmatter block
#   _frontmatter__append_context       — append a 'context:' entry
#   _frontmatter__append_subtask       — append a 'subtask:' entry
#   _frontmatter__remove_subtask       — remove a 'subtask:' entry by task ID
#   _frontmatter__rename_subtask       — repoint a 'subtask:' entry at a new task ID
#   _frontmatter__update_timestamp     — rewrite the 'updated:' field
#   _frontmatter__set_status           — rewrite the 'status:' field
#
# Global-variable conventions (bash 3.2 functions cannot return structured
# data, so these globals are part of the public surface):
#   _frontmatter__parse_task sets PARSED_TITLE, PARSED_STATUS, PARSED_CREATED,
#   PARSED_UPDATED, PARSED_BODY, and the arrays PARSED_LABELS, PARSED_CONTEXTS,
#   PARSED_SUBTASKS.
#   _frontmatter__write_task_file reads the arrays REWRITE_LABELS,
#   REWRITE_CONTEXTS, REWRITE_SUBTASKS, which callers must set beforehand.

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
# __frontmatter__quote writes. A value without a matched pair is returned as
# it is.
_frontmatter__parse_quoted_field() {
  local value
  value="$(_frontmatter__parse_field "$1" "$2")"
  __frontmatter__unquote "$value"
}

# Usage: _frontmatter__parse_values CONTENT FIELD...
# Prints one line per FIELD, in argument order: the field's value, decoded as
# _frontmatter__parse_quoted_field does, or an empty line when the field is
# absent, so each value keeps a fixed line position. The first occurrence of a
# field wins. A newline cannot occur inside a value, because the frontmatter
# format stores each value on one line and quoting escapes newlines.
# Rejects the repeatable fields label, context and subtask: logs an error and
# returns 1 before printing anything.
_frontmatter__parse_values() {
  local content="$1"; shift
  local field
  for field in "$@"; do
    case "$field" in
      label|context|subtask)
        printf "Error: Repeatable frontmatter field '%s' has no single value.\n" "$field" >&2
        return 1 ;;
    esac
  done

  local fields=("$@") values=() found=() i
  for (( i = 0; i < ${#fields[@]}; i++ )); do
    values[i]=''
    found[i]=''
  done

  local record key value
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    key="${record%%:*}"
    value="${record#"$key":}"
    for (( i = 0; i < ${#fields[@]}; i++ )); do
      if [[ "${fields[i]}" == "$key" && -z "${found[i]}" ]]; then
        values[i]="$(__frontmatter__unquote "$value")"
        found[i]=1
      fi
    done
  done < <(_frontmatter__parse_fields "$content" "$@")

  for (( i = 0; i < ${#fields[@]}; i++ )); do
    printf '%s\n' "${values[i]}"
  done
}

# Usage: __frontmatter__quote VALUE
# Prints VALUE as a double-quoted string using JSON's basic escapes: a
# backslash and a double quote are backslash-escaped, and newline, carriage
# return, tab, backspace and form feed become \n, \r, \t, \b and \f, so the
# value fits on one frontmatter line and reads back unchanged.
__frontmatter__quote() {
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
# The inverse of __frontmatter__quote for TEXT that is a matched pair of
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
# Extracts every value of a repeatable frontmatter field (label, context,
# subtask), one per line, in file order. Outputs nothing if absent.
_frontmatter__parse_repeated_field() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line#"$2:"}"
  done < <(_frontmatter__parse_fields "$1" "$2")
}

# _frontmatter__parse_task CONTENT
#
# Populates global variables from task frontmatter:
#   PARSED_TITLE, PARSED_STATUS, PARSED_CREATED, PARSED_UPDATED, PARSED_BODY
#   PARSED_LABELS (array), PARSED_CONTEXTS (array), PARSED_SUBTASKS (array)
#
# Exits 1 with an error message if any unrecognized frontmatter key is found.
# Known keys: title, status, created, updated, label, context, subtask
_frontmatter__parse_task() {
  local content="$1"

  PARSED_TITLE="$(_frontmatter__parse_quoted_field "$content" "title")"
  PARSED_STATUS="$(_frontmatter__parse_field "$content" "status")"
  PARSED_CREATED="$(_frontmatter__parse_field "$content" "created")"
  PARSED_UPDATED="$(_frontmatter__parse_field "$content" "updated")"
  PARSED_BODY="$(_frontmatter__parse_body "$content")"

  PARSED_LABELS=()
  while IFS= read -r lbl; do [[ -n "$lbl" ]] && PARSED_LABELS+=("$lbl"); done \
    < <(_frontmatter__parse_repeated_field "$content" "label")

  PARSED_CONTEXTS=()
  while IFS= read -r ctx; do [[ -n "$ctx" ]] && PARSED_CONTEXTS+=("$ctx"); done \
    < <(_frontmatter__parse_repeated_field "$content" "context")

  PARSED_SUBTASKS=()
  while IFS= read -r st; do [[ -n "$st" ]] && PARSED_SUBTASKS+=("$st"); done \
    < <(_frontmatter__parse_repeated_field "$content" "subtask")

  # Reject unrecognized frontmatter keys
  local unknown='' line sep=0 first=1 key
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$first" ]]; then
      first=''
      [[ "$line" == '---' ]] || break
    fi
    if [[ "$line" == '---' ]]; then
      sep=$(( sep + 1 ))
      [[ $sep -eq 2 ]] && break
      continue
    fi
    [[ $sep -eq 1 && "$line" == [a-zA-Z]* ]] || continue
    key="${line%%:*}"
    case "$key" in
      title|status|created|updated|label|context|subtask) ;;
      *) unknown+="$key"$'\n' ;;
    esac
  done <<< "$content"
  unknown="${unknown%$'\n'}"
  if [[ -n "$unknown" ]]; then
    printf 'Error: Unrecognized frontmatter field(s):\n%s\n' "$unknown" >&2
    return 1
  fi
}

# _frontmatter__write_task_file FILE TITLE STATUS BODY CREATED UPDATED
#
# Writes FILE with canonical frontmatter followed by BODY.
# Arrays REWRITE_LABELS, REWRITE_CONTEXTS, REWRITE_SUBTASKS must be set by
# the caller as environment variables before calling this function.
#
# Canonical field order: title, status, created, updated, label…, context…, subtask…
# STATUS is omitted when empty (used for context files which have no status field).
# Timestamps are caller-supplied; generate via _string__generate_timestamp at the call site.
# FILE is written directly: callers stage files for a commit rather than
# editing files anything else is reading.
_frontmatter__write_task_file() {
  local file="$1"
  local title="$2"
  local status="$3"
  local body="$4"
  local created="$5"
  local updated="$6"

  {
    echo '---'
    printf 'title: %s\n' "$(__frontmatter__quote "$title")"
    [[ -n "$status" ]] && echo "status: $status"
    echo "created: $created"
    echo "updated: $updated"
    for lbl in "${REWRITE_LABELS[@]+"${REWRITE_LABELS[@]}"}"; do
      echo "label: $lbl"
    done
    for ctx in "${REWRITE_CONTEXTS[@]+"${REWRITE_CONTEXTS[@]}"}"; do
      echo "context: $ctx"
    done
    for st in "${REWRITE_SUBTASKS[@]+"${REWRITE_SUBTASKS[@]}"}"; do
      echo "subtask: $st"
    done
    echo '---'
    if [[ -n "$body" ]]; then
      printf '%s\n' "$body"
    fi
  } > "$file"
}

# _frontmatter__write_context_file FILE TITLE BODY CREATED UPDATED
#
# Writes a context file with title, created, updated, and body.
# Context files have no status, label, context, or subtask fields.
# Delegates to _frontmatter__write_task_file with empty status and empty arrays.
_frontmatter__write_context_file() {
  local file="$1"
  local title="$2"
  local body="$3"
  local created="$4"
  local updated="$5"
  local REWRITE_LABELS=() REWRITE_CONTEXTS=() REWRITE_SUBTASKS=()
  _frontmatter__write_task_file "$file" "$title" "" "$body" "$created" "$updated"
}

# _frontmatter__insert_line FILE LINE_TO_INSERT [BEFORE_PATTERN]
#
# Shared implementation for inserting a line into YAML frontmatter.
# Inserts LINE_TO_INSERT at the correct position:
#   - If BEFORE_PATTERN is given: before the first line matching that pattern
#     within the frontmatter block.
#   - If omitted: before the closing --- separator.
# Rewritten in place, in bash: the file is a staged copy nothing else reads.
_frontmatter__insert_line() {
  local file="$1" line="$2" before="${3:-}"
  local current sep=0 inserted='' out=''
  while IFS= read -r current || [[ -n "$current" ]]; do
    if [[ "$current" == '---' ]]; then
      sep=$(( sep + 1 ))
      if [[ $sep -eq 2 && -z "$inserted" ]]; then
        out+="$line"$'\n'
        inserted=1
      fi
    elif [[ $sep -eq 1 && -n "$before" && -z "$inserted" && "$current" =~ $before ]]; then
      out+="$line"$'\n'
      inserted=1
    fi
    out+="$current"$'\n'
  done < "$file"
  printf '%s' "$out" > "$file"
}

# _frontmatter__append_context FILE CTX_ID
#
# Appends a 'context: CTX_ID' line before the first 'subtask:' line
# (or before the closing '---' if no subtask entries exist).
# Does not update the 'updated:' timestamp — call _frontmatter__update_timestamp
# separately if needed.
_frontmatter__append_context() {
  _frontmatter__insert_line "$1" "context: $2" "^subtask:"
}

# _frontmatter__append_subtask FILE TASK_ID
#
# Appends a 'subtask: [ ] TASK_ID' line before the closing '---' separator
# (after any existing context: or subtask: entries).
_frontmatter__append_subtask() {
  _frontmatter__insert_line "$1" "subtask: [ ] $2" ""
}

# _frontmatter__remove_subtask FILE TASK_ID
#
# Removes the 'subtask: [.] TASK_ID' line — any checkbox state (' ', 'x' or
# '-') — from FILE's frontmatter, in place. The entry is matched on the task
# ID alone, so a trailing title after the ID does not prevent removal. Only
# lines inside the frontmatter block are considered: a body line that looks
# like a subtask entry is left untouched. Removing an entry that does not
# exist leaves the file unchanged and returns 0.
# Rewritten in place, in bash: the file is a staged copy nothing else reads.
_frontmatter__remove_subtask() {
  local file="$1" task_id="$2"
  local current sep=0 rest out=''
  while IFS= read -r current || [[ -n "$current" ]]; do
    if [[ "$current" == '---' ]]; then
      sep=$(( sep + 1 ))
    elif [[ $sep -eq 1 && "$current" == subtask:* ]]; then
      rest="$(__frontmatter__subtask_rest "$current")"
      [[ "${rest%%[[:space:]]*}" == "$task_id" ]] && continue
    fi
    out+="$current"$'\n'
  done < "$file"
  printf '%s' "$out" > "$file"
}

# Usage: __frontmatter__subtask_rest LINE
# Prints a `subtask:` line with its key and checkbox prefix removed — the
# task ID and whatever follows it. A line without a well-formed checkbox is
# printed unchanged.
__frontmatter__subtask_rest() {
  local line="$1"
  local checkbox='^subtask:[[:space:]]*\[[[:space:]x-]\][[:space:]]*'
  if [[ "$line" =~ $checkbox ]]; then
    line="${line#"${BASH_REMATCH[0]}"}"
  fi
  printf '%s' "$line"
}

# _frontmatter__rename_subtask FILE OLD_ID NEW_ID
#
# Rewrites the 'subtask: [.] OLD_ID' entry in FILE's frontmatter to name
# NEW_ID instead, in place. The checkbox state and anything following the ID
# on the line (e.g. a trailing title) are preserved, and the entry keeps its
# position in the list. The entry is matched on the task ID alone, and only
# lines inside the frontmatter block are considered: a body line that looks
# like a subtask entry is left untouched. Renaming an entry that does not
# exist leaves the file unchanged and returns 0.
# Rewritten in place, in bash: the file is a staged copy nothing else reads.
_frontmatter__rename_subtask() {
  local file="$1" old_id="$2" new_id="$3"
  local current sep=0 rest prefix out=''
  while IFS= read -r current || [[ -n "$current" ]]; do
    if [[ "$current" == '---' ]]; then
      sep=$(( sep + 1 ))
    elif [[ $sep -eq 1 && "$current" == subtask:* ]]; then
      rest="$(__frontmatter__subtask_rest "$current")"
      if [[ "${rest%%[[:space:]]*}" == "$old_id" ]]; then
        # The checkbox prefix is whatever precedes the remainder.
        prefix="${current:0:$(( ${#current} - ${#rest} ))}"
        current="${prefix}${new_id}${rest:${#old_id}}"
      fi
    fi
    out+="$current"$'\n'
  done < "$file"
  printf '%s' "$out" > "$file"
}

# _frontmatter__update_timestamp FILE TIMESTAMP
#
# Updates the 'updated:' field in the frontmatter of FILE to TIMESTAMP.
# Rewritten in place, in bash: the file is a staged copy nothing else reads.
_frontmatter__update_timestamp() {
  local file="$1"
  local ts="$2"
  local current sep=0 out=''
  while IFS= read -r current || [[ -n "$current" ]]; do
    if [[ "$current" == '---' ]]; then
      sep=$(( sep + 1 ))
    elif [[ $sep -eq 1 && "$current" == updated:* ]]; then
      current="updated: $ts"
    fi
    out+="$current"$'\n'
  done < "$file"
  printf '%s' "$out" > "$file"
}

# _frontmatter__set_status FILE STATUS
#
# Updates the 'status:' field in the frontmatter of FILE to STATUS. Only lines
# inside the frontmatter block are considered: a body line starting with
# 'status:' is left untouched. Does not update the 'updated:' timestamp.
# Rewritten in place, in bash: the file is a staged copy nothing else reads.
_frontmatter__set_status() {
  local file="$1"
  local status="$2"
  local current sep=0 out=''
  while IFS= read -r current || [[ -n "$current" ]]; do
    if [[ "$current" == '---' ]]; then
      sep=$(( sep + 1 ))
    elif [[ $sep -eq 1 && "$current" == status:* ]]; then
      current="status: $status"
    fi
    out+="$current"$'\n'
  done < "$file"
  printf '%s' "$out" > "$file"
}
