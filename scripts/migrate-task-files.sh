#!/usr/bin/env bash
# migrate-task-files.sh — Migrate .tt/task/*.md flat files to the directory format.
#
# Each flat file .tt/task/<slug>.md becomes:
#   .tt/task/<slug>/TASK.md        — task file with body (description from frontmatter)
#   .tt/task/<slug>/context/...md  — one context file per context chunk in the body
#
# Usage:
#   scripts/migrate-task-files.sh [--repo PATH] [<bookmark>]
#
# With no argument: migrates all bookmarks.
# With a bookmark name: migrates only that bookmark (useful for testing).
# With --repo PATH: use PATH as the jj repo root (default: parent of script dir).
#
# The script creates new commits on each bookmark (via `jj new <bookmark>` +
# `jj commit -m "Migrate task files to directory format"` + `jj bookmark set`).
# No history is rewritten; `jj undo` reverts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  printf '%s\n' "$*" >&2
}

# Generate 8-char random hex
generate_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4
  elif [[ -r /dev/urandom ]]; then
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n' | head -c 8
  else
    log "Error: Need openssl or /dev/urandom"
    exit 1
  fi
}

# ISO 8601 UTC timestamp
generate_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# title → lowercase-hyphenated slug
title_to_slug() {
  local t="$1"
  printf '%s' "$t" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | tr -s '-' | sed 's/^-//;s/-$//'
}

# Parse a YAML frontmatter field value (strips surrounding quotes)
parse_frontmatter_field() {
  local content="$1" field="$2"
  printf '%s' "$content" | awk -v field="$field" '
    /^---$/ { n++; next }
    n == 1 && $0 ~ ("^" field ":") {
      sub("^" field ":[[:space:]]*", "")
      gsub(/^"|"$/, "")
      print; exit
    }
  '
}

# Parse repeatable frontmatter field (outputs one value per line)
parse_frontmatter_field_all() {
  local content="$1" field="$2"
  printf '%s' "$content" | awk -v field="$field" '
    /^---$/ { n++; if (n == 2) exit; next }
    n == 1 && $0 ~ ("^" field ":") {
      sub("^" field ":[[:space:]]*", "")
      print
    }
  '
}

# JSON-string → raw text (uses jq if available, else minimal fallback)
json_decode() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$s" | jq -r '.' 2>/dev/null || printf '%s' "$s"
  else
    # Minimal fallback: strip surrounding quotes, unescape \" and \n
    local stripped="${s#\"}"
    stripped="${stripped%\"}"
    printf '%s' "$stripped" | sed 's/\\"/"/g; s/\\n/\n/g'
  fi
}

# ---------------------------------------------------------------------------
# Context chunk writing
#
# Splits a body on "---" separator lines, classifies each segment, writes
# context files directly to disk, and outputs one "context/<slug>-<hex>"
# ID per line to stdout (for the caller to collect as context refs).
#
# Segment classification:
#   - timestamp context:  starts with "## YYYY-MM-DD HH:MM"
#   - checkin context:    starts with "[task/...](...)" link
#   - description text:   everything else (printed to &3 for caller to capture)
#
# Usage:
#   context_refs="$(write_context_chunks "$body" "$ctx_dir" 3>"$desc_tmpfile")"
#   residual_desc="$(cat "$desc_tmpfile")"
#
# For simplicity we use a single invocation: the function writes context files
# and prints context IDs to stdout; residual description segments are appended
# to the file at path $RESIDUAL_DESC_FILE (a global set by the caller).
# ---------------------------------------------------------------------------
RESIDUAL_DESC_FILE=''

write_context_chunks() {
  local body="$1"
  local ctx_dir="$2"

  # Split body on lines that are exactly "---"
  local segment=''
  local -a segments=()

  while IFS= read -r line; do
    if [[ "$line" == '---' ]]; then
      segments+=("$segment")
      segment=''
    else
      if [[ -n "$segment" ]]; then
        segment="${segment}"$'\n'"${line}"
      else
        segment="$line"
      fi
    fi
  done <<< "$body"
  # Push last segment (no trailing ---)
  if [[ -n "$segment" ]]; then
    segments+=("$segment")
  fi

  for seg in "${segments[@]+"${segments[@]}"}"; do
    # Trim leading blank lines
    local trimmed
    trimmed="$(printf '%s' "$seg" | awk 'NF{found=1} found{print}')"
    [[ -z "$trimmed" ]] && continue

    local first_line
    first_line="$(printf '%s' "$trimmed" | head -1)"

    # Detect timestamp heading: ## YYYY-MM-DD HH:MM
    if [[ "$first_line" =~ ^##[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}) ]]; then
      local ts_str="${BASH_REMATCH[1]}"
      local ctx_title="Context from ${ts_str}"
      local ctx_body
      ctx_body="$(printf '%s' "$trimmed" | tail -n +2 | awk 'NF{found=1} found{print}')"
      _write_one_context_file "$ctx_dir" "$ctx_title" "$ctx_body"

    # Detect checkin context block: starts with [task/...](...) or [`task/`...](...) link
    elif [[ "$first_line" =~ ^\[.?task/[^]]+\]\( ]]; then
      local ctx_title
      ctx_title="$(printf '%s' "$first_line" | sed 's/^\[`\{0,1\}//; s/`\{0,1\}\].*//')"
      local ctx_body
      ctx_body="$(printf '%s' "$trimmed" | tail -n +2 | awk 'NF{found=1} found{print}')"
      _write_one_context_file "$ctx_dir" "$ctx_title" "$ctx_body"

    else
      # Residual description text — append to the caller's file
      if [[ -n "$RESIDUAL_DESC_FILE" ]]; then
        printf '%s\n' "$trimmed" >> "$RESIDUAL_DESC_FILE"
      fi
    fi
  done
}

# Write a single context file; prints the context ID to stdout.
_write_one_context_file() {
  local ctx_dir="$1"
  local ctx_title="$2"
  local ctx_body="$3"

  local ctx_slug
  ctx_slug="$(title_to_slug "$ctx_title")"
  [[ -z "$ctx_slug" ]] && ctx_slug="context"
  local ctx_hex
  ctx_hex="$(generate_hex)"
  local ctx_id="context/${ctx_slug}-${ctx_hex}"
  local ctx_ts
  ctx_ts="$(generate_timestamp)"

  mkdir -p "$ctx_dir"
  {
    printf -- '---\n'
    printf 'title: "%s"\n' "${ctx_title//\"/\\\"}"
    printf 'created: %s\n' "$ctx_ts"
    printf 'updated: %s\n' "$ctx_ts"
    printf -- '---\n'
    if [[ -n "$ctx_body" ]]; then
      printf '%s\n' "$ctx_body"
    fi
  } > "$ctx_dir/${ctx_slug}-${ctx_hex}.md"

  printf '%s\n' "$ctx_id"
}

# ---------------------------------------------------------------------------
# Migrate a single bookmark
# ---------------------------------------------------------------------------
migrate_bookmark() {
  local bookmark="$1"
  log "Migrating bookmark: $bookmark"

  # Create a new WC on top of the bookmark
  jj -R "$REPO_DIR" new "$bookmark"

  local changed=false

  # Find all flat task files: .tt/task/*.md (not inside subdirectories)
  local task_dir="$REPO_DIR/.tt/task"
  [[ ! -d "$task_dir" ]] && {
    log "  No .tt/task/ directory found; skipping."
    jj -R "$REPO_DIR" abandon
    return 0
  }

  local -a flat_files=()
  while IFS= read -r f; do
    flat_files+=("$f")
  done < <(find "$task_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null || true)

  if [[ ${#flat_files[@]} -eq 0 ]]; then
    log "  No flat task files to migrate."
    jj -R "$REPO_DIR" abandon
    return 0
  fi

  for flat_file in "${flat_files[@]}"; do
    local filename
    filename="$(basename "$flat_file" .md)"  # e.g. foo-abc12345
    local new_dir="$task_dir/$filename"
    local new_task_file="$new_dir/TASK.md"

    # Skip if already in directory format
    if [[ -d "$new_dir" ]]; then
      log "  Skipping already-migrated: $filename"
      continue
    fi

    log "  Migrating: $filename"

    # Read content
    local content
    content="$(cat "$flat_file")"

    # Parse frontmatter fields
    local title status created
    title="$(parse_frontmatter_field "$content" "title")"
    status="$(parse_frontmatter_field "$content" "status")"
    created="$(parse_frontmatter_field "$content" "created")"
    [[ -z "$status" ]] && status="TODO"
    [[ -z "$created" ]] && created="$(generate_timestamp)"
    local updated="$created"

    # Decode JSON-encoded description from frontmatter
    local description_raw description
    description_raw="$(printf '%s' "$content" | awk '
      /^---$/ { n++; next }
      n == 1 && /^description:/ {
        sub(/^description:[[:space:]]*/, "")
        print; exit
      }
    ')"
    if [[ -n "$description_raw" ]]; then
      description="$(json_decode "$description_raw")"
    else
      description=""
    fi

    # Parse labels and subtask entries (preserve as-is)
    local -a labels=()
    while IFS= read -r lbl; do
      [[ -n "$lbl" ]] && labels+=("$lbl")
    done < <(parse_frontmatter_field_all "$content" "label")

    local -a subtasks=()
    while IFS= read -r st; do
      [[ -n "$st" ]] && subtasks+=("$st")
    done < <(parse_frontmatter_field_all "$content" "subtask")

    # Extract body (everything after the second ---)
    local body
    body="$(printf '%s' "$content" | awk '/^---$/{n++; if(n==2){found=1; next}} found{print}')"

    # Pass 1: write context files directly to disk, collect context IDs and
    # any residual description text from the body.
    local ctx_dir="$new_dir/context"
    local -a context_refs=()
    local residual_desc=''

    if [[ -n "$body" ]]; then
      local residual_tmpfile
      residual_tmpfile="$(mktemp)"
      RESIDUAL_DESC_FILE="$residual_tmpfile"

      while IFS= read -r ctx_id; do
        [[ -n "$ctx_id" ]] && context_refs+=("$ctx_id")
      done < <(write_context_chunks "$body" "$ctx_dir")

      residual_desc="$(cat "$residual_tmpfile")"
      rm -f "$residual_tmpfile"
      RESIDUAL_DESC_FILE=''
    fi

    # Combine description: frontmatter description + residual body text
    local final_body="$description"
    if [[ -n "$residual_desc" ]]; then
      if [[ -n "$final_body" ]]; then
        final_body="${final_body}"$'\n\n'"$residual_desc"
      else
        final_body="$residual_desc"
      fi
    fi

    # Pass 2: write TASK.md with all context refs known
    mkdir -p "$new_dir"
    {
      printf -- '---\n'
      if [[ -n "$title" ]]; then
        printf 'title: "%s"\n' "${title//\"/\\\"}"
      fi
      printf 'status: %s\n' "$status"
      printf 'created: %s\n' "$created"
      printf 'updated: %s\n' "$updated"
      for lbl in "${labels[@]+"${labels[@]}"}"; do
        printf 'label: %s\n' "$lbl"
      done
      for st in "${subtasks[@]+"${subtasks[@]}"}"; do
        printf 'subtask: %s\n' "$st"
      done
      for ctx_ref in "${context_refs[@]+"${context_refs[@]}"}"; do
        printf 'context: %s\n' "$ctx_ref"
      done
      printf -- '---\n'
      if [[ -n "$final_body" ]]; then
        printf '%s\n' "$final_body"
      fi
    } > "$new_task_file"

    # Remove old flat file
    rm -f "$flat_file"

    # Update TASK.md symlink if it pointed to the old file
    local symlink_path="$REPO_DIR/TASK.md"
    if [[ -L "$symlink_path" ]]; then
      local current_target
      current_target="$(readlink "$symlink_path")"
      if [[ "$current_target" == ".tt/task/${filename}.md" ||
            "$current_target" == "$task_dir/${filename}.md" ]]; then
        ln -sf ".tt/task/${filename}/TASK.md" "$symlink_path"
        log "  Updated TASK.md symlink -> .tt/task/${filename}/TASK.md"
      fi
    fi

    changed=true
    log "  Migrated: $filename"
  done

  if [[ "$changed" == true ]]; then
    jj -R "$REPO_DIR" commit -m "Migrate task files to directory format"
    jj -R "$REPO_DIR" bookmark set "$bookmark" -r '@-'
    jj -R "$REPO_DIR" new '@'
    log "  Committed migration for: $bookmark"
  else
    jj -R "$REPO_DIR" abandon
    log "  No changes needed for: $bookmark"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local target_bookmark=''
  local workspace_dir=''
  local workspace_revision=''
  # Not local: _ws_cleanup trap needs access to this after main() returns
  _RETAIN_WORKSPACE=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -lt 2 ]] && { log "Error: --repo requires an argument"; exit 1; }
        REPO_DIR="$2"; shift 2 ;;
      --repo=*)
        REPO_DIR="${1#--repo=}"; shift ;;
      --workspace)
        [[ $# -lt 2 ]] && { log "Error: --workspace requires an argument"; exit 1; }
        workspace_dir="$2"; shift 2 ;;
      --workspace=*)
        workspace_dir="${1#--workspace=}"; shift ;;
      --revision)
        [[ $# -lt 2 ]] && { log "Error: --revision requires an argument"; exit 1; }
        workspace_revision="$2"; shift 2 ;;
      --revision=*)
        workspace_revision="${1#--revision=}"; shift ;;
      --retain-workspace)
        _RETAIN_WORKSPACE=true; shift ;;
      -*)
        log "Error: Unknown option: $1"; exit 1 ;;
      *)
        target_bookmark="$1"; shift ;;
    esac
  done

  # If --workspace is given, create an isolated jj workspace, run migration
  # inside it, then clean up (unless --retain-workspace).
  if [[ -n "$workspace_dir" ]]; then
    [[ -z "$target_bookmark" ]] && { log "Error: --workspace requires a bookmark argument"; exit 1; }

    # If --revision is given, verify it is an ancestor of the target bookmark.
    # This ensures the target bookmark already contains the correct version of
    # the migration script before we run it against its files.
    if [[ -n "$workspace_revision" ]]; then
      local ancestry_check
      ancestry_check="$(jj -R "$REPO_DIR" --ignore-working-copy \
        log -r "${workspace_revision}::${target_bookmark}" --no-graph \
        -T 'commit_id ++ "\n"' 2>/dev/null)" || true
      if [[ -z "$ancestry_check" ]]; then
        log "Error: '$workspace_revision' is not an ancestor of '$target_bookmark'."
        log "Rebase the test bookmark onto the feature branch first:"
        log "  jj rebase -b $target_bookmark -d $workspace_revision"
        exit 1
      fi
      log "Ancestry check passed: $workspace_revision is an ancestor of $target_bookmark"
    fi

    # These are globals (not local) so _ws_cleanup can reference them after
    # main() returns (bash trap functions don't inherit local scope).
    _WS_NAME="migrate-$$"
    _WS_ORIGINAL_REPO_DIR="$REPO_DIR"
    _WS_DIR="$workspace_dir"

    log "Creating workspace '$_WS_NAME' at $_WS_DIR"
    jj -R "$_WS_ORIGINAL_REPO_DIR" workspace add \
      --revision "$target_bookmark" \
      --name "$_WS_NAME" \
      "$_WS_DIR"

    # Print the workspace name to stdout (all other output goes to stderr via log())
    printf '%s\n' "$_WS_NAME"

    # Override REPO_DIR so all subsequent jj -R calls use the new workspace
    REPO_DIR="$_WS_DIR"

    _ws_cleanup() {
      if [[ "$_RETAIN_WORKSPACE" != true ]]; then
        jj -R "$_WS_ORIGINAL_REPO_DIR" workspace forget "$_WS_NAME" 2>/dev/null || true
        rm -rf "$_WS_DIR"
        log "Cleaned up workspace: $_WS_DIR"
      else
        log "Retaining workspace: $_WS_DIR (name: $_WS_NAME)"
        log "To clean up manually: jj -R \"$_WS_ORIGINAL_REPO_DIR\" workspace forget \"$_WS_NAME\" && rm -rf \"$_WS_DIR\""
      fi
    }
    trap '_ws_cleanup' EXIT
  fi

  cd "$REPO_DIR"

  if [[ -n "$target_bookmark" ]]; then
    migrate_bookmark "$target_bookmark"
  else
    # Migrate all task and project bookmarks
    local all_bookmarks
    all_bookmarks="$(jj -R "$REPO_DIR" --ignore-working-copy log -r 'bookmarks()' \
      -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' --no-graph 2>/dev/null)" || true

    local -a bookmarks_to_migrate=()
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      if [[ "$b" == task/* || "$b" == project/* ]]; then
        bookmarks_to_migrate+=("$b")
      fi
    done <<< "$all_bookmarks"

    if [[ ${#bookmarks_to_migrate[@]} -eq 0 ]]; then
      log "No task or project bookmarks found to migrate."
      exit 0
    fi

    for bm in "${bookmarks_to_migrate[@]}"; do
      migrate_bookmark "$bm"
    done

    log "Migration complete."
  fi
}

main "$@"
