# Task model facade for tt bootstrap CLI scripts.
# Source this file; do not execute directly.
#
# Maps the task hierarchy (task/project branches, task files, subtask
# frontmatter) onto the underlying VCS: classifying branches, resolving the
# current task, walking parent/child relationships, resolving task revision
# ranges, and writing task files onto branches.
#
# Public surface:
#   _task__check_is_task_branch      — bookmark name matches the task ID pattern
#   _task__check_is_project_branch   — bookmark name matches the project ID pattern
#   _task__check_branch_exists       — bookmark resolves to a revision
#   _task__resolve_revision          — immutable commit ID of a revision
#   _task__delete_branch             — delete a task/project bookmark
#   _task__read_file                 — read a repo file as recorded on a branch
#   _task__assert_bookmark_current   — exit unless the bookmark tracks all commits up to @-
#   _task__check_bookmark_current    — test whether the bookmark tracks all commits up to @-
#   _task__find_parent_branch        — parent branch listing a task as a subtask
#   _task__find_parent_project       — nearest ancestor project branch
#   _task__find_branch               — canonical branch for a task ("where to read" rule)
#   _task__get_range_context         — task id + parent bookmark + upper bound
#   _task__resolve_range             — parent bookmark + upper bound only
#   _task__resolve_fork_point        — fork point commit between parent and upper bound
#   _task__get_full_range_records    — every commit component attributable to a task
#   _task__resolve_current           — rev/task-file/bookmark of the current branch
#   _task__resolve_current_revision  — commit ID of the current branch
#   _task__resolve_current_file      — task file path of the current branch
#   _task__resolve_current_branch    — bookmark name of the current branch
#   _task__collect_descendant_dirs   — task dirs for all descendants of a task
#   _task__write_stub                — minimal task file stub for a new task
#   _task__commit_on_branch          — staged bare write committed onto a bookmark
#   _task__commit_new_branch         — staged bare write starting a new bookmark
#   _task__commit_handoff            — staged bare write on a branch tip, bookmark unmoved
#   _task__merge_branch              — check-in merge commit (branch tip + handoff)
#   _task__check_conflicts           — whether a revision has merge conflicts
#   _task__advance_branch            — move a branch bookmark forward to a revision
#   _task__list_unmerged_changes     — paths changed by a branch's unmerged range
#
# The _task__full_range_* helpers are internal to _task__get_full_range_records,
# and __task__commit_staged is the private staging engine shared by
# _task__commit_on_branch, _task__commit_new_branch and _task__commit_handoff.

# Return true if bookmark name matches task ID pattern (<prefix><slug>-<hex>).
_task__check_is_task_branch() {
  local bookmark="$1"
  local prefix="$2"
  [[ "$bookmark" == "$prefix"* ]] && [[ "$bookmark" =~ -[0-9a-fA-F]{8}$ ]]
}

# Return true if bookmark name matches project ID pattern (<prefix><slug>-<hex>).
_task__check_is_project_branch() {
  local bookmark="$1"
  local prefix="$2"
  [[ "$bookmark" == "$prefix"* ]] && [[ "$bookmark" =~ -[0-9a-fA-F]{8}$ ]]
}

# Usage: _task__check_branch_exists REPO BRANCH
# Returns 0 when BRANCH resolves to a revision in REPO, non-zero otherwise.
# Documented pass-through to _repo__check_revision_exists so commands can test
# whether a task or project branch exists without reaching into the VCS layer.
_task__check_branch_exists() {
  local repo="$1" branch="$2"
  _repo__check_revision_exists "$repo" "$branch"
}

# Usage: _task__resolve_revision REPO REV
# Prints the immutable commit ID of REV (a bookmark name, '@', or any other
# revision expression). Returns non-zero with nothing printed when REV does
# not resolve. Documented pass-through to _repo__resolve_commit so commands can
# pin a branch tip or fork revision without reaching into the VCS layer.
_task__resolve_revision() {
  local repo="$1" rev="$2"
  local commit
  commit="$(_repo__resolve_commit "$repo" "$rev")" || return 1
  [[ -n "$commit" ]] || return 1
  printf '%s' "$commit"
}

# Usage: _task__delete_branch REPO BRANCH
# Deletes the BRANCH bookmark. Returns non-zero when no such bookmark exists.
# Documented pass-through to _repo__delete_bookmark so commands can retire a
# task or project branch without reaching into the VCS layer.
_task__delete_branch() {
  local repo="$1" branch="$2"
  _repo__delete_bookmark "$repo" "$branch"
}

# Usage: _task__read_file REPO REV PATH
# Prints the content of the repo-root-relative PATH as recorded at REV
# (typically a task or project branch). Documented pass-through to
# _repo__read_file_at_revision so commands can read task and context files from
# a branch without reaching into the VCS layer.
_task__read_file() {
  local repo="$1" rev="$2" path="$3"
  _repo__read_file_at_revision "$repo" "$rev" "$path"
}

# Usage: _task__assert_bookmark_current REPO BOOKMARK
# Exits 1 if there are any commits between BOOKMARK and the working-copy parent
# (@-) that are not tracked by the bookmark. Used by commands that operate on
# the implicit current branch to ensure all work has been checkpointed.
#
# Skip this check when the user passes an explicit task-id, as that constitutes
# an intentional acknowledgement that the bookmark may be behind.
_task__assert_bookmark_current() {
  local repo="$1" bookmark="$2"
  if ! _task__check_bookmark_current "$repo" "$bookmark"; then
    _ui__log "Error: There are commits since the last checkpoint that are not tracked by the task bookmark."
    _ui__log "  Run 'tt task checkpoint' to record them before checking in."
    _ui__log "  Alternatively, pass the task ID explicitly to skip this check:"
    _ui__log "    tt task checkin ${bookmark}"
    exit 1
  fi
}

# Usage: _task__check_bookmark_current REPO BOOKMARK
# Returns 0 if there are no commits between BOOKMARK and the working-copy parent
# (@-) that are not tracked by the bookmark. Returns 1 if commits exist.
# A range that cannot be resolved counts as zero commits, so resolution
# failures are treated as "current".
_task__check_bookmark_current() {
  local repo="$1" bookmark="$2"
  local ahead_count
  ahead_count="$(_repo__count_commits_in_range "$repo" "$bookmark" '@-')"
  [[ "$ahead_count" -eq 0 ]]
}

# Usage: _task__find_parent_branch REPO TASK_ID TASK_PREFIX PROJECT_PREFIX
# Scans all task/project bookmarks for one whose owner task file lists TASK_ID
# in a subtask: entry (any checkbox state). Outputs the parent bookmark name.
# Exit 0: parent found (printed to stdout).
# Exit 1: no parent found (task is parentless; nothing printed).
# Exit 2: multiple parents found (error printed to stderr).
_task__find_parent_branch() {
  local repo="$1" task_id="$2" task_prefix="$3" project_prefix="$4"

  local all_bookmarks
  all_bookmarks="$(_repo__list_bookmark_names "$repo")" || true

  local found=''
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    _task__check_is_task_branch "$branch" "$task_prefix" || _task__check_is_project_branch "$branch" "$project_prefix" || continue
    [[ "$branch" == "$task_id" ]] && continue
    local suffix
    if _task__check_is_task_branch "$branch" "$task_prefix"; then
      suffix="${branch#$task_prefix}"
    else
      suffix="${branch#$project_prefix}"
    fi
    local path
    path="$(_path__task_file "$suffix")"
    local content
    content="$(_repo__read_file_at_revision "$repo" "$branch" "$path")" || continue
    if printf '%s' "$content" | grep -qE "^subtask:[[:space:]]*\[[[:space:]x\-]\][[:space:]]+${task_id}([[:space:]]|$)"; then
      if [[ -n "$found" ]]; then
        _ui__log "Error: Multiple parent branches found for '$task_id': '$found' and '$branch'."
        return 2
      fi
      found="$branch"
    fi
  done <<< "$all_bookmarks"

  [[ -z "$found" ]] && return 1
  printf '%s' "$found"
}

# Usage: _task__get_range_context REPO [TASK_ID]
# Resolves the task ID together with the revision range covering that task
# branch's unmerged commits since it diverged from its parent branch.
#
# Without TASK_ID: resolves the current task branch and extends the upper bound
# beyond the task bookmark to include trailing commits ('@' if the working copy
# is non-empty, '@-' if it is empty).
# With TASK_ID: the upper bound is the task bookmark itself.
#
# Outputs "<task-id>\t<parent-bookmark>\t<upper-bound>" to stdout.
# Exit 0: range resolved (printed to stdout).
# Exit 1: not on a task branch, bookmark not found, or no parent found.
# Exit 2: multiple parents found (error printed to stderr).
_task__get_range_context() {
  local repo="$1" task_id_arg="${2:-}"

  local task_prefix project_prefix
  task_prefix="$(_workspace__get_task_prefix "$repo")"
  project_prefix="$(_workspace__get_project_prefix "$repo")"

  local task_bookmark upper_bound

  if [[ -z "$task_id_arg" ]]; then
    if ! task_bookmark="$(_task__resolve_current_branch "$repo" "$task_prefix" "$project_prefix")"; then
      _ui__log "Error: Not on a task or project branch."
      return 1
    fi
    if [[ -z "$task_bookmark" ]]; then
      _ui__log "Error: Not on a task or project branch."
      return 1
    fi

    if _repo__check_commit_empty "$repo" '@'; then
      upper_bound='@-'
    else
      upper_bound='@'
    fi
  else
    task_bookmark="$task_id_arg"
    upper_bound="$task_bookmark"

    if ! _repo__check_revision_exists "$repo" "$task_bookmark"; then
      _ui__log "Error: Bookmark '$task_bookmark' not found."
      return 1
    fi
  fi

  local parent_bookmark exit_code=0
  parent_bookmark="$(_task__find_parent_branch "$repo" "$task_bookmark" "$task_prefix" "$project_prefix")" || exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    [[ $exit_code -eq 1 ]] && _ui__log "Error: No parent found for '$task_bookmark'."
    return $exit_code
  fi

  printf '%s\t%s\t%s' "$task_bookmark" "$parent_bookmark" "$upper_bound"
}

# Usage: _task__resolve_range REPO [TASK_ID]
# Compatibility wrapper over _task__get_range_context that outputs only the
# range endpoints: "<parent_bookmark> <upper_bound>".
# Exit codes match _task__get_range_context.
_task__resolve_range() {
  local repo="$1" task_id_arg="${2:-}"

  local context
  context="$(_task__get_range_context "$repo" "$task_id_arg")" || return $?

  local task_bookmark parent_bookmark upper_bound
  IFS=$'\t' read -r task_bookmark parent_bookmark upper_bound <<< "$context"

  printf '%s %s' "$parent_bookmark" "$upper_bound"
}

# Usage: _task__resolve_fork_point REPO PARENT_BOOKMARK UPPER_BOUND
# Outputs the commit ID of the fork point between PARENT_BOOKMARK and UPPER_BOUND.
# Exit 0: fork point resolved (printed to stdout).
# Exit 1: fork point could not be resolved (error printed to stderr).
_task__resolve_fork_point() {
  local repo="$1" parent_bookmark="$2" upper_bound="$3"

  local fork_point
  if ! fork_point="$(_repo__find_fork_point_commit "$repo" "$parent_bookmark" "$upper_bound")"; then
    _ui__log "Error: Could not resolve fork point between '$parent_bookmark' and '$upper_bound'."
    return 1
  fi
  if [[ -z "$fork_point" ]]; then
    _ui__log "Error: Could not resolve fork point between '$parent_bookmark' and '$upper_bound'."
    return 1
  fi

  printf '%s' "$fork_point"
}

# ---------------------------------------------------------------------------
# Full task range discovery
#
# A task's "full" range (the --all mode of revset/diff/changelog) is the union
# of every commit attributable to it across its retained lifecycle: commits
# made directly on the task branch, task-management operations performed on
# the task itself, and creation/checkin/deletion of its direct children --
# both already checked into its current parent and still unmerged on its own
# branch. See DESIGN.md for the conceptual model.
# ---------------------------------------------------------------------------

# Usage: _task__get_full_range_records REPO TASK_ID PARENT_BOOKMARK UPPER_BOUND
#
# Discovers every connected component of commits attributable to TASK_ID,
# oldest first. Records are tab-separated:
#   <base-id>\t<tip-id>\t<kind>\t<ordering-id>\t<timestamp>
#
# <kind> is one of:
#   historical — a prior check-in of TASK_ID into PARENT_BOOKMARK
#   child      — a direct child of TASK_ID checked into it
#   path       — a single commit that edited TASK_ID's own task file directly
#                (a task-management operation, or a direct-child create/delete)
#   current    — the task's current unmerged range (PARENT_BOOKMARK..UPPER_BOUND)
#
# Each component's revset is "<base-id>..<tip-id>" (base excluded, tip
# included), except for "current", whose base/tip may be bookmark names or
# '@'/'@-' rather than immutable commit IDs, matching _task__resolve_range.
#
# Only supports task branches (not project branches).
# Exit 1: TASK_ID is not a task branch, or a required revision could not be
# resolved (error printed to stderr).
_task__get_full_range_records() {
  local repo="$1" task_id="$2" parent_bookmark="$3" upper_bound="$4"

  local task_prefix project_prefix
  task_prefix="$(_workspace__get_task_prefix "$repo")"
  project_prefix="$(_workspace__get_project_prefix "$repo")"

  if ! _task__check_is_task_branch "$task_id" "$task_prefix"; then
    _ui__log "Error: Full task range discovery requires a task branch (got '$task_id')."
    return 1
  fi

  local target_file parent_file
  target_file="$(_path__task_file "${task_id#"$task_prefix"}")"
  parent_file="$(_task__full_range_bookmark_task_file "$parent_bookmark" "$task_prefix" "$project_prefix")"
  if [[ -z "$parent_file" ]]; then
    _ui__log "Error: '$parent_bookmark' is not a task or project branch."
    return 1
  fi

  local target_commit parent_commit upper_commit
  target_commit="$(_task__full_range_resolve_commit "$repo" "$task_id")" || return 1
  parent_commit="$(_task__full_range_resolve_commit "$repo" "$parent_bookmark")" || return 1
  upper_commit="$(_task__full_range_resolve_commit "$repo" "$upper_bound")" || return 1

  local creation_boundary
  creation_boundary="$(_task__full_range_creation_boundary \
    "$repo" "$task_id" "$target_file" "$target_commit" "$parent_commit")" || return 1

  # --- Read scalar waypoint fields for every commit that may participate in the
  # range: commit-id, ordered parent ids, timestamp, and whether it changed the
  # target task file. ---
  local -a wp_id=() wp_parents=() wp_ts=() wp_changed=()
  local wp_commit parents ts changed
  while IFS=$'\t' read -r wp_commit parents ts changed; do
    [[ -z "$wp_commit" ]] && continue
    wp_id+=("$wp_commit")
    wp_parents+=("$parents")
    wp_ts+=("$ts")
    wp_changed+=("$changed")
  done < <(_task__full_range_query_waypoints \
    "$repo" "$creation_boundary" "$target_commit" "$parent_commit" "$target_file")

  # --- Classify two-parent merge candidates as check-ins by the topology of
  # their second (handoff) parent's TASK.md symlink transition. ---
  local -a comp_base=() comp_tip=() comp_kind=() comp_order=() comp_ts=()
  local i
  for ((i = 0; i < ${#wp_id[@]}; i++)); do
    local commit_parents="${wp_parents[$i]}"
    [[ "$commit_parents" == *' '* ]] || continue
    local first_parent="${commit_parents%% *}" second_parent="${commit_parents#* }"
    [[ "$second_parent" == *' '* ]] && continue   # more than 2 parents: not a check-in merge

    local handoff_index=-1 j
    for ((j = 0; j < ${#wp_id[@]}; j++)); do
      if [[ "${wp_id[$j]}" == "$second_parent" ]]; then
        handoff_index=$j
        break
      fi
    done
    [[ $handoff_index -lt 0 ]] && continue
    local handoff_parent="${wp_parents[$handoff_index]}"
    [[ -z "$handoff_parent" || "$handoff_parent" == *' '* ]] && continue  # handoff must have exactly one parent

    local symlink_diff removed added
    symlink_diff="$(_task__full_range_symlink_diff "$repo" "${wp_id[$handoff_index]}")"
    removed="$(_task__full_range_parse_symlink_removed "$symlink_diff")"
    added="$(_task__full_range_parse_symlink_added "$symlink_diff")"
    [[ -z "$removed" || -z "$added" ]] && continue

    if [[ "$removed" == "$target_file" && "$added" == "$parent_file" ]]; then
      comp_base+=("$first_parent"); comp_tip+=("$handoff_parent"); comp_kind+=("historical")
      comp_order+=("${wp_id[$i]}"); comp_ts+=("${wp_ts[$i]}")
    elif [[ "$added" == "$target_file" && "$removed" != "$target_file" ]]; then
      comp_base+=("$first_parent"); comp_tip+=("${wp_id[$i]}"); comp_kind+=("child")
      comp_order+=("${wp_id[$i]}"); comp_ts+=("${wp_ts[$i]}")
    fi
  done

  # --- Single-commit path waypoints: direct edits to the target task file that
  # are not part of a check-in merge (task-management operations, and
  # direct-child create/delete commits recorded on whichever branch currently
  # owns the target's retained files). ---
  local -a path_base=() path_tip=() path_order=() path_ts=()
  for ((i = 0; i < ${#wp_id[@]}; i++)); do
    [[ "${wp_changed[$i]}" == "1" ]] || continue
    local commit_parents="${wp_parents[$i]}"
    [[ -z "$commit_parents" || "$commit_parents" == *' '* ]] && continue  # root or merge: not a path waypoint
    [[ "${wp_id[$i]}" == "$creation_boundary" ]] && continue
    path_base+=("$commit_parents"); path_tip+=("${wp_id[$i]}")
    path_order+=("${wp_id[$i]}"); path_ts+=("${wp_ts[$i]}")
  done

  # --- Current unmerged component, and the interleaved base/tip cover-range
  # pairs used to drop covered child/path candidates. ---
  local current_base="$parent_bookmark" current_tip="$upper_bound"
  local -a cover_pairs=("$parent_bookmark" "$upper_bound")
  for ((i = 0; i < ${#comp_base[@]}; i++)); do
    if [[ "${comp_kind[$i]}" == "historical" ]]; then
      cover_pairs+=("${comp_base[$i]}" "${comp_tip[$i]}")
    fi
  done

  local -a final_base=() final_tip=() final_kind=() final_order=() final_ts=()
  for ((i = 0; i < ${#comp_base[@]}; i++)); do
    _task__full_range_span_empty "$repo" "${comp_base[$i]}" "${comp_tip[$i]}" && continue
    if [[ "${comp_kind[$i]}" == "child" ]]; then
      _repo__check_range_covered "$repo" "${comp_base[$i]}" "${comp_tip[$i]}" "${cover_pairs[@]}" && continue
    fi
    final_base+=("${comp_base[$i]}"); final_tip+=("${comp_tip[$i]}")
    final_kind+=("${comp_kind[$i]}"); final_order+=("${comp_order[$i]}"); final_ts+=("${comp_ts[$i]}")
  done
  for ((i = 0; i < ${#path_base[@]}; i++)); do
    _task__full_range_span_empty "$repo" "${path_base[$i]}" "${path_tip[$i]}" && continue
    _repo__check_range_covered "$repo" "${path_base[$i]}" "${path_tip[$i]}" "${cover_pairs[@]}" && continue
    final_base+=("${path_base[$i]}"); final_tip+=("${path_tip[$i]}")
    final_kind+=("path"); final_order+=("${path_order[$i]}"); final_ts+=("${path_ts[$i]}")
  done

  # --- Order historical/child/path components by ancestry, then append the
  # current unmerged component last. ---
  if [[ ${#final_base[@]} -gt 0 ]]; then
    local ordered order_commit
    ordered="$(_repo__sort_commits_by_ancestry \
      "$repo" "$creation_boundary" "$target_commit" "$parent_commit" "${final_order[@]}")"
    while IFS= read -r order_commit; do
      [[ -z "$order_commit" ]] && continue
      for ((i = 0; i < ${#final_order[@]}; i++)); do
        if [[ "${final_order[$i]}" == "$order_commit" ]]; then
          printf '%s\t%s\t%s\t%s\t%s\n' \
            "${final_base[$i]}" "${final_tip[$i]}" "${final_kind[$i]}" "${final_order[$i]}" "${final_ts[$i]}"
          break
        fi
      done
    done <<< "$ordered"
  fi

  if ! _task__full_range_span_empty "$repo" "$current_base" "$current_tip"; then
    local current_ts
    current_ts="$(_repo__get_commit_timestamp "$repo" "$upper_commit")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$current_base" "$current_tip" "current" "$upper_commit" "$current_ts"
  fi
}

# Usage: _task__full_range_resolve_commit REPO REV
# Prints the immutable commit ID of REV. Exit 1 with an error if REV cannot be
# resolved.
_task__full_range_resolve_commit() {
  local repo="$1" rev="$2"
  local id
  id="$(_repo__resolve_commit "$repo" "$rev")" || id=''
  if [[ -z "$id" ]]; then
    _ui__log "Error: Could not resolve revision '$rev'."
    return 1
  fi
  printf '%s' "$id"
}

# Usage: _task__full_range_bookmark_task_file BOOKMARK TASK_PREFIX PROJECT_PREFIX
# Prints the canonical task file path owned by BOOKMARK, or nothing if
# BOOKMARK is neither a task nor a project branch.
_task__full_range_bookmark_task_file() {
  local bookmark="$1" task_prefix="$2" project_prefix="$3"
  if _task__check_is_task_branch "$bookmark" "$task_prefix"; then
    _path__task_file "${bookmark#"$task_prefix"}"
  elif _task__check_is_project_branch "$bookmark" "$project_prefix"; then
    _path__task_file "${bookmark#"$project_prefix"}"
  fi
}

# Usage: _task__full_range_creation_boundary REPO TASK_ID TARGET_FILE TARGET_COMMIT PARENT_COMMIT
# Prints the immutable commit ID of the unique commit that created TARGET_FILE
# within the combined ancestry of TARGET_COMMIT and PARENT_COMMIT. Exit 1 with
# an error if no such commit, or more than one, is found.
_task__full_range_creation_boundary() {
  local repo="$1" task_id="$2" target_file="$3" target_commit="$4" parent_commit="$5"
  local boundary
  if ! boundary="$(_repo__find_file_introduction "$repo" "$target_file" "$target_commit" "$parent_commit")"; then
    _ui__log "Error: Could not resolve a unique creation boundary for '$task_id'."
    return 1
  fi
  printf '%s' "$boundary"
}

# Usage: _task__full_range_query_waypoints REPO BOUNDARY HEAD_A HEAD_B TARGET_FILE
# Prints one tab-separated line per commit, oldest first, for every commit
# between BOUNDARY and the two heads that changes TARGET_FILE, changes the
# root TASK.md symlink, or is a merge with a parent that changes the root
# TASK.md symlink:
#   <commit-id>\t<parent-ids space-separated>\t<timestamp>\t<target-changed 0|1>
_task__full_range_query_waypoints() {
  local repo="$1" boundary="$2" head_a="$3" head_b="$4" target_file="$5"
  _repo__list_file_waypoints "$repo" "$boundary" "$head_a" "$head_b" \
    "$target_file" "$TT_TASK_SYMLINK_FILENAME"
}

# Usage: _task__full_range_symlink_diff REPO REV
# Prints the Git-format diff of the root TASK.md symlink at REV.
_task__full_range_symlink_diff() {
  local repo="$1" rev="$2"
  _repo__get_file_diff "$repo" "$rev" "$TT_TASK_SYMLINK_FILENAME"
}

# Usage: _task__full_range_parse_symlink_removed DIFF_TEXT
# Prints the removed symlink target from a Git-format TASK.md diff, or nothing.
_task__full_range_parse_symlink_removed() {
  printf '%s\n' "$1" | grep -E '^-[^-]' | head -1 | cut -c2-
}

# Usage: _task__full_range_parse_symlink_added DIFF_TEXT
# Prints the added symlink target from a Git-format TASK.md diff, or nothing.
_task__full_range_parse_symlink_added() {
  printf '%s\n' "$1" | grep -E '^\+[^+]' | head -1 | cut -c2-
}

# Usage: _task__full_range_span_empty REPO BASE TIP
# Returns 0 (true) if the range from BASE (exclusive) to TIP (inclusive)
# contains no commits.
_task__full_range_span_empty() {
  local repo="$1" base="$2" tip="$3"
  local count
  count="$(_repo__count_commits_in_range "$repo" "$base" "$tip")"
  [[ "$count" -eq 0 ]]
}

# Usage: _task__find_parent_project REPO TASK_ID TASK_PREFIX PROJECT_PREFIX
# Walks up the task hierarchy from TASK_ID to find the nearest ancestor project branch.
# Outputs the project branch name to stdout.
# Exit 0: project found (printed to stdout).
# Exit 1: no ancestor project found.
# Exit 2: multiple parents found at some level (error printed to stderr by _task__find_parent_branch).
_task__find_parent_project() {
  local repo="$1" task_id="$2" task_prefix="$3" project_prefix="$4"
  local cursor="$task_id"
  while true; do
    local parent='' exit_code=0
    parent="$(_task__find_parent_branch "$repo" "$cursor" "$task_prefix" "$project_prefix")" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      return $exit_code
    fi
    if _task__check_is_project_branch "$parent" "$project_prefix"; then
      printf '%s' "$parent"
      return 0
    fi
    cursor="$parent"
  done
}

# Usage: _task__find_branch REPO TASK_ID TASK_PREFIX PROJECT_PREFIX
# Locates the canonical branch for TASK_ID using the "where to read" rule:
# scans all task/project bookmarks for one whose owner task file contains
# "subtask: [x] <task-id>" (merged); if found, outputs that parent branch.
# Otherwise checks if TASK_ID itself is a valid branch (ongoing) and outputs it.
# Exits 1 if neither is found.
_task__find_branch() {
  local repo="$1" task_id="$2" task_prefix="$3" project_prefix="$4"
  local all_bookmarks
  all_bookmarks="$(_repo__list_bookmark_names "$repo")" || true

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    _task__check_is_task_branch "$branch" "$task_prefix" || _task__check_is_project_branch "$branch" "$project_prefix" || continue
    local suffix
    if _task__check_is_task_branch "$branch" "$task_prefix"; then
      suffix="${branch#$task_prefix}"
    else
      suffix="${branch#$project_prefix}"
    fi
    local path
    path="$(_path__task_file "$suffix")"
    local c
    c="$(_repo__read_file_at_revision "$repo" "$branch" "$path")" || continue
    if printf '%s' "$c" | grep -qE "^subtask:[[:space:]]*\[x\][[:space:]]+${task_id}([[:space:]]|$)"; then
      printf '%s' "$branch"
      return 0
    fi
  done <<< "$all_bookmarks"

  # Not merged — use task's own branch
  if _repo__check_revision_exists "$repo" "$task_id"; then
    printf '%s' "$task_id"
    return 0
  fi

  return 1
}

# Usage: _task__commit_on_branch REPO BRANCH MESSAGE
#          [--modify PATH]... [--delete PATH]... [--delete-prefix PREFIX]...
#          -- WRITER_FN [ARGS...]
#
# Commits a staged set of file writes and deletions onto BRANCH without
# touching any working copy: builds the change as a bare commit on top of the
# branch tip (_repo__commit_changeset), advances the BRANCH bookmark to it,
# reattaches the current worktree when it sat on the old tip
# (_worktree__reattach_current), and prints the new commit ID.
#
# The three inputs are ORTHOGONAL:
#   --modify         materializes an existing branch-tip file (repo-root-
#                    relative) into the staging directory for read-modify-
#                    write; a path absent at the tip is an ERROR.
#   staging dir      carries new and replaced content: WRITER_FN is invoked
#                    with the staging root as its first argument (followed by
#                    ARGS), and every file present under it afterwards lands
#                    in the commit at its stage-relative path.
#   --delete /       carry removals: each --delete names one repo-root-
#   --delete-prefix  relative file; each --delete-prefix is expanded to the
#                    exact files under it at the tip (a prefix matching no
#                    files contributes nothing).
# A file disappearing from the staging directory is NOT a deletion — removals
# are always declared via the delete flags.
#
# A non-zero WRITER_FN status aborts the call: nothing is committed and the
# bookmark does not move.
#
# Exit 0: commit created (ID printed to stdout).
# Exit non-zero: bad arguments, unresolvable branch, absent --modify path,
# writer failure, or a failed VCS step (error printed to stderr).
_task__commit_on_branch() {
  local repo="$1" branch="$2" message="$3"
  shift 3

  local tip
  tip="$(_repo__resolve_commit "$repo" "$branch")" || tip=''
  if [[ -z "$tip" ]]; then
    _ui__log "Error: Could not resolve branch '$branch'."
    return 1
  fi

  local new_commit
  new_commit="$(__task__commit_staged "$repo" "$tip" "$message" "$@")" || return 1
  [[ -n "$new_commit" ]] || return 1
  _repo__set_bookmark "$repo" "$branch" "$new_commit" || return 1
  _worktree__reattach_current "$repo" "$tip" "$new_commit" || return 1
  printf '%s\n' "$new_commit"
}

# Usage: _task__commit_new_branch REPO NEW_BRANCH PARENT_REV MESSAGE
#          [--allow-backwards] -- WRITER_FN [ARGS...]
#
# Starts a branch: builds a bare commit on top of PARENT_REV from the writes
# WRITER_FN leaves in a fresh staging directory (the same staging contract as
# _task__commit_on_branch, without the modify/delete flags), points the
# NEW_BRANCH bookmark at the new commit, and prints the commit ID. No working
# copy is touched, no worktree is reattached, and no out-of-sync report is
# produced: a branch that did not exist before the call has no worktrees
# sitting on it.
#
# --allow-backwards is passed through to the bookmark update so an existing
# NEW_BRANCH bookmark may be moved even when the new commit is not a
# descendant of its current position (forced branch re-creation).
#
# A non-zero WRITER_FN status aborts the call: nothing is committed and no
# bookmark is created or moved.
#
# Exit 0: commit created (ID printed to stdout).
# Exit non-zero: bad arguments, unresolvable PARENT_REV, writer failure, or a
# failed VCS step (error printed to stderr).
_task__commit_new_branch() {
  local repo="$1" new_branch="$2" parent_rev="$3" message="$4"
  shift 4

  local -a bookmark_flags=()
  if [[ "${1:-}" == '--allow-backwards' ]]; then
    bookmark_flags=(--allow-backwards)
    shift
  fi

  local parent_commit
  parent_commit="$(_repo__resolve_commit "$repo" "$parent_rev")" || parent_commit=''
  if [[ -z "$parent_commit" ]]; then
    _ui__log "Error: Could not resolve revision '$parent_rev'."
    return 1
  fi

  local new_commit
  new_commit="$(__task__commit_staged "$repo" "$parent_commit" "$message" "$@")" \
    || return 1
  [[ -n "$new_commit" ]] || return 1
  _repo__set_bookmark "$repo" "$new_branch" "$new_commit" \
    "${bookmark_flags[@]+"${bookmark_flags[@]}"}" || return 1
  printf '%s\n' "$new_commit"
}

# Usage: _task__commit_handoff REPO BRANCH MESSAGE
#          [--modify PATH]... [--delete PATH]... [--delete-prefix PREFIX]...
#          -- WRITER_FN [ARGS...]
#
# Builds the linear handoff commit of a check-in or publish: a staged bare
# write (the same flag and writer contract as _task__commit_on_branch)
# committed on top of BRANCH's tip, printing the new commit ID. Unlike
# _task__commit_on_branch, the BRANCH bookmark does NOT advance and no
# worktree is reattached: the handoff carries the file changes that belong to
# the RECEIVING branch's history — it becomes reachable only through the
# merge commit that lands it there (_task__merge_branch) — so the source
# branch, and every worktree sitting on it, stays exactly where it was.
#
# A non-zero WRITER_FN status aborts the call: nothing is committed.
#
# Exit 0: commit created (ID printed to stdout).
# Exit non-zero: bad arguments, unresolvable branch, absent --modify path,
# writer failure, or a failed VCS step (error printed to stderr).
_task__commit_handoff() {
  local repo="$1" branch="$2" message="$3"
  shift 3

  local tip
  tip="$(_repo__resolve_commit "$repo" "$branch")" || tip=''
  if [[ -z "$tip" ]]; then
    _ui__log "Error: Could not resolve branch '$branch'."
    return 1
  fi

  local new_commit
  new_commit="$(__task__commit_staged "$repo" "$tip" "$message" "$@")" || return 1
  [[ -n "$new_commit" ]] || return 1
  printf '%s\n' "$new_commit"
}

# Usage: _task__merge_branch REPO MESSAGE PARENT_REV HANDOFF_REV
#
# Creates the merge commit that lands a handoff on a receiving branch:
# a two-parent commit whose FIRST parent is PARENT_REV (the receiving
# branch's tip) and whose SECOND parent is HANDOFF_REV, described by MESSAGE.
# Prints the merge commit's ID; the caller advances the receiving branch's
# bookmark to it separately (_task__advance_branch).
#
# The parent order is semantic, not cosmetic: full-range discovery
# (_task__get_full_range_records) classifies historical check-ins by the shape
# of a merge's second parent, so the handoff must always be second.
#
# The merge carries no file writes of its own: the backend computes the
# merged tree from the two parents and represents any conflicts natively.
# Callers inspect the result with _task__check_conflicts and decide whether to
# keep it. Documented pass-through to _repo__create_merge_commit.
_task__merge_branch() {
  local repo="$1" message="$2" parent_rev="$3" handoff_rev="$4"
  _repo__create_merge_commit "$repo" "$message" "$parent_rev" "$handoff_rev"
}

# Usage: _task__check_conflicts REPO REV
# Returns 0 when REV (typically a freshly created merge commit) carries merge
# conflicts, non-zero when it is conflict-free. Documented pass-through to
# _repo__check_has_conflicts so commands can gate on a merge's conflict state
# without reaching into the VCS layer.
_task__check_conflicts() {
  local repo="$1" rev="$2"
  _repo__check_has_conflicts "$repo" "$rev"
}

# Usage: _task__advance_branch REPO BRANCH REV
# Moves the BRANCH bookmark forward to REV. REV must be a descendant of the
# bookmark's current position (the underlying bookmark update refuses
# backwards moves); use this to land a newly created commit — e.g. a check-in
# merge — on the branch that owns it. Documented pass-through to
# _repo__set_bookmark so commands can advance a branch without reaching into
# the VCS layer.
_task__advance_branch() {
  local repo="$1" branch="$2" rev="$3"
  _repo__set_bookmark "$repo" "$branch" "$rev"
}

# Usage: _task__list_unmerged_changes REPO PARENT_BRANCH CHILD_BRANCH [PREFIX]
#
# Prints the repo-root-relative paths (one per line) that CHILD_BRANCH's
# unmerged range — the commits reachable from CHILD_BRANCH but not from
# PARENT_BRANCH — changes as a whole, optionally restricted to paths under
# the directory PREFIX. Nothing is printed when the range changes nothing.
#
# The range is diffed as one unit anchored at the roots of the unmerged set
# ("roots(::child ~ ::parent)..child"), so content the child merely inherited
# from the parent at its fork point is never reported. The roots themselves
# are excluded from the diff: the first unmerged commit is the branch's own
# creation commit (its task file stub), which is never what a caller needs to
# inspect. This is deliberately a path listing rather than a content diff:
# its consumer (checkin's stray-task-file validation) needs to know WHICH
# task files the range touches, not what changed inside them.
#
# Returns non-zero (nothing printed) when the range cannot be diffed.
_task__list_unmerged_changes() {
  local repo="$1" parent_branch="$2" child_branch="$3" prefix="${4:-}"

  local changed
  changed="$(_repo__list_changed_files "$repo" \
    "roots(::${child_branch} ~ ::${parent_branch})..${child_branch}")" || return 1

  if [[ -z "$prefix" ]]; then
    [[ -n "$changed" ]] && printf '%s\n' "$changed"
    return 0
  fi

  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    [[ "$path" == "$prefix"/* ]] && printf '%s\n' "$path"
  done <<< "$changed"
  return 0
}

# Usage: __task__commit_staged REPO TIP MESSAGE
#          [--modify PATH]... [--delete PATH]... [--delete-prefix PREFIX]...
#          -- WRITER_FN [ARGS...]
#
# Private staging engine shared by _task__commit_on_branch and
# _task__commit_new_branch: materializes each --modify path from TIP into a
# fresh staging directory, expands --delete/--delete-prefix against TIP's
# tree, runs WRITER_FN with the staging root (followed by ARGS), commits the
# staged tree as a bare child of TIP (_repo__commit_changeset), and prints the
# new commit ID. Moves no bookmark and touches no worktree; the public
# wrappers layer those steps on.
#
# The staged work runs in a subshell whose EXIT trap removes the staging
# directory on every path, so no trap leaks into the caller and the function
# is safe to call from set -e scripts.
#
# Exit 0: commit created (ID printed to stdout).
# Exit non-zero: bad arguments, absent --modify path, writer failure, or a
# failed VCS step (error printed to stderr).
__task__commit_staged() {
  local repo="$1" tip="$2" message="$3"
  shift 3

  local -a modify_paths=() delete_paths=() delete_prefixes=()
  local saw_separator=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --modify|--delete|--delete-prefix)
        if [[ $# -lt 2 ]]; then
          _ui__log "Error: $1 requires a path argument."
          return 1
        fi
        case "$1" in
          --modify)        modify_paths+=("$2") ;;
          --delete)        delete_paths+=("$2") ;;
          --delete-prefix) delete_prefixes+=("$2") ;;
        esac
        shift 2
        ;;
      --)
        saw_separator=1
        shift
        break
        ;;
      *)
        _ui__log "Error: Unknown staged-commit flag: $1"
        return 1
        ;;
    esac
  done
  if [[ -z "$saw_separator" || $# -lt 1 ]]; then
    _ui__log "Error: A staged commit requires '-- WRITER_FN [ARGS...]'."
    return 1
  fi
  local writer_fn="$1"
  shift

  # The remainder runs in a subshell so an EXIT trap can remove the staging
  # directory on every path without leaking the trap into the caller.
  (
    local stage
    stage="$(mktemp -d)" || exit 1
    trap 'rm -rf "$stage"' EXIT

    local modify_path
    for modify_path in "${modify_paths[@]+"${modify_paths[@]}"}"; do
      mkdir -p "$stage/$(dirname "$modify_path")" || exit 1
      if ! _repo__read_file_at_revision "$repo" "$tip" "$modify_path" \
          > "$stage/$modify_path"; then
        _ui__log "Error: '$modify_path' does not exist on '$tip'."
        exit 1
      fi
    done

    local -a deletions=()
    local delete_path
    for delete_path in "${delete_paths[@]+"${delete_paths[@]}"}"; do
      deletions+=("$delete_path")
    done
    local delete_prefix expanded
    for delete_prefix in "${delete_prefixes[@]+"${delete_prefixes[@]}"}"; do
      expanded="$(_repo__list_files_at_revision "$repo" "$tip" "$delete_prefix")" \
        || expanded=''
      while IFS= read -r delete_path; do
        [[ -n "$delete_path" ]] && deletions+=("$delete_path")
      done <<< "$expanded"
    done

    "$writer_fn" "$stage" "$@" || {
      _ui__log "Error: Writer '$writer_fn' failed; nothing was committed."
      exit 1
    }

    local new_commit
    new_commit="$(_repo__commit_changeset "$repo" "$tip" "$message" "$stage" \
      "${deletions[@]+"${deletions[@]}"}")" || exit 1
    [[ -n "$new_commit" ]] || exit 1
    printf '%s\n' "$new_commit"
  )
}

# Usage: _task__resolve_current REPO TASK_PREFIX PROJECT_PREFIX
#
# Resolve the "current branch" (closest ancestor of the working copy @ that has a bookmark).
# The *closest* bookmarked ancestor matters: when @ is a working-copy commit
# (direct descendant of a task), we get the task bookmark, not a more distant
# ancestor like main.
# Outputs three lines to stdout:
#   line 1: rev       — commit ID at the current branch, or '@' if no bookmarks in ancestry
#   line 2: task_file — path to .tt/task/<slug>-<hex>.md, or empty if current branch is a root
#   line 3: bookmark  — bookmark name, or empty if current branch is a root
#
# Exits 1 if the current branch cannot be resolved.
_task__resolve_current() {
  local repo="$1"
  local task_prefix="$2"
  local project_prefix="$3"
  local current_branch

  current_branch="$(_repo__find_nearest_bookmark "$repo" '@')" || current_branch=''

  if [[ -z "$current_branch" ]]; then
    printf '%s\n\n\n' '@'
  else
    local parent_rev
    if ! parent_rev="$(_repo__resolve_commit "$repo" "$current_branch")"; then
      _ui__log "Error: Could not resolve current branch: $current_branch"
      exit 1
    fi
    if _task__check_is_task_branch "$current_branch" "$task_prefix"; then
      printf '%s\n%s\n%s\n' "$parent_rev" "$(_path__task_file "${current_branch#$task_prefix}")" "$current_branch"
    elif _task__check_is_project_branch "$current_branch" "$project_prefix"; then
      printf '%s\n%s\n%s\n' "$parent_rev" "$(_path__task_file "${current_branch#$project_prefix}")" "$current_branch"
    else
      printf '%s\n\n\n' "$parent_rev"
    fi
  fi
}

# Usage: _task__resolve_current_revision REPO TASK_PREFIX PROJECT_PREFIX
#
# Convenience wrapper around _task__resolve_current that returns only the commit ID
# (line 1 of _task__resolve_current's output). Prints the commit ID to stdout, or
# '@' if no bookmarks are found in the working copy ancestry.
_task__resolve_current_revision() {
  local resolve_output
  resolve_output="$(_task__resolve_current "$@")" || return $?
  printf '%s' "$resolve_output" | sed -n '1p'
}

# Usage: _task__resolve_current_file REPO TASK_PREFIX PROJECT_PREFIX
#
# Convenience wrapper around _task__resolve_current that returns only the task file path
# (line 2 of _task__resolve_current's output). Prints the path to stdout, or an empty
# string if the current branch is not a task or project branch.
_task__resolve_current_file() {
  local resolve_output
  resolve_output="$(_task__resolve_current "$@")" || return $?
  printf '%s' "$resolve_output" | sed -n '2p'
}

# Usage: _task__resolve_current_branch REPO TASK_PREFIX PROJECT_PREFIX
#
# Convenience wrapper around _task__resolve_current that returns only the bookmark name
# (line 3 of _task__resolve_current's output). Prints the bookmark name to stdout, or
# an empty string if no bookmark is found in the working copy ancestry.
_task__resolve_current_branch() {
  local resolve_output
  resolve_output="$(_task__resolve_current "$@")" || return $?
  printf '%s' "$resolve_output" | sed -n '3p'
}

# ---------------------------------------------------------------------------
# Descendant task helpers
# ---------------------------------------------------------------------------

# Usage: _task__collect_descendant_dirs REPO BRANCH TASK_ID TASK_PREFIX PROJECT_PREFIX
#
# Outputs one `.tt/task/<slug>` directory path per line for every task that
# is a descendant of TASK_ID (direct children, grandchildren, etc.), read
# from BRANCH.  Traversal follows `subtask:` frontmatter entries.
#
# Only task IDs whose prefix matches TASK_PREFIX or PROJECT_PREFIX are
# followed; unknown entries are skipped silently.
#
# Does not output the task's own directory (the caller already handles that).
_task__collect_descendant_dirs() {
  local repo="$1" branch="$2" task_id="$3" task_prefix="$4" project_prefix="$5"

  # BFS queue (bash array)
  local -a queue=("$task_id")
  local -a visited=("$task_id")

  while [[ ${#queue[@]} -gt 0 ]]; do
    local current="${queue[0]}"
    queue=("${queue[@]:1}")      # shift

    # Derive slug and read task file from branch
    local suffix
    if _task__check_is_task_branch "$current" "$task_prefix"; then
      suffix="${current#$task_prefix}"
    elif _task__check_is_project_branch "$current" "$project_prefix"; then
      suffix="${current#$project_prefix}"
    else
      continue
    fi

    local tf
    tf="$(_path__task_file "$suffix")"
    local content
    content="$(_repo__read_file_at_revision "$repo" "$branch" "$tf")" || continue

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
      if _task__check_is_task_branch "$subtask_id" "$task_prefix"; then
        sub_suffix="${subtask_id#$task_prefix}"
      elif _task__check_is_project_branch "$subtask_id" "$project_prefix"; then
        sub_suffix="${subtask_id#$project_prefix}"
      else
        continue
      fi
      _path__task_dir "$sub_suffix"
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

# _task__write_stub ROOT TASK_SUFFIX [TIMESTAMP]
#
# Writes a minimal task file stub at ROOT/.tt/task/<suffix>/TASK.md, where
# ROOT is any directory tree — typically a staging directory for a bare
# branch write; nothing outside ROOT is touched. Produces a placeholder
# title: "", status: TODO, and created/updated set to TIMESTAMP (default:
# now). Passing an explicit TIMESTAMP lets a caller write byte-identical
# stub copies across several commits. The placeholder title is overwritten
# by the subsequent `tt task edit` call during task creation.
_task__write_stub() {
  local root="$1"
  local suffix="$2"
  local ts="${3:-}"
  local dir
  dir="$(_path__task_dir "$suffix")"
  local file
  file="$(_path__task_file "$suffix")"
  if [[ -z "$ts" ]]; then
    ts="$(_string__generate_timestamp)"
  fi
  mkdir -p "$root/$dir"
  local REWRITE_LABELS=() REWRITE_CONTEXTS=() REWRITE_SUBTASKS=()
  _frontmatter__write_task_file "$root/$file" "" "TODO" "" "$ts" "$ts"
}
