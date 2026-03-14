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

# JSON-string → raw text (uses jq if available, else fallback)
json_decode() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$s" | jq -r '.' 2>/dev/null || printf '%s' "$s"
  else
    # Minimal fallback: strip surrounding quotes, unescape \" and \\n
    local stripped="${s#\"}"
    stripped="${stripped%\"}"
    printf '%s' "$stripped" | sed 's/\\"/"/g; s/\\n/\n/g'
  fi
}

# ---------------------------------------------------------------------------
# Context chunk parsing
#
# Splits the body on "---" separator lines and classifies each segment:
#   - timestamp context:   starts with "## YYYY-MM-DD HH:MM"
#   - checkin context:     starts with "[task/...](..." link
#   - description text:    everything else
#
# Outputs to stdout: one record per chunk, using NUL as a field separator:
#   CHUNK_TYPE \0 TITLE \0 BODY
#
# where CHUNK_TYPE is "context" or "desc".
# ---------------------------------------------------------------------------
parse_context_chunks() {
  local body="$1"

  # Split body on lines that are exactly "---"
  local IFS_SAVED="$IFS"
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

    # Detect timestamp heading: ## YYYY-MM-DD HH:MM
    local first_line
    first_line="$(printf '%s' "$trimmed" | head -1)"
    if [[ "$first_line" =~ ^##[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}) ]]; then
      local ts_str="${BASH_REMATCH[1]}"
      local ctx_title="Context from ${ts_str}"
      # Body is everything after the first line
      local ctx_body
      ctx_body="$(printf '%s' "$trimmed" | tail -n +2 | awk 'NF{found=1} found{print}')"
      printf '%s\x00%s\x00%s\n' "context" "$ctx_title" "$ctx_body"

    # Detect checkin context block: starts with [task/...](...) title
    elif [[ "$first_line" =~ ^\[task/[^]]+\]\( ]]; then
      # Title = the text of the link + the rest of the line (if any)
      local ctx_title
      ctx_title="$(printf '%s' "$first_line" | sed 's/^\[//; s/\].*//')"
      local ctx_body
      ctx_body="$(printf '%s' "$trimmed" | tail -n +2 | awk 'NF{found=1} found{print}')"
      printf '%s\x00%s\x00%s\n' "context" "$ctx_title" "$ctx_body"

    else
      # Description text
      printf '%s\x00%s\x00%s\n' "desc" "" "$trimmed"
    fi
  done
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

  # Find all flat task files: .tt/task/*.md (not directories, not TASK.md inside dirs)
  local task_dir="$REPO_DIR/.tt/task"
  [[ ! -d "$task_dir" ]] && {
    log "  No .tt/task/ directory found; skipping."
    jj -R "$REPO_DIR" abandon
    return 0
  }

  local flat_files=()
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

    # Skip if already in directory format (shouldn't happen but be safe)
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

    # If no created timestamp, use current time (migration approximation)
    if [[ -z "$created" ]]; then
      created="$(generate_timestamp)"
    fi
    local updated="$created"

    # Decode description from JSON-encoded frontmatter field
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

    # Parse labels (repeatable)
    local -a labels=()
    while IFS= read -r lbl; do
      [[ -n "$lbl" ]] && labels+=("$lbl")
    done < <(parse_frontmatter_field_all "$content" "label")

    # Parse subtask entries (preserve as-is, e.g. "[ ] task/foo-abc12345")
    local -a subtasks=()
    while IFS= read -r st; do
      [[ -n "$st" ]] && subtasks+=("$st")
    done < <(parse_frontmatter_field_all "$content" "subtask")

    # Extract body (everything after the second ---)
    local body
    body="$(printf '%s' "$content" | awk '/^---$/{n++; if(n==2){found=1; next}} found{print}')"

    # Parse context chunks from body
    local desc_parts=()
    local -a ctx_titles=()
    local -a ctx_bodies=()

    if [[ -n "$body" ]]; then
      while IFS=$'\n' read -r line; do
        [[ -z "$line" ]] && continue
        local chunk_type chunk_title chunk_body
        # Split on NUL fields
        chunk_type="$(printf '%s' "$line" | cut -d$'\x00' -f1)"
        chunk_title="$(printf '%s' "$line" | cut -d$'\x00' -f2)"
        chunk_body="$(printf '%s' "$line" | cut -d$'\x00' -f3-)"
        case "$chunk_type" in
          context)
            ctx_titles+=("$chunk_title")
            ctx_bodies+=("$chunk_body")
            ;;
          desc)
            desc_parts+=("$chunk_body")
            ;;
        esac
      done < <(parse_context_chunks "$body")
    fi

    # Combine description: frontmatter description + any residual body desc parts
    local final_body="$description"
    for dp in "${desc_parts[@]+"${desc_parts[@]}"}"; do
      if [[ -n "$final_body" ]]; then
        final_body="${final_body}"$'\n\n'"$dp"
      else
        final_body="$dp"
      fi
    done

    # Create new directory structure
    mkdir -p "$new_dir/context"

    # Generate context file entries for frontmatter
    local -a context_refs=()
    local n_ctx=${#ctx_titles[@]}
    for (( i=0; i<n_ctx; i++ )); do
      local ctx_title="${ctx_titles[$i]}"
      local ctx_body="${ctx_bodies[$i]}"
      local ctx_slug
      ctx_slug="$(title_to_slug "$ctx_title")"
      [[ -z "$ctx_slug" ]] && ctx_slug="context"
      local ctx_hex
      ctx_hex="$(generate_hex)"
      local ctx_id="context/${ctx_slug}-${ctx_hex}"
      context_refs+=("$ctx_id")

      # Write context file
      local ctx_ts
      ctx_ts="$(generate_timestamp)"
      {
        printf -- '---\n'
        printf 'title: "%s"\n' "${ctx_title//\"/\\\"}"
        printf 'created: %s\n' "$ctx_ts"
        printf 'updated: %s\n' "$ctx_ts"
        printf -- '---\n'
        if [[ -n "$ctx_body" ]]; then
          printf '%s\n' "$ctx_body"
        fi
      } > "$new_dir/${ctx_id}.md"
    done

    # Write new TASK.md
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

    # Update TASK.md symlink if it points to the old file
    local symlink_path="$REPO_DIR/TASK.md"
    if [[ -L "$symlink_path" ]]; then
      local current_target
      current_target="$(readlink "$symlink_path")"
      local expected_old_rel=".tt/task/${filename}.md"
      local expected_old_abs="$task_dir/${filename}.md"
      if [[ "$current_target" == "$expected_old_rel" || "$current_target" == "$expected_old_abs" ]]; then
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

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -lt 2 ]] && { log "Error: --repo requires an argument"; exit 1; }
        REPO_DIR="$2"; shift 2 ;;
      --repo=*)
        REPO_DIR="${1#--repo=}"; shift ;;
      -*)
        log "Error: Unknown option: $1"; exit 1 ;;
      *)
        target_bookmark="$1"; shift ;;
    esac
  done

  cd "$REPO_DIR"

  if [[ -n "$target_bookmark" ]]; then
    # Migrate a single bookmark
    migrate_bookmark "$target_bookmark"
  else
    # Migrate all task and project bookmarks
    local all_bookmarks
    all_bookmarks="$(jj -R "$REPO_DIR" --ignore-working-copy log -r 'bookmarks()' \
      -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' --no-graph 2>/dev/null)" || true

    local -a bookmarks_to_migrate=()
    while IFS= read -r b; do
      [[ -z "$b" ]] && continue
      # Only migrate task/ and project/ bookmarks
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
