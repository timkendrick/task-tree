# Path construction and canonicalization helpers for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Public surface:
#   TT_METADATA_DIR              — repo-relative tt metadata directory
#   TT_TASK_SYMLINK_FILENAME     — repo-root symlink to the current task file
#   _path__metadata               — path within the tt metadata directory
#   _path__task_root              — directory containing all task directories
#   _path__task_file              — canonical path to a task's TASK.md
#   _path__task_dir               — canonical directory path for a task
#   _path__task_context           — canonical path to a context file
#   _path__metadata_exclusions    — tt-metadata paths that diffs should exclude
#   _path__resolve_symlinks       — canonicalize a directory path (pwd -P)
#   _path__dirname             — directory part of a path, without a process
#   _path__make_absolute_symlink  — create/replace a symlink with an absolute target

# The tt metadata directory, relative to the repository root. All task files,
# context files, configuration, hooks and history live beneath this directory.
# Use this instead of hardcoding '.tt' so the location is defined in one place.
TT_METADATA_DIR='.tt'

# The repo-root symlink pointing at the current task's TASK.md. Although it
# lives outside TT_METADATA_DIR it is tt metadata, not project content.
TT_TASK_SYMLINK_FILENAME='TASK.md'

# The repo-relative directory containing all task directories.
TT_TASK_ROOT_DIR="$TT_METADATA_DIR/task"

# Usage: _path__metadata [SUBPATH]
# Returns the repo-relative path to the tt metadata directory, optionally with
# SUBPATH appended (e.g. _path__metadata "config.toml" -> ".tt/config.toml").
_path__metadata() {
  local subpath="${1:-}"
  if [[ -z "$subpath" ]]; then
    printf '%s' "$TT_METADATA_DIR"
  else
    printf '%s/%s' "$TT_METADATA_DIR" "$subpath"
  fi
}

# Usage: _path__task_root
# Returns the canonical directory path containing all task directories.
_path__task_root() {
  printf '%s' "$TT_TASK_ROOT_DIR"
}

# Usage: _path__metadata_exclusions
# Emits one "<kind>\t<path>" record per tt-metadata path that diffs should exclude.
# <kind> is 'dir' or 'file'. Backends translate these into their own path syntax.
_path__metadata_exclusions() {
  printf 'dir\t%s\nfile\t%s\n' "$TT_METADATA_DIR" "$TT_TASK_SYMLINK_FILENAME"
}

# Usage: _path__task_file SUFFIX
# Returns the canonical path to a task's TASK.md file.
# SUFFIX is the slug-hex part (e.g. "my-task-abc12345").
_path__task_file() {
  local suffix="$1"
  printf '%s/%s/%s' "$TT_TASK_ROOT_DIR" "$suffix" "$TT_TASK_SYMLINK_FILENAME"
}

# Usage: _path__task_dir SUFFIX
# Returns the canonical directory path for a task.
_path__task_dir() {
  local suffix="$1"
  printf '%s/%s' "$TT_TASK_ROOT_DIR" "$suffix"
}

# Usage: _path__task_context SUFFIX CTX_ID
# Returns the canonical path to a context file.
# CTX_ID is "context/<ctx-slug>-<ctx-hex>" (without .md).
_path__task_context() {
  local suffix="$1"
  local ctx_id="$2"
  printf '%s/%s/%s.md' "$TT_TASK_ROOT_DIR" "$suffix" "$ctx_id"
}

# Resolve DIR to a canonical absolute path, following OS-level symlinks (pwd -P).
# Exits 1 if the directory does not exist or cannot be entered.
# Usage: _path__resolve_symlinks DIR
_path__resolve_symlinks() {
  (cd "$1" && pwd -P)
}

# Usage: _path__dirname PATH
# Prints the directory part of PATH as `dirname` would: trailing slashes
# dropped, "." for a bare name, "/" for a top-level entry. Pure bash, so it
# costs no process. The only places that strip a path inline instead are the
# script-directory lines that run before this module is loaded, and the test
# harness, which does not load it.
_path__dirname() {
  local path="$1"
  while [[ "$path" == */ && "$path" != '/' ]]; do path="${path%/}"; done
  if [[ "$path" != */* ]]; then
    printf '.'
  elif [[ "${path%/*}" == '' ]]; then
    printf '/'
  else
    printf '%s' "${path%/*}"
  fi
}

# Usage: _path__make_absolute_symlink TARGET_PATH SYMLINK_PATH
# Creates or replaces SYMLINK_PATH pointing at TARGET_PATH, always using an
# absolute path for the target to prevent symlink loops (e.g. HEAD -> ./HEAD).
# TARGET_PATH must be an existing directory or file; exits 1 otherwise.
_path__make_absolute_symlink() {
  local target_path="$1" symlink_path="$2"
  if [[ ! -e "$target_path" ]]; then
    _ui__log "Error: Symlink target does not exist: $target_path"
    return 1
  fi
  if [[ "$target_path" != /* ]]; then
    target_path="$(_path__resolve_symlinks "$target_path")"
  fi
  ln -snf "$target_path" "$symlink_path"
}
