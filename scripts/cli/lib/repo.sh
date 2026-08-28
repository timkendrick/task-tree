# Backend-neutral VCS interface for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Declares one _repo__* wrapper per VCS operation and delegates each to the
# active backend (currently jj, lib/vcs/jj.sh). The wrapper list below is the
# backend contract: a backend must implement a same-suffix function for every
# wrapper, and nothing outside this file may call backend functions directly.
#
# Public surface: every _repo__* function declared below. Argument and output
# conventions are documented on the backend implementations.

_TT_REPO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_TT_REPO_LIB_DIR/vcs/jj.sh"

# --- Repository discovery ---
_repo__check_is_repository()       { _jj__check_is_repository "$@"; }
_repo__find_repository_root()      { _jj__find_repository_root "$@"; }
_repo__resolve_repository_root()   { _jj__resolve_repository_root "$@"; }
_repo__resolve_repository_path()   { _jj__resolve_repository_path "$@"; }

# --- Operation log ---
_repo__get_operation_id()          { _jj__get_operation_id "$@"; }

# --- Revisions ---
_repo__count_revisions()           { _jj__count_revisions "$@"; }
_repo__get_commit_description()    { _jj__get_commit_description "$@"; }
_repo__check_has_conflicts()       { _jj__check_has_conflicts "$@"; }
_repo__list_mainline_commits()     { _jj__list_mainline_commits "$@"; }

# --- Working copy (restricted: worktree-level callers only) ---
_repo__check_working_copy_clean()  { _jj__check_working_copy_clean "$@"; }
_repo__get_working_copy_revision() { _jj__get_working_copy_revision "$@"; }
_repo__get_working_copy_parent()   { _jj__get_working_copy_parent "$@"; }
_repo__set_working_copy_revision() { _jj__set_working_copy_revision "$@"; }
_repo__new_working_copy_child()    { _jj__new_working_copy_child "$@"; }
_repo__commit_working_copy()       { _jj__commit_working_copy "$@"; }

# --- Bookmarks ---
_repo__set_bookmark()              { _jj__set_bookmark "$@"; }

# --- Worktrees ---
_repo__resolve_worktree_root()     { _jj__resolve_worktree_root "$@"; }
_repo__list_worktrees()            { _jj__list_worktrees "$@"; }
_repo__forget_worktree()           { _jj__forget_worktree "$@"; }

# --- Files ---
_repo__read_file_at_revision()     { _jj__read_file_at_revision "$@"; }
_repo__read_file_at_operation()    { _jj__read_file_at_operation "$@"; }
