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
#
# Every operation takes the repository root — or, for the working-copy group,
# the worktree root — as its first argument.

_TT_REPO_LIB_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
. "$_TT_REPO_LIB_DIR/vcs/jj.sh"

# --- Repository discovery ---
_repo__check_is_repository()       { _jj__check_is_repository "$@"; }
_repo__find_repository_root()      { _jj__find_repository_root "$@"; }
_repo__resolve_repository_root()   { _jj__resolve_repository_root "$@"; }
_repo__resolve_repository_path()   { _jj__resolve_repository_path "$@"; }
_repo__get_backend_type()          { _jj__get_backend_type "$@"; }
_repo__check_backend_supported()   { _jj__check_backend_supported "$@"; }

# --- Operation log ---
_repo__get_operation_id()          { _jj__get_operation_id "$@"; }
_repo__restore_operation()         { _jj__restore_operation "$@"; }

# --- Revisions ---
_repo__get_commit_description()    { _jj__get_commit_description "$@"; }
_repo__resolve_commit()            { _jj__resolve_commit "$@"; }
_repo__resolve_single_commit()     { _jj__resolve_single_commit "$@"; }
_repo__resolve_change()            { _jj__resolve_change "$@"; }
_repo__get_commit_timestamp()      { _jj__get_commit_timestamp "$@"; }
_repo__check_is_canonical_commit_id() { _jj__check_is_canonical_commit_id "$@"; }
_repo__check_revision_exists()     { _jj__check_revision_exists "$@"; }
_repo__check_commit_empty()        { _jj__check_commit_empty "$@"; }
_repo__check_has_conflicts()       { _jj__check_has_conflicts "$@"; }
_repo__check_descendants_have_conflicts() { _jj__check_descendants_have_conflicts "$@"; }
_repo__check_range_has_conflicts() { _jj__check_range_has_conflicts "$@"; }
_repo__check_is_ancestor()         { _jj__check_is_ancestor "$@"; }
_repo__filter_commits_reachable_from() { _jj__filter_commits_reachable_from "$@"; }
_repo__find_fork_point_commit()    { _jj__find_fork_point_commit "$@"; }
_repo__list_commits_in_range()     { _jj__list_commits_in_range "$@"; }
_repo__list_commits_in_dag_range() { _jj__list_commits_in_dag_range "$@"; }
_repo__count_commits_in_range()    { _jj__count_commits_in_range "$@"; }
_repo__list_range_root_commits()   { _jj__list_range_root_commits "$@"; }
_repo__list_range_root_parent_commits() { _jj__list_range_root_parent_commits "$@"; }
_repo__check_range_covered()       { _jj__check_range_covered "$@"; }
_repo__format_revision_range()     { _jj__format_revision_range "$@"; }
_repo__list_mainline_commits()     { _jj__list_mainline_commits "$@"; }

# --- Task-range queries ---
_repo__find_file_introduction()    { _jj__find_file_introduction "$@"; }
_repo__find_prefix_introduction()  { _jj__find_prefix_introduction "$@"; }
_repo__list_descendant_changes()   { _jj__list_descendant_changes "$@"; }
_repo__list_file_waypoints()       { _jj__list_file_waypoints "$@"; }
_repo__sort_commits_by_ancestry()  { _jj__sort_commits_by_ancestry "$@"; }

# --- Working copy (restricted: worktree-level callers only) ---
_repo__check_working_copy_clean()  { _jj__check_working_copy_clean "$@"; }
_repo__list_working_copy_changes() { _jj__list_working_copy_changes "$@"; }
_repo__get_worktree_checkout_revision() { _jj__get_worktree_checkout_revision "$@"; }
_repo__get_working_copy_revision() { _jj__get_working_copy_revision "$@"; }
_repo__get_working_copy_parent()   { _jj__get_working_copy_parent "$@"; }
_repo__set_working_copy_revision() { _jj__set_working_copy_revision "$@"; }
_repo__new_working_copy_child()    { _jj__new_working_copy_child "$@"; }
_repo__commit_working_copy()       { _jj__commit_working_copy "$@"; }
_repo__snapshot_worktree()         { _jj__snapshot_worktree "$@"; }
_repo__reattach_worktree()         { _jj__reattach_worktree "$@"; }
_repo__refresh_worktree()          { _jj__refresh_worktree "$@"; }

# --- Mutations (bare; no working copy involved) ---
_repo__commit_changeset()          { _jj__commit_changeset "$@"; }
_repo__create_merge_commit()       { _jj__create_merge_commit "$@"; }
_repo__set_description()           { _jj__set_description "$@"; }
_repo__move_commits()              { _jj__move_commits "$@"; }
_repo__squash_commit()             { _jj__squash_commit "$@"; }
_repo__restore_tree()              { _jj__restore_tree "$@"; }
_repo__restore_path()              { _jj__restore_path "$@"; }
_repo__abandon_commit()            { _jj__abandon_commit "$@"; }

# --- Bookmarks ---
_repo__set_bookmark()              { _jj__set_bookmark "$@"; }
_repo__list_bookmark_names()       { _jj__list_bookmark_names "$@"; }
_repo__list_bookmarks_at()         { _jj__list_bookmarks_at "$@"; }
_repo__check_bookmark_exists()     { _jj__check_bookmark_exists "$@"; }
_repo__rename_bookmark()           { _jj__rename_bookmark "$@"; }
_repo__delete_bookmark()           { _jj__delete_bookmark "$@"; }

# --- Worktrees ---
_repo__resolve_worktree_root()     { _jj__resolve_worktree_root "$@"; }
_repo__list_worktrees()            { _jj__list_worktrees "$@"; }
_repo__forget_worktree()           { _jj__forget_worktree "$@"; }
_repo__create_worktree()           { _jj__create_worktree "$@"; }
_repo__get_worktree_revision()     { _jj__get_worktree_revision "$@"; }

# --- Files ---
_repo__read_file_at_revision()     { _jj__read_file_at_revision "$@"; }
_repo__read_symlink_at_revision()  { _jj__read_symlink_at_revision "$@"; }
_repo__read_file_at_operation()    { _jj__read_file_at_operation "$@"; }
_repo__check_file_exists_at_revision() { _jj__check_file_exists_at_revision "$@"; }
_repo__list_files_at_revision()    { _jj__list_files_at_revision "$@"; }
_repo__list_files_at_operation()   { _jj__list_files_at_operation "$@"; }
_repo__list_changed_files()        { _jj__list_changed_files "$@"; }
_repo__list_changed_files_in_range() { _jj__list_changed_files_in_range "$@"; }
_repo__get_file_diff()             { _jj__get_file_diff "$@"; }
_repo__show_diff()                 { _jj__show_diff "$@"; }
