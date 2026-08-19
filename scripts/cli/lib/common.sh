# Common functions for tt bootstrap CLI scripts.
# Source this file; do not execute directly.

# ---------------------------------------------------------------------------
# VCS file-read helpers
# ---------------------------------------------------------------------------

# Usage: jj_show_at_revision REPO REV PATH
# Reads a file at a named revision from a jj repo using a root:-relative path.
# Always passes --ignore-working-copy since these calls never read from @.
# Outputs file content to stdout. Returns jj's exit code (non-zero = file absent).
jj_show_at_revision() {
  local repo="$1" rev="$2" path="$3"
  jj -R "$repo" --ignore-working-copy file show -r "$rev" -- "root:$path" 2>/dev/null
}

# Usage: get_jj_op_id REPO
# Prints the current jj operation ID to stdout.
# Returns 1 if the operation ID cannot be read.
#
# Runs jj in a subshell that cds into REPO first. This ensures jj can resolve
# its CWD even when the caller's working directory has been deleted (e.g. after
# a worktree is removed by `worktree delete`). The -R flag tells jj which repo
# to operate on, so the cd only affects CWD resolution, not the target repo.
get_jj_op_id() {
  local repo="$1"
  (cd "$repo" && jj -R "$repo" op log --no-graph -T id -n 1 2>/dev/null)
}

# Usage: jj_show_at_op REPO OP REV PATH
# Reads a file at a specific jj operation ID and revision, using a root:-relative path.
# Used for historical rescue (e.g. recovering pre-rename file content).
# Outputs file content to stdout. Returns jj's exit code (non-zero = file absent).
jj_show_at_op() {
  local repo="$1" op="$2" rev="$3" path="$4"
  jj -R "$repo" --at-operation "$op" file show -r "$rev" -- "root:$path" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Commit message formatting
# ---------------------------------------------------------------------------

# Usage: format_commit_message NAMESPACE OPERATION ENTITY_ID DESCRIPTION
#
# Constructs a standardized tt commit message:
#   [tt:<namespace>:<entity-id>:<operation>] <description>
#
# When ENTITY_ID is empty (e.g. workspace operations), uses:
#   [tt:<namespace>:<operation>] <description>
#
# DESCRIPTION may be multi-line for checkpoint commits.
#
# Arguments:
#   NAMESPACE   — the command namespace, e.g. "workspace", "task"
#   OPERATION   — the operation name, e.g. "create", "edit", "checkpoint", etc.
#   ENTITY_ID   — the full task ID, e.g. "task/foo-ab123456" or "project/my-ab123456"
#                 (empty string for workspace-level operations)
#   DESCRIPTION — human-readable description (title, user message, etc.)
#
# Outputs the formatted commit message to stdout.
format_commit_message() {
  local namespace="$1"
  local operation="$2"
  local entity_id="$3"
  local description="$4"

  if [[ -z "$entity_id" ]]; then
    printf '[tt:%s:%s] %s' "$namespace" "$operation" "$description"
  else
    printf '[tt:%s:%s:%s] %s' "$namespace" "$entity_id" "$operation" "$description"
  fi
}

# ---------------------------------------------------------------------------
# Shared slug / ID / timestamp helpers (used by create, edit, add-context)
# ---------------------------------------------------------------------------

# Generate slug from title: replace non-alphanumeric with -, collapse consecutive, lowercase, trim.
title_to_slug() {
  local t="$1"
  printf '%s' "$t" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | tr -s '-' | sed 's/^-//;s/-$//'
}

# Validate slug: only lowercase alphanumeric and single hyphens; no leading/trailing hyphens.
# Returns 0 if valid, 1 and logs error if invalid.
validate_slug() {
  local s="$1"
  if [[ -z "$s" ]]; then
    log "Error: Slug cannot be empty"
    return 1
  fi
  if [[ "$s" =~ [A-Z] ]]; then
    log "Error: Slug must be lowercase: $s"
    return 1
  fi
  if [[ "$s" =~ ^- ]]; then
    log "Error: Slug cannot start with hyphen: $s"
    return 1
  fi
  if [[ "$s" =~ -$ ]]; then
    log "Error: Slug cannot end with hyphen: $s"
    return 1
  fi
  if [[ "$s" =~ -- ]]; then
    log "Error: Slug cannot contain consecutive hyphens: $s"
    return 1
  fi
  if [[ "$s" =~ [^a-z0-9-] ]]; then
    log "Error: Slug must contain only lowercase letters, digits, and hyphens: $s"
    return 1
  fi
  return 0
}

# Generate an 8-character random hex string for task/context IDs.
generate_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4
  elif [[ -r /dev/urandom ]]; then
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n' | head -c 8
  else
    log "Error: Need openssl or /dev/urandom to generate ID"
    exit 1
  fi
}

# Generate an ISO 8601 UTC timestamp (e.g. 2026-03-12T23:04:57Z).
generate_timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ---------------------------------------------------------------------------
# Task/context file path helpers
# ---------------------------------------------------------------------------

# The tt metadata directory, relative to the repository root. All task files,
# context files, configuration, hooks and history live beneath this directory.
# Use this instead of hardcoding '.tt' so the location is defined in one place.
TT_METADATA_DIR='.tt'

# The repo-root symlink pointing at the current task's TASK.md. Although it
# lives outside TT_METADATA_DIR it is tt metadata, not project content.
TT_TASK_SYMLINK_FILENAME='TASK.md'

# Usage: tt_metadata_path [SUBPATH]
# Returns the repo-relative path to the tt metadata directory, optionally with
# SUBPATH appended (e.g. tt_metadata_path "config.toml" -> ".tt/config.toml").
tt_metadata_path() {
  local subpath="${1:-}"
  if [[ -z "$subpath" ]]; then
    printf '%s' "$TT_METADATA_DIR"
  else
    printf '%s/%s' "$TT_METADATA_DIR" "$subpath"
  fi
}

# Usage: task_root_path
# Returns the canonical directory path containing all task directories.
task_root_path() {
  tt_metadata_path 'task'
}

# Usage: metadata_exclusion_fileset
# Returns a jj fileset expression matching everything except tt metadata: the
# metadata directory and the repo-root TASK.md symlink. 'root:' patterns are
# workspace-relative, so the expression is independent of the current directory.
metadata_exclusion_fileset() {
  printf '~(root:"%s" | root-file:"%s")' "$TT_METADATA_DIR" "$TT_TASK_SYMLINK_FILENAME"
}

# Usage: task_file_path SUFFIX
# Returns the canonical path to a task's TASK.md file.
# SUFFIX is the slug-hex part (e.g. "my-task-abc12345").
task_file_path() {
  local suffix="$1"
  printf '%s/%s/%s' "$(task_root_path)" "$suffix" "$TT_TASK_SYMLINK_FILENAME"
}

# Usage: task_dir_path SUFFIX
# Returns the canonical directory path for a task.
task_dir_path() {
  local suffix="$1"
  printf '%s/%s' "$(task_root_path)" "$suffix"
}

# Usage: task_context_path SUFFIX CTX_ID
# Returns the canonical path to a context file.
# CTX_ID is "context/<ctx-slug>-<ctx-hex>" (without .md).
task_context_path() {
  local suffix="$1"
  local ctx_id="$2"
  printf '%s/%s/%s.md' "$(task_root_path)" "$suffix" "$ctx_id"
}

# ---------------------------------------------------------------------------
# Body parsing helper
# ---------------------------------------------------------------------------

# Usage: parse_body CONTENT
# Outputs everything after the second "---" line (the frontmatter closing delimiter).
parse_body() {
  local content="$1"
  printf '%s' "$content" | awk '/^---$/{n++; if(n==2){found=1; next}} found{print}'
}

log() {
  printf '%s\n' "$*" >&2
}

# Resolve DIR to a canonical absolute path, following OS-level symlinks (pwd -P).
# Exits 1 if the directory does not exist or cannot be entered.
# Usage: resolve_path_symlinks DIR
resolve_path_symlinks() {
  (cd "$1" && pwd -P)
}

# Find repo root by walking up from current directory to find .jj; return 1 if not found.
# Uses pwd -P to resolve symlinks so that working from inside a symlinked directory
# (e.g. /virtual/HEAD) does not produce a symlink path as the repo root.
find_repo_root() {
  local dir
  dir="$(pwd -P)"
  while [[ -n "$dir" ]]; do
    if [[ -d "$dir/.jj" ]]; then
      printf '%s' "$dir"
      return 0
    fi
    [[ "$dir" == '/' ]] && break
    dir="$(dirname "$dir")"
  done
  return 1
}

# Usage: repo=$(resolve_repo "$repo_flag_value")
#
# Resolves the repository root using the following priority order:
#   1. $repo_flag_value — the value passed to --repo (if non-empty)
#   2. $TT_REPO        — the TT_REPO environment variable (if set and non-empty)
#   3. find_repo_root  — walk up from CWD to find a .jj directory
#
# Prints the resolved repo path to stdout.
# Exits 1 with an error message if the path cannot be resolved or is not a jj repo.
resolve_repo() {
  local repo="${1:-}"

  # Priority 1: explicit --repo flag (already in $repo if set)
  if [[ -z "$repo" ]]; then
    # Priority 2: TT_REPO environment variable
    if [[ -n "${TT_REPO:-}" ]]; then
      repo="$TT_REPO"
    else
      # Priority 3: walk up from CWD
      if ! repo="$(find_repo_root)"; then
        log "Error: No enclosing jj repository. Use --repo or set TT_REPO."
        exit 1
      fi
    fi
  fi

  if [[ ! -d "$repo/.jj" ]]; then
    log "Error: Not a jj repository: $repo"
    exit 1
  fi

  # Canonicalize to match jj's own path representation (e.g. /var → /private/var on macOS)
  repo="$(resolve_path_symlinks "$repo")"
  printf '%s' "$repo"
}

# Read task_prefix from .tt/config.toml; default "task/" if missing or unreadable.
get_task_prefix() {
  local repo="$1"
  local config="$repo/$(tt_metadata_path 'config.toml')"
  local default_prefix='task/'
  if [[ -r "$config" ]]; then
    convfmt --from toml --to json < "$config" | jq -r '.task_prefix // "'"$default_prefix"'"'
  else
    printf '%s' "$default_prefix"
  fi
}

# Read project_prefix from .tt/config.toml; default "project/" if missing or unreadable.
get_project_prefix() {
  local repo="$1"
  local config="$repo/$(tt_metadata_path 'config.toml')"
  local default_prefix='project/'
  if [[ -r "$config" ]]; then
    convfmt --from toml --to json < "$config" | jq -r '.project_prefix // "'"$default_prefix"'"'
  else
    printf '%s' "$default_prefix"
  fi
}

# Return true if bookmark name matches task ID pattern (<prefix><slug>-<hex>).
is_task_branch() {
  local bookmark="$1"
  local prefix="$2"
  [[ "$bookmark" == "$prefix"* ]] && [[ "$bookmark" =~ -[0-9a-fA-F]{8}$ ]]
}

# Usage: set_workspace_dir REPO VIRTUAL_DIR
# Creates or replaces the <repo>/.tt/workspace symlink pointing at VIRTUAL_DIR.
# Always uses an absolute target path; the absolute-path guarantee is an
# implementation detail enforced here so callers never need to think about it.
set_workspace_dir() {
  local repo="$1" virtual_dir="$2"
  make_absolute_symlink "$virtual_dir" "$repo/$(tt_metadata_path 'workspace')"
}

# Usage: init_tt_history REPO
# Creates an empty .tt/history file in REPO if it does not already exist.
# The history file is gitignored (via .tt/.gitignore) and used by the
# transaction system to record before/after jj operation IDs for `tt history undo`.
init_tt_history() {
  local repo="$1"
  local history_file="$repo/$(tt_metadata_path 'history')"
  if [[ ! -f "$history_file" ]]; then
    touch "$history_file"
  fi
}

# Read workspace dir from .tt/workspace symlink; returns 1 if not configured.
# Always resolves to an absolute path to prevent symlink loops.
get_workspace_dir() {
  local repo="$1"
  local symlink="$repo/$(tt_metadata_path 'workspace')"
  if [[ -L "$symlink" ]]; then
    local ws_dir
    ws_dir="$(readlink "$symlink")"
    if [[ -n "$ws_dir" ]]; then
      # Resolve relative targets against the symlink's parent directory,
      # then canonicalise to strip OS-level symlinks (e.g. /var -> /private/var).
      if [[ "$ws_dir" != /* ]]; then
        ws_dir="$(resolve_path_symlinks "$(cd "$(dirname "$symlink")" && cd "$ws_dir" && pwd)")"
      else
        ws_dir="$(resolve_path_symlinks "$ws_dir")"
      fi
      printf '%s' "$ws_dir"
      return 0
    fi
  fi
  return 1
}

# Return true if bookmark name matches project ID pattern (<prefix><slug>-<hex>).
is_project_branch() {
  local bookmark="$1"
  local prefix="$2"
  [[ "$bookmark" == "$prefix"* ]] && [[ "$bookmark" =~ -[0-9a-fA-F]{8}$ ]]
}

# Usage: count_revs_in_revset REPO REVSET
# Prints the number of commits matching REVSET (0 if REVSET fails to resolve).
count_revs_in_revset() {
  local repo="$1" revset="$2"
  jj -R "$repo" log -r "$revset" --no-graph -T 'commit_id ++ "\n"' 2>/dev/null | grep -c . || true
}

# Usage: get_commit_description REPO REV
# Prints the full description of REV (empty if it has none).
get_commit_description() {
  local repo="$1" rev="$2"
  jj -R "$repo" log -r "$rev" --no-graph -T 'description'
}

# Usage: is_wc_clean REPO_OR_WORKTREE
# Returns 0 if the working copy at REPO_OR_WORKTREE has no pending changes.
is_wc_clean() {
  local r="$1"
  local result
  result="$(jj -R "$r" log -r '@' --no-graph -T 'empty' 2>/dev/null)" || return 1
  [[ "$result" == "true" ]]
}

# Usage: assert_bookmark_up_to_date REPO BOOKMARK
# Exits 1 if there are any commits between BOOKMARK and the working-copy parent
# (@-) that are not tracked by the bookmark. Used by commands that operate on
# the implicit current branch to ensure all work has been checkpointed.
#
# Skip this check when the user passes an explicit task-id, as that constitutes
# an intentional acknowledgement that the bookmark may be behind.
assert_bookmark_up_to_date() {
  local repo="$1" bookmark="$2"
  if ! check_bookmark_up_to_date "$repo" "$bookmark"; then
    log "Error: There are commits since the last checkpoint that are not tracked by the task bookmark."
    log "  Run 'tt task checkpoint' to record them before checking in."
    log "  Alternatively, pass the task ID explicitly to skip this check:"
    log "    tt task checkin ${bookmark}"
    exit 1
  fi
}

# Usage: run_hook REPO HOOK_NAME BLOCKING WORKTREE_DIR WORKSPACE_DIR [VAR=val ...]
# Runs .tt/hooks/<hook-name> with TT_WORKSPACE_DIR and TT_WORKTREE_DIR set,
# plus any additional VAR=val pairs. Blocking hooks abort on non-zero exit.
run_hook() {
  local repo="$1" hook_name="$2" blocking="$3" worktree_dir="$4" workspace_dir="$5"
  shift 5
  local hook_path="$repo/$(tt_metadata_path "hooks/$hook_name")"
  [[ ! -x "$hook_path" ]] && return 0
  local exit_code=0
  env TT_WORKSPACE_DIR="${workspace_dir:-}" TT_WORKTREE_DIR="$worktree_dir" "$@" "$hook_path" \
    || exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    if [[ "$blocking" == true ]]; then
      log "Error: Hook '$hook_name' failed (exit $exit_code); aborting."
      exit 1
    else
      log "Warning: Hook '$hook_name' failed (exit $exit_code; non-blocking)."
    fi
  fi
}

# Usage: make_absolute_symlink TARGET_PATH SYMLINK_PATH
# Creates or replaces SYMLINK_PATH pointing at TARGET_PATH, always using an
# absolute path for the target to prevent symlink loops (e.g. HEAD -> ./HEAD).
# TARGET_PATH must be an existing directory or file; exits 1 otherwise.
make_absolute_symlink() {
  local target_path="$1" symlink_path="$2"
  if [[ ! -e "$target_path" ]]; then
    log "Error: Symlink target does not exist: $target_path"
    return 1
  fi
  if [[ "$target_path" != /* ]]; then
    target_path="$(resolve_path_symlinks "$target_path")"
  fi
  ln -snf "$target_path" "$symlink_path"
}

# Usage: update_head_symlink WORKSPACE_DIR TARGET_PATH
# Updates <workspace-dir>/HEAD to point at TARGET_PATH using an absolute path
# to prevent symlink loops.
update_head_symlink() {
  local workspace_dir="$1" target_path="$2"
  [[ -z "$workspace_dir" ]] && return 0
  [[ ! -d "$workspace_dir" ]] && return 0
  local head_path="$workspace_dir/HEAD"
  make_absolute_symlink "$target_path" "$head_path"
  log "Updated HEAD -> $target_path"
}

# Usage: perform_workspace_switch REPO WORKSPACE_DIR TASK_ID TARGET_WORKTREE OUTGOING_WORKTREE PREVIOUS_TASK_ID
# Fires pre-checkout hook, updates HEAD symlink, fires post-checkout hook.
perform_workspace_switch() {
  local repo="$1" workspace_dir="$2" task_id="$3"
  local target_worktree="$4" outgoing_worktree="$5" previous_task_id="$6"

  log "Switching to $task_id"

  run_hook "$repo" "pre-checkout" true "$outgoing_worktree" "${workspace_dir:-}" \
    "TT_TASK_ID=$task_id" \
    "TT_TASK_BRANCH=$task_id" \
    "TT_PREVIOUS_TASK_ID=${previous_task_id}" \
    "TT_PREVIOUS_TASK_BRANCH=${previous_task_id}"

  update_head_symlink "$workspace_dir" "$target_worktree"

  run_hook "$repo" "post-checkout" false "$target_worktree" "${workspace_dir:-}" \
    "TT_TASK_ID=$task_id" \
    "TT_TASK_BRANCH=$task_id" \
    "TT_PREVIOUS_TASK_ID=${previous_task_id}" \
    "TT_PREVIOUS_TASK_BRANCH=${previous_task_id}"
}

# Usage: parse_frontmatter_fields CONTENT FIELD...
# Extracts the requested frontmatter fields in a single pass, preserving file
# order. Emits one "FIELD:VALUE" line per matching frontmatter entry, with the
# key's leading whitespace stripped from VALUE but quotes preserved.
#
# The frontmatter block is strictly the leading delimited block: CONTENT must
# begin with a '---' line, and parsing stops at the closing '---'. Any '---'
# lines appearing later (e.g. inside a fenced code block in the body) are
# ignored, so body content can never be mistaken for frontmatter.
parse_frontmatter_fields() {
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

# Usage: parse_frontmatter_field CONTENT FIELD
# Extracts the raw value of a single-valued frontmatter field, preserving any
# quotes present in the original. If the field appears more than once, the
# first occurrence wins. Outputs nothing if the field is absent.
parse_frontmatter_field() {
  local out first
  out="$(parse_frontmatter_fields "$1" "$2")"
  [[ -z "$out" ]] && return 0
  first="${out%%$'\n'*}"
  printf '%s' "${first#"$2:"}"
}

# Usage: parse_quoted_frontmatter_field CONTENT FIELD
# As parse_frontmatter_field, but strips a matched pair of surrounding
# double quotes from the value.
parse_quoted_frontmatter_field() {
  local value
  value="$(parse_frontmatter_field "$1" "$2")"
  if [[ "$value" == \"*\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  fi
  printf '%s' "$value"
}

# Usage: parse_repeated_frontmatter_field CONTENT FIELD
# Extracts every value of a repeatable frontmatter field (label, context,
# subtask), one per line, in file order. Outputs nothing if absent.
parse_repeated_frontmatter_field() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line#"$2:"}"
  done < <(parse_frontmatter_fields "$1" "$2")
}

# Usage: raw=$(prompt_raw <<< "$template")
# Reads template from stdin, opens editor, returns raw file content (no stripping).
# Exits non-zero if editor exits non-zero.
# On editor failure, the temporary file is retained on disk and its path is
# printed to stderr so the user can recover any unsaved edits.
prompt_raw() {
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
    log "Error: Editor exited with non-zero status."
    log "  Editor contents: $tmpfile"
    return 1;
  }
  cat "$tmpfile"
}

# Usage: message=$(prompt <<< "$template")
# Reads template from stdin, opens editor, strips #-comment lines and trims whitespace,
# prints cleaned text to stdout (empty string if blank after stripping).
# Exits non-zero if editor exits non-zero.
prompt() {
  local raw
  raw="$(prompt_raw)" || return 1
  local msg
  msg="$(printf '%s' "$raw" | sed '/^#/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # trim leading/trailing blank lines
  msg="$(printf '%s' "$msg" | awk 'NF{found=1} found{print}' | sed -e 's/[[:space:]]*$//')"
  printf '%s' "$msg"
}

# Usage: has_conflicts REPO_OR_WORKTREE REVSET
# Returns 0 (true) if any commit in REVSET has conflicts.
has_conflicts() {
  local repo="$1" revset="$2"
  local result
  result="$(jj -R "$repo" log -r "$revset" \
    --no-graph -T 'if(conflict, "yes\n")' 2>/dev/null)" || true
  [[ -n "$result" ]]
}

# Usage: find_parent_branch REPO TASK_ID TASK_PREFIX PROJECT_PREFIX
# Scans all task/project bookmarks for one whose owner task file lists TASK_ID
# in a subtask: entry (any checkbox state). Outputs the parent bookmark name.
# Exit 0: parent found (printed to stdout).
# Exit 1: no parent found (task is parentless; nothing printed).
# Exit 2: multiple parents found (error printed to stderr).
find_parent_branch() {
  local repo="$1" task_id="$2" task_prefix="$3" project_prefix="$4"
  local jj_opts=(-R "$repo")

  local all_bookmarks
  all_bookmarks="$(jj "${jj_opts[@]}" --ignore-working-copy log -r 'bookmarks()' \
    -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' --no-graph 2>/dev/null)" || true

  local found=''
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    is_task_branch "$branch" "$task_prefix" || is_project_branch "$branch" "$project_prefix" || continue
    [[ "$branch" == "$task_id" ]] && continue
    local suffix
    if is_task_branch "$branch" "$task_prefix"; then
      suffix="${branch#$task_prefix}"
    else
      suffix="${branch#$project_prefix}"
    fi
    local path
    path="$(task_file_path "$suffix")"
    local content
    content="$(jj_show_at_revision "$repo" "$branch" "$path")" || continue
    if printf '%s' "$content" | grep -qE "^subtask:[[:space:]]*\[[[:space:]x\-]\][[:space:]]+${task_id}([[:space:]]|$)"; then
      if [[ -n "$found" ]]; then
        log "Error: Multiple parent branches found for '$task_id': '$found' and '$branch'."
        return 2
      fi
      found="$branch"
    fi
  done <<< "$all_bookmarks"

  [[ -z "$found" ]] && return 1
  printf '%s' "$found"
}

# Usage: resolve_task_range REPO [TASK_ID]
# Resolves the revision range covering a task branch's unmerged commits since it
# diverged from its parent branch.
#
# Without TASK_ID: resolves the current task branch and extends the upper bound
# beyond the task bookmark to include trailing commits ('@' if the working copy
# is non-empty, '@-' if it is empty).
# With TASK_ID: the upper bound is the task bookmark itself.
#
# Outputs "<parent_bookmark> <upper_bound>" to stdout.
# Exit 0: range resolved (printed to stdout).
# Exit 1: not on a task branch, bookmark not found, or no parent found.
# Exit 2: multiple parents found (error printed to stderr).
resolve_task_range() {
  local repo="$1" task_id_arg="${2:-}"

  local task_prefix project_prefix
  task_prefix="$(get_task_prefix "$repo")"
  project_prefix="$(get_project_prefix "$repo")"

  local task_bookmark upper_bound

  if [[ -z "$task_id_arg" ]]; then
    if ! task_bookmark="$(resolve_current_bookmark "$repo" "$task_prefix" "$project_prefix")"; then
      log "Error: Not on a task or project branch."
      return 1
    fi
    if [[ -z "$task_bookmark" ]]; then
      log "Error: Not on a task or project branch."
      return 1
    fi

    local wc_empty
    wc_empty="$(jj -R "$repo" log -r '@' --no-graph -T 'empty' 2>/dev/null)" || true
    if [[ "$wc_empty" == "true" ]]; then
      upper_bound='@-'
    else
      upper_bound='@'
    fi
  else
    task_bookmark="$task_id_arg"
    upper_bound="$task_bookmark"

    if ! jj -R "$repo" log -r "$task_bookmark" --no-graph -T 'commit_id' >/dev/null 2>&1; then
      log "Error: Bookmark '$task_bookmark' not found."
      return 1
    fi
  fi

  local parent_bookmark exit_code=0
  parent_bookmark="$(find_parent_branch "$repo" "$task_bookmark" "$task_prefix" "$project_prefix")" || exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    [[ $exit_code -eq 1 ]] && log "Error: No parent found for '$task_bookmark'."
    return $exit_code
  fi

  printf '%s %s' "$parent_bookmark" "$upper_bound"
}

# Usage: resolve_task_fork_point REPO PARENT_BOOKMARK UPPER_BOUND
# Outputs the commit_id of the fork point between PARENT_BOOKMARK and UPPER_BOUND.
# Exit 0: fork point resolved (printed to stdout).
# Exit 1: fork point could not be resolved (error printed to stderr).
resolve_task_fork_point() {
  local repo="$1" parent_bookmark="$2" upper_bound="$3"

  local fork_point
  if ! fork_point="$(jj -R "$repo" log -r "fork_point(${parent_bookmark} | ${upper_bound})" \
    --no-graph -T 'commit_id' 2>/dev/null)"; then
    log "Error: Could not resolve fork point between '$parent_bookmark' and '$upper_bound'."
    return 1
  fi
  if [[ -z "$fork_point" ]]; then
    log "Error: Could not resolve fork point between '$parent_bookmark' and '$upper_bound'."
    return 1
  fi

  printf '%s' "$fork_point"
}

# Usage: find_parent_project REPO TASK_ID TASK_PREFIX PROJECT_PREFIX
# Walks up the task hierarchy from TASK_ID to find the nearest ancestor project branch.
# Outputs the project branch name to stdout.
# Exit 0: project found (printed to stdout).
# Exit 1: no ancestor project found.
# Exit 2: multiple parents found at some level (error printed to stderr by find_parent_branch).
find_parent_project() {
  local repo="$1" task_id="$2" task_prefix="$3" project_prefix="$4"
  local cursor="$task_id"
  while true; do
    local parent='' exit_code=0
    parent="$(find_parent_branch "$repo" "$cursor" "$task_prefix" "$project_prefix")" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      return $exit_code
    fi
    if is_project_branch "$parent" "$project_prefix"; then
      printf '%s' "$parent"
      return 0
    fi
    cursor="$parent"
  done
}

# Usage: find_branch_for_task REPO TASK_ID TASK_PREFIX PROJECT_PREFIX
# Locates the canonical branch for TASK_ID using the "where to read" rule:
# scans all task/project bookmarks for one whose owner task file contains
# "subtask: [x] <task-id>" (merged); if found, outputs that parent branch.
# Otherwise checks if TASK_ID itself is a valid branch (ongoing) and outputs it.
# Exits 1 if neither is found.
find_branch_for_task() {
  local repo="$1" task_id="$2" task_prefix="$3" project_prefix="$4"
  local all_bookmarks
  all_bookmarks="$(jj -R "$repo" --ignore-working-copy log -r 'bookmarks()' \
    -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' --no-graph 2>/dev/null)" || true

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    is_task_branch "$branch" "$task_prefix" || is_project_branch "$branch" "$project_prefix" || continue
    local suffix
    if is_task_branch "$branch" "$task_prefix"; then
      suffix="${branch#$task_prefix}"
    else
      suffix="${branch#$project_prefix}"
    fi
    local path
    path="$(task_file_path "$suffix")"
    local c
    c="$(jj_show_at_revision "$repo" "$branch" "$path")" || continue
    if printf '%s' "$c" | grep -qE "^subtask:[[:space:]]*\[x\][[:space:]]+${task_id}([[:space:]]|$)"; then
      printf '%s' "$branch"
      return 0
    fi
  done <<< "$all_bookmarks"

  # Not merged — use task's own branch
  if jj -R "$repo" --ignore-working-copy log -r "$task_id" --no-graph -T '' 2>/dev/null; then
    printf '%s' "$task_id"
    return 0
  fi

  return 1
}

# Usage: get_worktree_current_rev WORKTREE
# Prints the change_id of @ in the given worktree. Exits 1 on failure.
# We return the change_id (not the commit_id) because change IDs survive
# rebases: if @ is a descendant of a rebased branch, jj creates a new
# commit with the same change ID, so `jj edit <change_id>` will always
# resolve to the correct (post-rebase) version of the working-copy commit.
get_worktree_current_rev() {
  local worktree="$1"
  jj -R "$worktree" log -r '@' --no-graph -T 'change_id' 2>/dev/null
}

# Usage: resolve_current_worktree REPO
# Prints the current workspace root; falls back to REPO if not in a workspace.
resolve_current_worktree() {
  local repo="$1"
  jj -R "$repo" workspace root 2>/dev/null || printf '%s' "$repo"
}

# Usage: resolve_task_worktree REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX CURRENT_WORKTREE [WORKTREE_ARG]
#
# Resolves which worktree to operate on for BOOKMARK:
#   0 matches → use CURRENT_WORKTREE (fallback)
#   1 match   → use that worktree
#   multiple  → if CURRENT_WORKTREE is one of them, use it;
#               else if WORKTREE_ARG is given, use it;
#               else error and list candidates
#
# Prints the resolved worktree path to stdout. Exits 1 on unresolvable ambiguity.
resolve_task_worktree() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  local current_worktree="$5" worktree_arg="${6:-}"

  local found wt_count
  found="$(find_worktrees_for_branch "$repo" "$bookmark" "$task_prefix" "$project_prefix")"
  wt_count="$(printf '%s' "$found" | grep -c . 2>/dev/null || true)"

  case "$wt_count" in
    0) printf '%s' "$current_worktree" ;;
    1) printf '%s' "$found" ;;
    *)
      if printf '%s\n' "$found" | grep -qxF "$current_worktree"; then
        printf '%s' "$current_worktree"
        return 0
      fi
      if [[ -n "$worktree_arg" ]]; then
        printf '%s' "$worktree_arg"
        return 0
      fi
      log "Error: Multiple workspaces found for '$bookmark'; use --worktree=<path>:"
      printf '%s\n' "$found" | while IFS= read -r p; do log "  $p"; done
      return 1
      ;;
  esac
}

# Usage: parse_workspace_list_line LINE
# Parses one line from `jj workspace list -T 'name ++ ": " ++ root ++ "\n"'`.
# Outputs two lines to stdout:
#   line 1: workspace name
#   line 2: absolute filesystem path, or empty string if the path is an error
#            (i.e. the workspace has no recorded or resolvable path)
# Lines with error paths look like: "name: <Error: Workspace has no recorded path: name>"
# write_and_commit_on_branch REPO TARGET_WORKTREE BOOKMARK CURRENT_WORKTREE \
#                            CURRENT_BOOKMARK MESSAGE WRITER_FN [WRITER_ARGS...]
#
# Applies filesystem mutations and commits them onto BOOKMARK, advancing the
# bookmark. WRITER_FN is invoked with the destination worktree root as its first
# argument, followed by any WRITER_ARGS.
#
#   same-branch  - BOOKMARK is checked out in TARGET_WORKTREE: write there and
#                  commit normally.
#   cross-branch - otherwise (the task has no worktree of its own, or the current
#                  worktree is on a different branch): `jj edit BOOKMARK` and
#                  `jj new`, write into REPO, commit, advance the bookmark, then
#                  restore the working copy to its original parent. This lets
#                  commands mutate tasks that have not been checked out.
#
# Must be called inside a transaction. CURRENT_BOOKMARK must be resolved by the
# caller *before* tt_begin_transaction, since resolution can trigger a jj snapshot.
write_and_commit_on_branch() {
  local repo="$1" target_worktree="$2" bookmark="$3"
  local current_worktree="$4" current_bookmark="$5" message="$6" writer_fn="$7"
  shift 7

  if [[ "$target_worktree" == "$current_worktree" && "$current_bookmark" != "$bookmark" ]]; then
    # Cross-branch: since @ is empty (callers require a clean WC), save the parent
    # commit_id so the working copy can be restored after committing on the target.
    local original_parent_rev
    original_parent_rev="$(jj -R "$repo" log -r '@-' --no-graph -T 'commit_id' 2>/dev/null)"

    jj -R "$repo" edit "$bookmark"
    jj -R "$repo" new

    "$writer_fn" "$repo" "$@"

    jj -R "$repo" commit -m "$message"
    jj -R "$repo" bookmark set "$bookmark" -r '@-'
    jj -R "$repo" new -r "$original_parent_rev"
  else
    "$writer_fn" "$target_worktree" "$@"

    jj -R "$target_worktree" commit -m "$message"
    jj -R "$target_worktree" bookmark set "$bookmark" -r '@-'
  fi
}

parse_workspace_list_line() {
  local line="$1"
  local ws_name ws_path
  ws_name="$(printf '%s' "$line" | sed 's/: .*//')"
  ws_path="$(printf '%s' "$line" | sed 's/^[^:]*: //')"
  if [[ "$ws_path" == '<Error:'* ]]; then
    ws_path=''
  fi
  printf '%s\n%s\n' "$ws_name" "$ws_path"
}

# Usage: find_worktrees_for_branch REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX
# Outputs one workspace root path per line for each jj workspace where
# BOOKMARK is the current branch (resolved via resolve_current).
# Uses jj template 'name ++ ": " ++ root ++ "\n"' to get workspace paths.
find_worktrees_for_branch() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  # Get all workspace names + root paths using explicit template.
  # Format per line: "name: /absolute/path" or "name: <Error: ...>" for missing paths.
  local ws_list
  ws_list="$(jj -R "$repo" --ignore-working-copy workspace list --no-pager \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || return 0
  while IFS= read -r ws_line; do
    [[ -z "$ws_line" ]] && continue
    local parsed ws_name ws_root
    parsed="$(parse_workspace_list_line "$ws_line")"
    ws_name="$(printf '%s' "$parsed" | sed -n '1p')"
    ws_root="$(printf '%s' "$parsed" | sed -n '2p')"
    [[ -z "$ws_root" ]] && continue
    [[ ! -d "$ws_root" ]] && continue
    # Resolve current bookmark in this workspace
    local ws_bookmark
    ws_bookmark="$(resolve_current_bookmark "$ws_root" "$task_prefix" "$project_prefix" 2>/dev/null)" || continue
    if [[ "$ws_bookmark" == "$bookmark" ]]; then
      printf '%s\n' "$ws_root"
    fi
  done <<< "$ws_list"
}

# Usage: resolve_current REPO TASK_PREFIX PROJECT_PREFIX
#
# Resolve the "current branch" (closest ancestor of the working copy @ that has a bookmark).
# Uses heads() so that when @ is a working-copy commit (direct descendant of a task), we get
# the task bookmark, not a more distant ancestor like main.
# Outputs three lines to stdout:
#   line 1: rev       — commit ID at the current branch, or '@' if no bookmarks in ancestry
#   line 2: task_file — path to .tt/task/<slug>-<hex>.md, or empty if current branch is a root
#   line 3: bookmark  — bookmark name, or empty if current branch is a root
#
# Exits 1 if the current branch cannot be resolved.
resolve_current() {
  local repo="$1"
  local task_prefix="$2"
  local project_prefix="$3"
  local jj_opts=(-R "$repo")
  local current_branch

  current_branch="$(jj "${jj_opts[@]}" --ignore-working-copy log -r 'heads(ancestors(@) & bookmarks())' -n 1 --no-graph -T 'local_bookmarks.map(|b| b.name()).join(",")' 2>/dev/null)" || true
  current_branch="${current_branch%%,*}"  # Take first if comma-separated

  if [[ -z "$current_branch" ]]; then
    printf '%s\n\n\n' '@'
  else
    local parent_rev
    if ! parent_rev="$(jj "${jj_opts[@]}" --ignore-working-copy log -r "$current_branch" -n 1 --no-graph -T 'commit_id' 2>/dev/null)"; then
      log "Error: Could not resolve current branch: $current_branch"
      exit 1
    fi
    if is_task_branch "$current_branch" "$task_prefix"; then
      printf '%s\n%s\n%s\n' "$parent_rev" "$(task_file_path "${current_branch#$task_prefix}")" "$current_branch"
    elif is_project_branch "$current_branch" "$project_prefix"; then
      printf '%s\n%s\n%s\n' "$parent_rev" "$(task_file_path "${current_branch#$project_prefix}")" "$current_branch"
    else
      printf '%s\n\n\n' "$parent_rev"
    fi
  fi
}

# Usage: resolve_current_rev REPO TASK_PREFIX PROJECT_PREFIX
#
# Convenience wrapper around resolve_current that returns only the commit ID
# (line 1 of resolve_current's output). Prints the commit ID to stdout, or
# '@' if no bookmarks are found in the working copy ancestry.
resolve_current_rev() {
  local resolve_output
  resolve_output="$(resolve_current "$@")" || return $?
  printf '%s' "$resolve_output" | sed -n '1p'
}

# Usage: resolve_current_task_file REPO TASK_PREFIX PROJECT_PREFIX
#
# Convenience wrapper around resolve_current that returns only the task file path
# (line 2 of resolve_current's output). Prints the path to stdout, or an empty
# string if the current branch is not a task or project branch.
resolve_current_task_file() {
  local resolve_output
  resolve_output="$(resolve_current "$@")" || return $?
  printf '%s' "$resolve_output" | sed -n '2p'
}

# Usage: resolve_current_bookmark REPO TASK_PREFIX PROJECT_PREFIX
#
# Convenience wrapper around resolve_current that returns only the bookmark name
# (line 3 of resolve_current's output). Prints the bookmark name to stdout, or
# an empty string if no bookmark is found in the working copy ancestry.
resolve_current_bookmark() {
  local resolve_output
  resolve_output="$(resolve_current "$@")" || return $?
  printf '%s' "$resolve_output" | sed -n '3p'
}

# Usage: resolve_workspace_name REPO WORKTREE_PATH
# Prints the jj workspace name for the workspace at WORKTREE_PATH.
# Returns 0 and prints name if found, returns 1 if not found.
resolve_workspace_name() {
  local repo="$1" worktree_path="$2"
  local ws_list
  ws_list="$(jj -R "$repo" --ignore-working-copy workspace list \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || return 1
  while IFS= read -r ws_line; do
    [[ -z "$ws_line" ]] && continue
    local parsed ws_name ws_root
    parsed="$(parse_workspace_list_line "$ws_line")"
    ws_name="$(printf '%s' "$parsed" | sed -n '1p')"
    ws_root="$(printf '%s' "$parsed" | sed -n '2p')"
    if [[ "$ws_root" == "$worktree_path" ]]; then
      printf '%s' "$ws_name"
      return 0
    fi
  done <<< "$ws_list"
  return 1
}

# Usage: list_workspaces REPO TASK_PREFIX PROJECT_PREFIX
# Prints tab-separated workspace data, one line per workspace:
#   name\tpath\ttask_id
# path is empty string if unavailable; task_id is empty string if unresolved.
list_workspaces() {
  local repo="$1" task_prefix="$2" project_prefix="$3"
  local ws_raw
  ws_raw="$(jj -R "$repo" --ignore-working-copy workspace list \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null)" || return 0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local parsed ws_name ws_path
    parsed="$(parse_workspace_list_line "$line")"
    ws_name="$(printf '%s' "$parsed" | sed -n '1p')"
    ws_path="$(printf '%s' "$parsed" | sed -n '2p')"

    local task_id=''
    if [[ -n "$ws_path" && -d "$ws_path" ]]; then
      task_id="$(resolve_current_bookmark "$ws_path" "$task_prefix" "$project_prefix" 2>/dev/null)" || true
    fi

    printf '%s\t%s\t%s\n' "$ws_name" "$ws_path" "$task_id"
  done <<< "$ws_raw"
}

# Usage: forget_worktree REPO WORKSPACE_NAME [WORKTREE_PATH]
# Forgets the jj workspace from the repository model.
# If WORKTREE_PATH is provided, also removes all files from disk.
forget_worktree() {
  local repo="$1" ws_name="$2" worktree_path="${3:-}"
  jj -R "$repo" workspace forget "$ws_name"
  if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
    rm -rf "$worktree_path"
  fi
}

# Usage: check_bookmark_up_to_date REPO BOOKMARK
# Returns 0 if there are no commits between BOOKMARK and the working-copy parent
# (@-) that are not tracked by the bookmark. Returns 1 if commits exist.
check_bookmark_up_to_date() {
  local repo="$1" bookmark="$2"
  local ahead_commits
  ahead_commits="$(jj -R "$repo" log \
    -r "(::@- & ~::${bookmark})" \
    --no-graph -T 'change_id ++ "\n"' 2>/dev/null)" || return 0
  [[ -z "$ahead_commits" ]]
}


# Read the active worktree path from <workspace-dir>/HEAD.
# Returns 1 if the HEAD symlink is absent or unreadable; never falls back.
# Always returns a canonicalised absolute path (pwd -P).
get_active_worktree() {
  local workspace_dir="$1"
  local head_path="$workspace_dir/HEAD"
  [[ -L "$head_path" ]] || return 1
  local head_target
  head_target="$(readlink "$head_path")" || return 1
  [[ -n "$head_target" ]] || return 1
  # Resolve relative symlink
  if [[ "$head_target" != /* ]]; then
    head_target="${workspace_dir}/${head_target}"
  fi
  resolved="$(resolve_path_symlinks "$head_target")"
  printf '%s' "$resolved"
}

# Map a task status field to a GFM checkbox string.
# TODO -> [ ], IN-PROGRESS -> [-], DONE/Done -> [x], else [ ]
status_to_checkbox() {
  local s="$1"
  case "$s" in
    TODO)        printf '[ ]' ;;
    IN-PROGRESS) printf '[-]' ;;
    DONE|Done)   printf '[x]' ;;
    *)           printf '[?]' ;;
  esac
}

# ---------------------------------------------------------------------------
# Descendant task helpers
# ---------------------------------------------------------------------------

# Usage: collect_descendant_task_dirs REPO BRANCH TASK_ID TASK_PREFIX PROJECT_PREFIX
#
# Outputs one `.tt/task/<slug>` directory path per line for every task that
# is a descendant of TASK_ID (direct children, grandchildren, etc.), read
# from BRANCH.  Traversal follows `subtask:` frontmatter entries.
#
# Only task IDs whose prefix matches TASK_PREFIX or PROJECT_PREFIX are
# followed; unknown entries are skipped silently.
#
# Does not output the task's own directory (the caller already handles that).
collect_descendant_task_dirs() {
  local repo="$1" branch="$2" task_id="$3" task_prefix="$4" project_prefix="$5"

  # BFS queue (bash array)
  local -a queue=("$task_id")
  local -a visited=("$task_id")

  while [[ ${#queue[@]} -gt 0 ]]; do
    local current="${queue[0]}"
    queue=("${queue[@]:1}")      # shift

    # Derive slug and read task file from branch
    local suffix
    if is_task_branch "$current" "$task_prefix"; then
      suffix="${current#$task_prefix}"
    elif is_project_branch "$current" "$project_prefix"; then
      suffix="${current#$project_prefix}"
    else
      continue
    fi

    local tf
    tf="$(task_file_path "$suffix")"
    local content
    content="$(jj_show_at_revision "$repo" "$branch" "$tf")" || continue

    # Extract all subtask IDs (any checkbox state)
    while IFS= read -r subtask_id; do
      [[ -z "$subtask_id" ]] && continue
      # Skip if already visited (cycle guard)
      local already=false
      local v
      for v in "${visited[@]}"; do
        [[ "$v" == "$subtask_id" ]] && { already=true; break; }
      done
      "$already" && continue

      visited+=("$subtask_id")

      # Emit directory for this descendant
      local sub_suffix
      if is_task_branch "$subtask_id" "$task_prefix"; then
        sub_suffix="${subtask_id#$task_prefix}"
      elif is_project_branch "$subtask_id" "$project_prefix"; then
        sub_suffix="${subtask_id#$project_prefix}"
      else
        continue
      fi
      task_dir_path "$sub_suffix"
      printf '\n'

      # Enqueue for further traversal
      queue+=("$subtask_id")
    done < <(printf '%s' "$content" | awk '
      /^---$/ { n++; next }
      n == 1 && /^subtask:/ {
        sub(/^subtask:[[:space:]]*\[[[:space:]x\-]\][[:space:]]*/, "")
        print
      }
    ')
  done
}

# ---------------------------------------------------------------------------
# Task frontmatter parsing
# ---------------------------------------------------------------------------

# parse_task_frontmatter CONTENT
#
# Populates global variables from task frontmatter:
#   PARSED_TITLE, PARSED_STATUS, PARSED_CREATED, PARSED_UPDATED, PARSED_BODY
#   PARSED_LABELS (array), PARSED_CONTEXTS (array), PARSED_SUBTASKS (array)
#
# Exits 1 with an error message if any unrecognized frontmatter key is found.
# Known keys: title, status, created, updated, label, context, subtask
parse_task_frontmatter() {
  local content="$1"

  PARSED_TITLE="$(parse_quoted_frontmatter_field "$content" "title")"
  PARSED_STATUS="$(parse_frontmatter_field "$content" "status")"
  PARSED_CREATED="$(parse_frontmatter_field "$content" "created")"
  PARSED_UPDATED="$(parse_frontmatter_field "$content" "updated")"
  PARSED_BODY="$(parse_body "$content")"

  PARSED_LABELS=()
  while IFS= read -r lbl; do [[ -n "$lbl" ]] && PARSED_LABELS+=("$lbl"); done \
    < <(parse_repeated_frontmatter_field "$content" "label")

  PARSED_CONTEXTS=()
  while IFS= read -r ctx; do [[ -n "$ctx" ]] && PARSED_CONTEXTS+=("$ctx"); done \
    < <(parse_repeated_frontmatter_field "$content" "context")

  PARSED_SUBTASKS=()
  while IFS= read -r st; do [[ -n "$st" ]] && PARSED_SUBTASKS+=("$st"); done \
    < <(parse_repeated_frontmatter_field "$content" "subtask")

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

# ---------------------------------------------------------------------------
# Frontmatter mutation helpers
# ---------------------------------------------------------------------------

# write_task_file FILE TITLE STATUS BODY CREATED UPDATED
#
# Writes FILE with canonical frontmatter followed by BODY.
# Arrays REWRITE_LABELS, REWRITE_CONTEXTS, REWRITE_SUBTASKS must be set by
# the caller as environment variables before calling this function.
#
# Canonical field order: title, status, created, updated, label…, context…, subtask…
# STATUS is omitted when empty (used for context files which have no status field).
# Timestamps are caller-supplied; generate via generate_timestamp at the call site.
# Writes to a temp file and renames for atomicity.
write_task_file() {
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

# write_context_file FILE TITLE BODY CREATED UPDATED
#
# Writes a context file with title, created, updated, and body.
# Context files have no status, label, context, or subtask fields.
# Delegates to write_task_file with empty status and empty arrays.
write_context_file() {
  local file="$1"
  local title="$2"
  local body="$3"
  local created="$4"
  local updated="$5"
  local REWRITE_LABELS=() REWRITE_CONTEXTS=() REWRITE_SUBTASKS=()
  write_task_file "$file" "$title" "" "$body" "$created" "$updated"
}

# write_task_stub REPO TASK_SUFFIX
#
# Writes a minimal task file stub at .tt/task/<suffix>/TASK.md.
# Produces a placeholder title: "", status: TODO, and created/updated timestamps.
# The placeholder title is overwritten by the subsequent `tt task edit` call
# during task creation.
write_task_stub() {
  local repo="$1"
  local suffix="$2"
  local dir
  dir="$(task_dir_path "$suffix")"
  local file
  file="$(task_file_path "$suffix")"
  local ts
  ts="$(generate_timestamp)"
  mkdir -p "$repo/$dir"
  local REWRITE_LABELS=() REWRITE_CONTEXTS=() REWRITE_SUBTASKS=()
  write_task_file "$repo/$file" "" "TODO" "" "$ts" "$ts"
  log "Created task file: $file"
}

# _insert_frontmatter_line FILE LINE_TO_INSERT [BEFORE_PATTERN]
#
# Shared implementation for inserting a line into YAML frontmatter.
# Inserts LINE_TO_INSERT at the correct position:
#   - If BEFORE_PATTERN is given: before the first line matching that pattern
#     within the frontmatter block.
#   - If omitted: before the closing --- separator.
# Uses temp file + mv for atomicity.
_insert_frontmatter_line() {
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

# append_frontmatter_context FILE CTX_ID
#
# Appends a 'context: CTX_ID' line before the first 'subtask:' line
# (or before the closing '---' if no subtask entries exist).
# Does not update the 'updated:' timestamp — call update_frontmatter_timestamp
# separately if needed.
append_frontmatter_context() {
  _insert_frontmatter_line "$1" "context: $2" "^subtask:"
}

# append_frontmatter_subtask FILE TASK_ID
#
# Appends a 'subtask: [ ] TASK_ID' line before the closing '---' separator
# (after any existing context: or subtask: entries).
append_frontmatter_subtask() {
  _insert_frontmatter_line "$1" "subtask: [ ] $2" ""
}

# update_frontmatter_timestamp FILE TIMESTAMP
#
# Updates the 'updated:' field in the frontmatter of FILE to TIMESTAMP.
# Uses temp file + mv for atomicity.
update_frontmatter_timestamp() {
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

# ---------------------------------------------------------------------------
# Transaction management
#
# A "transaction" records the jj operation ID before and after a mutating tt
# command, enabling `tt history undo` to restore the repository state.
#
# Log file: <canonical-repo>/.tt/history
# Format:   one line per transaction: <before-op-id>:<after-op-id>
#           An in-progress transaction has an empty after-op-id: <before-op-id>:
#
# History location: the history file always lives in the **canonical** jj repo
# root (the repo whose .jj/repo entry is a directory, not a pointer file).
# Secondary jj workspaces have a .jj/repo *file* containing a relative path
# back to the canonical repo's .jj/repo directory. resolve_canonical_repo
# follows that pointer so all workspaces share a single history file.
#
# Nesting: sub-commands invoked by a top-level command inherit TT_TRANSACTION_ID
# via the environment. tt_begin_transaction is a no-op when TT_TRANSACTION_ID is
# already set. The internal (non-exported) _TT_TRANSACTION_OWNER variable
# stores the resolved history file path for the owning process; it is not
# exported so sub-processes never inherit it (they are not the transaction owner).
# ---------------------------------------------------------------------------

# Usage: resolve_canonical_repo REPO
# Returns the canonical repo root for the repository.
# If REPO is a secondary jj workspace (.jj/repo is a pointer file),
# follows the pointer to find the canonical repo root.
# If REPO is already the canonical repo (.jj/repo is a directory), returns REPO.
resolve_canonical_repo() {
  local repo="$1"
  local repo_entry="$repo/.jj/repo"
  if [[ -f "$repo_entry" ]]; then
    # Secondary workspace: .jj/repo is a file containing a relative path to
    # the canonical repo's .jj/repo directory (e.g. "../../../../repo/.jj/repo").
    local target
    target="$(cd "$repo/.jj" && realpath "$(cat "$repo_entry")")" \
      || { log "Error: Could not resolve canonical repo from $repo_entry"; return 1; }
    # target = /path/to/canonical/.jj/repo — strip /.jj/repo to get repo root
    dirname "$(dirname "$target")"
  else
    # Canonical repo: .jj/repo is a directory (the actual op store)
    printf '%s' "$repo"
  fi
}

# Usage: resolve_history_file_location REPO
# Returns the path to the .tt/history file for REPO.
# Follows .jj/repo pointer files so secondary jj workspaces resolve to the
# canonical repo's history file rather than a per-worktree copy.
# Canonical repos return <repo>/.tt/history directly.
resolve_history_file_location() {
  local repo="$1"
  local canonical_repo
  canonical_repo="$(resolve_canonical_repo "$repo")" || return 1
  printf '%s/%s' "$canonical_repo" "$(tt_metadata_path 'history')"
}

# Usage: tt_begin_transaction REPO
# Begins a tt transaction. No-op if TT_TRANSACTION_ID is already set (nested call).
# Captures the current jj operation ID, checks for in-progress transactions,
# appends "<before-op-id>:" to .tt/history, exports TT_TRANSACTION_ID, and sets
# an ERR trap to auto-rollback on failure.
#
# Resolves and caches the canonical history file path in _TT_TRANSACTION_OWNER
# at begin time (while the repo/worktree still exists on disk), so that
# tt_commit_transaction and tt_rollback_transaction can use it even if the
# worktree has been deleted by the time they run (e.g. worktree delete).
tt_begin_transaction() {
  local repo="$1"
  # No-op when nested (parent command already began a transaction)
  if [[ -n "${TT_TRANSACTION_ID:-}" ]]; then
    return 0
  fi

  local history_file
  history_file="$(resolve_history_file_location "$repo")" || exit 1

  # Capture current jj operation ID
  local before_op
  before_op="$(get_jj_op_id "$repo")" || {
    log "Error: Could not read jj operation ID to begin transaction"
    exit 1
  }

  # Check for in-progress transaction (last line has empty after-op-id)
  if [[ -f "$history_file" && -s "$history_file" ]]; then
    local last_line
    last_line="$(tail -n 1 "$history_file" 2>/dev/null)" || true
    if [[ -n "$last_line" ]]; then
      local last_after="${last_line#*:}"
      if [[ -z "$last_after" ]]; then
        log "Error: Another tt command is in progress (incomplete transaction)."
        log "  To revert a crashed process: tt history undo --force"
        log "  Or to keep the current state: tt history unlock --force"
        exit 1
      fi
    fi
  fi

  # Append in-progress entry to history log
  printf '%s:\n' "$before_op" >> "$history_file"

  # Export for sub-commands (nested tt_begin_transaction calls will be no-ops)
  export TT_TRANSACTION_ID="$before_op"
  # Store resolved history file path for commit/rollback (not exported — sub-processes
  # are not the transaction owner). Using the file path rather than `true` means we
  # avoid re-resolving at commit/rollback time, which may fail if the worktree has
  # been deleted by then (e.g. worktree delete).
  _TT_TRANSACTION_OWNER="$history_file"

  # Set ERR trap to auto-rollback on failure
  trap 'tt_rollback_transaction "'"$repo"'"' ERR
}

# Usage: tt_commit_transaction REPO
# Finalizes the transaction by writing the after-op-id into .tt/history.
# No-op when called from a nested sub-command (not the transaction owner).
tt_commit_transaction() {
  local repo="$1"
  # Only the owning process commits the transaction
  if [[ -z "${_TT_TRANSACTION_OWNER:-}" ]]; then
    return 0
  fi

  local history_file="${_TT_TRANSACTION_OWNER}"
  local before_op="${TT_TRANSACTION_ID}"

  # Derive canonical repo from the history file path (walk up from .tt/ to find .jj/).
  # This is safe even if $repo (a worktree) has been deleted, since history_file
  # is always inside the canonical repo which remains on disk.
  local canonical_repo
  canonical_repo="$(cd "$(dirname "$history_file")" && find_repo_root)" || {
    log "Warning: Could not derive canonical repo from history file path; history may be incomplete"
    canonical_repo="$repo"
  }

  # Capture current jj operation ID
  local after_op
  after_op="$(get_jj_op_id "$canonical_repo")" || {
    log "Warning: Could not read jj operation ID for transaction commit; history may be incomplete"
    after_op="unknown"
  }

  # Replace the last line (in-progress: "<before>:") with the completed entry ("<before>:<after>")
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$ s|^${before_op}:\$|${before_op}:${after_op}|" "$history_file"
  else
    sed -i "$ s|^${before_op}:\$|${before_op}:${after_op}|" "$history_file"
  fi

  # Clear ERR trap and ownership flag
  trap - ERR
  unset _TT_TRANSACTION_OWNER
}

# Usage: tt_rollback_transaction REPO
# Rolls back the transaction by restoring jj to the before-op state and
# removing the in-progress line from .tt/history.
# No-op when called from a nested sub-command (not the transaction owner).
tt_rollback_transaction() {
  local repo="$1"
  # Only the owning process rolls back
  if [[ -z "${_TT_TRANSACTION_OWNER:-}" ]]; then
    return 0
  fi

  local before_op="${TT_TRANSACTION_ID:-}"
  if [[ -z "$before_op" ]]; then
    return 0
  fi

  local history_file="${_TT_TRANSACTION_OWNER}"

  # Derive canonical repo from the history file path (walk up from .tt/ to find .jj/).
  local canonical_repo
  canonical_repo="$(cd "$(dirname "$history_file")" && find_repo_root)" || canonical_repo="$repo"

  log "Rolling back transaction (restoring jj operation: ${before_op:0:12}...)"

  # Restore jj to before-op state.
  # Use a subshell to cd into the canonical repo first, so jj can resolve CWD
  # even when the caller's working directory has been deleted (e.g. after
  # worktree delete).
  (cd "$canonical_repo" && jj -R "$canonical_repo" op restore "$before_op" 2>/dev/null) || \
    log "Warning: Could not restore jj operation state; manual recovery may be needed"

  # Remove the in-progress line from history
  if [[ -f "$history_file" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "/^${before_op}:\$/d" "$history_file"
    else
      sed -i "/^${before_op}:\$/d" "$history_file"
    fi
  fi

  # Clear ERR trap and ownership flag
  trap - ERR
  unset _TT_TRANSACTION_OWNER
}

# ---------------------------------------------------------------------------
# Interactive selection
# ---------------------------------------------------------------------------

# Usage: _select_value OPTION...
# Renders the built-in minimal picker UI to stderr and reads one line from
# /dev/tty. The raw reply is printed to stdout (validation is the caller's job).
# Returns 1 if no interactive terminal is available or the read fails.
_select_value() {
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

# Usage: printf '%s\n' item... | select_value
# Reads newline-separated options from stdin, presents a picker, and writes the
# selected option to stdout.
#
# When TT_SELECT is set it is run via `sh -c` as the picker: it receives the
# options on stdin and must write exactly one of them to stdout. Otherwise the
# built-in picker (_select_value) is used.
#
# Returns 1 if no options were provided, if the picker fails, or if the picker's
# output does not exactly match one of the provided options.
select_value() {
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
    choice="$(_select_value "${options[@]}")" || return 1
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
