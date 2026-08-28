# Task/context file frontmatter parsing and mutation helpers for tt bootstrap
# CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   _frontmatter__parse_body           — body after the closing frontmatter delimiter
#   _frontmatter__parse_fields         — extract requested fields in file order
#   _frontmatter__parse_field          — raw value of a single-valued field
#   _frontmatter__parse_quoted_field   — field value with matched quotes stripped
#   _frontmatter__parse_repeated_field — every value of a repeatable field
#   _frontmatter__parse_task           — parse task content into PARSED_* globals
#   _frontmatter__write_task_file      — write a canonical task file
#   _frontmatter__write_context_file   — write a canonical context file
#   _frontmatter__insert_line          — insert a line into a frontmatter block
#   _frontmatter__append_context       — append a 'context:' entry
#   _frontmatter__append_subtask       — append a 'subtask:' entry
#   _frontmatter__update_timestamp     — rewrite the 'updated:' field
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
  printf '%s' "$content" | awk '/^---$/{n++; if(n==2){found=1; next}} found{print}'
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
  printf '%s' "$content" | awk -v fields="$*" '
    BEGIN { n = split(fields, f, " "); for (i = 1; i <= n; i++) want[f[i]] = 1 }
    NR == 1 && $0 != "---" { exit }
    /^---$/ { sep++; if (sep == 2) exit; next }
    sep == 1 {
      key = $0
      if (sub(/:.*$/, "", key) == 0) next
      if (key in want) {
        val = $0
        sub("^" key ":[ \t]*", "", val)
        print key ":" val
      }
    }
  '
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
# As _frontmatter__parse_field, but strips a matched pair of surrounding
# double quotes from the value.
_frontmatter__parse_quoted_field() {
  local value
  value="$(_frontmatter__parse_field "$1" "$2")"
  if [[ "$value" == \"*\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  fi
  printf '%s' "$value"
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
  local unknown
  unknown="$(printf '%s' "$content" | awk '
    NR == 1 && $0 != "---" { exit }
    /^---$/ { n++; if (n==2) exit; next }
    n==1 && /^[a-zA-Z]/ {
      key=$0; sub(/:.*/, "", key)
      if (key != "title" && key != "status" && key != "created" && key != "updated" \
          && key != "label" && key != "context" && key != "subtask")
        print key
    }
  ')"
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
# Writes to a temp file and renames for atomicity.
_frontmatter__write_task_file() {
  local file="$1"
  local title="$2"
  local status="$3"
  local body="$4"
  local created="$5"
  local updated="$6"

  local tmpfile
  tmpfile="$(mktemp)"
  {
    echo '---'
    echo "title: \"${title//\"/\\\"}\""
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
  } > "$tmpfile"
  mv "$tmpfile" "$file"
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
# Uses temp file + mv for atomicity.
_frontmatter__insert_line() {
  local file="$1" line="$2" before="${3:-}"
  local tmpfile
  tmpfile="$(mktemp)"
  awk -v ins="$line" -v bef="$before" '
    BEGIN { sep=0; inserted=0 }
    /^---$/ {
      sep++
      if (sep == 2 && !inserted) { print ins; inserted=1 }
      print; next
    }
    sep == 1 && bef != "" && !inserted && $0 ~ bef {
      print ins; inserted=1
    }
    { print }
  ' "$file" > "$tmpfile"
  mv "$tmpfile" "$file"
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

# _frontmatter__update_timestamp FILE TIMESTAMP
#
# Updates the 'updated:' field in the frontmatter of FILE to TIMESTAMP.
# Uses temp file + mv for atomicity.
_frontmatter__update_timestamp() {
  local file="$1"
  local ts="$2"
  local tmpfile
  tmpfile="$(mktemp)"
  awk -v ts="$ts" '
    BEGIN { sep=0 }
    /^---$/ { sep++; print; next }
    sep == 1 && /^updated:/ { print "updated: " ts; next }
    { print }
  ' "$file" > "$tmpfile"
  mv "$tmpfile" "$file"
}
