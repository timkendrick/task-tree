# Common functions for tt bootstrap CLI scripts.
# Source this file; do not execute directly.

_TT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_TT_LIB_DIR/ui.sh"
. "$_TT_LIB_DIR/string.sh"
. "$_TT_LIB_DIR/format.sh"
. "$_TT_LIB_DIR/path.sh"
. "$_TT_LIB_DIR/frontmatter.sh"
. "$_TT_LIB_DIR/commit.sh"
. "$_TT_LIB_DIR/hook.sh"
. "$_TT_LIB_DIR/repo.sh"
. "$_TT_LIB_DIR/history.sh"
. "$_TT_LIB_DIR/workspace.sh"
. "$_TT_LIB_DIR/worktree.sh"

# Return true if bookmark name matches task ID pattern (<prefix><slug>-<hex>).
is_task_branch() {
  local bookmark="$1"
  local prefix="$2"
  [[ "$bookmark" == "$prefix"* ]] && [[ "$bookmark" =~ -[0-9a-fA-F]{8}$ ]]
}

# Return true if bookmark name matches project ID pattern (<prefix><slug>-<hex>).
is_project_branch() {
  local bookmark="$1"
  local prefix="$2"
  [[ "$bookmark" == "$prefix"* ]] && [[ "$bookmark" =~ -[0-9a-fA-F]{8}$ ]]
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
    _ui__log "Error: There are commits since the last checkpoint that are not tracked by the task bookmark."
    _ui__log "  Run 'tt task checkpoint' to record them before checking in."
    _ui__log "  Alternatively, pass the task ID explicitly to skip this check:"
    _ui__log "    tt task checkin ${bookmark}"
    exit 1
  fi
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

# Usage: get_task_range_context REPO [TASK_ID]
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
get_task_range_context() {
  local repo="$1" task_id_arg="${2:-}"

  local task_prefix project_prefix
  task_prefix="$(_workspace__get_task_prefix "$repo")"
  project_prefix="$(_workspace__get_project_prefix "$repo")"

  local task_bookmark upper_bound

  if [[ -z "$task_id_arg" ]]; then
    if ! task_bookmark="$(resolve_current_bookmark "$repo" "$task_prefix" "$project_prefix")"; then
      _ui__log "Error: Not on a task or project branch."
      return 1
    fi
    if [[ -z "$task_bookmark" ]]; then
      _ui__log "Error: Not on a task or project branch."
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
      _ui__log "Error: Bookmark '$task_bookmark' not found."
      return 1
    fi
  fi

  local parent_bookmark exit_code=0
  parent_bookmark="$(find_parent_branch "$repo" "$task_bookmark" "$task_prefix" "$project_prefix")" || exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    [[ $exit_code -eq 1 ]] && _ui__log "Error: No parent found for '$task_bookmark'."
    return $exit_code
  fi

  printf '%s\t%s\t%s' "$task_bookmark" "$parent_bookmark" "$upper_bound"
}

# Usage: resolve_task_range REPO [TASK_ID]
# Compatibility wrapper over get_task_range_context that outputs only the
# range endpoints: "<parent_bookmark> <upper_bound>".
# Exit codes match get_task_range_context.
resolve_task_range() {
  local repo="$1" task_id_arg="${2:-}"

  local context
  context="$(get_task_range_context "$repo" "$task_id_arg")" || return $?

  local task_bookmark parent_bookmark upper_bound
  IFS=$'\t' read -r task_bookmark parent_bookmark upper_bound <<< "$context"

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

# Usage: get_full_task_range_records REPO TASK_ID PARENT_BOOKMARK UPPER_BOUND
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
# '@'/'@-' rather than immutable commit IDs, matching resolve_task_range.
#
# Only supports task branches (not project branches).
# Exit 1: TASK_ID is not a task branch, or a required revision could not be
# resolved (error printed to stderr).
get_full_task_range_records() {
  local repo="$1" task_id="$2" parent_bookmark="$3" upper_bound="$4"

  local task_prefix project_prefix
  task_prefix="$(_workspace__get_task_prefix "$repo")"
  project_prefix="$(_workspace__get_project_prefix "$repo")"

  if ! is_task_branch "$task_id" "$task_prefix"; then
    _ui__log "Error: Full task range discovery requires a task branch (got '$task_id')."
    return 1
  fi

  local target_file parent_file
  target_file="$(_path__task_file "${task_id#"$task_prefix"}")"
  parent_file="$(_full_range_bookmark_task_file "$parent_bookmark" "$task_prefix" "$project_prefix")"
  if [[ -z "$parent_file" ]]; then
    _ui__log "Error: '$parent_bookmark' is not a task or project branch."
    return 1
  fi

  local target_commit parent_commit upper_commit
  target_commit="$(_full_range_resolve_commit "$repo" "$task_id")" || return 1
  parent_commit="$(_full_range_resolve_commit "$repo" "$parent_bookmark")" || return 1
  upper_commit="$(_full_range_resolve_commit "$repo" "$upper_bound")" || return 1

  local creation_boundary
  creation_boundary="$(_full_range_creation_boundary \
    "$repo" "$task_id" "$target_file" "$target_commit" "$parent_commit")" || return 1

  local bounded="${creation_boundary}:: & ::(${target_commit} | ${parent_commit})"

  # --- Read scalar waypoint fields for every commit that may participate in the
  # range: commit-id, ordered parent ids, timestamp, and whether it changed the
  # target task file. ---
  local -a wp_id=() wp_parents=() wp_ts=() wp_changed=()
  local commit_id parents ts changed
  while IFS=$'\t' read -r commit_id parents ts changed; do
    [[ -z "$commit_id" ]] && continue
    wp_id+=("$commit_id")
    wp_parents+=("$parents")
    wp_ts+=("$ts")
    wp_changed+=("$changed")
  done < <(_full_range_query_waypoints "$repo" "$bounded" "$target_file")

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
    symlink_diff="$(_full_range_symlink_diff "$repo" "${wp_id[$handoff_index]}")"
    removed="$(_full_range_parse_symlink_removed "$symlink_diff")"
    added="$(_full_range_parse_symlink_added "$symlink_diff")"
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

  # --- Current unmerged component, and the broad-component union used to drop
  # covered child/path candidates. ---
  local current_base="$parent_bookmark" current_tip="$upper_bound"
  local broad_union="(${parent_bookmark}..${upper_bound})"
  for ((i = 0; i < ${#comp_base[@]}; i++)); do
    if [[ "${comp_kind[$i]}" == "historical" ]]; then
      broad_union="${broad_union} | (${comp_base[$i]}..${comp_tip[$i]})"
    fi
  done

  local -a final_base=() final_tip=() final_kind=() final_order=() final_ts=()
  for ((i = 0; i < ${#comp_base[@]}; i++)); do
    _full_range_span_empty "$repo" "${comp_base[$i]}" "${comp_tip[$i]}" && continue
    if [[ "${comp_kind[$i]}" == "child" ]]; then
      _full_range_covered_by "$repo" "${comp_base[$i]}" "${comp_tip[$i]}" "$broad_union" && continue
    fi
    final_base+=("${comp_base[$i]}"); final_tip+=("${comp_tip[$i]}")
    final_kind+=("${comp_kind[$i]}"); final_order+=("${comp_order[$i]}"); final_ts+=("${comp_ts[$i]}")
  done
  for ((i = 0; i < ${#path_base[@]}; i++)); do
    _full_range_span_empty "$repo" "${path_base[$i]}" "${path_tip[$i]}" && continue
    _full_range_covered_by "$repo" "${path_base[$i]}" "${path_tip[$i]}" "$broad_union" && continue
    final_base+=("${path_base[$i]}"); final_tip+=("${path_tip[$i]}")
    final_kind+=("path"); final_order+=("${path_order[$i]}"); final_ts+=("${path_ts[$i]}")
  done

  # --- Order historical/child/path components by ancestry, then append the
  # current unmerged component last. ---
  if [[ ${#final_base[@]} -gt 0 ]]; then
    local order_ids=""
    for ((i = 0; i < ${#final_order[@]}; i++)); do
      if [[ -z "$order_ids" ]]; then order_ids="${final_order[$i]}"; else order_ids="${order_ids} | ${final_order[$i]}"; fi
    done
    local ordered order_commit
    ordered="$(jj -R "$repo" --ignore-working-copy log --no-graph --reversed \
      -r "(${bounded}) & (${order_ids})" -T 'commit_id ++ "\n"' 2>/dev/null)"
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

  if ! _full_range_span_empty "$repo" "$current_base" "$current_tip"; then
    local current_ts
    current_ts="$(jj -R "$repo" --ignore-working-copy log --no-graph -r "$upper_commit" \
      -T 'committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ")' 2>/dev/null)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$current_base" "$current_tip" "current" "$upper_commit" "$current_ts"
  fi
}

# Usage: _full_range_resolve_commit REPO REV
# Prints the immutable commit ID of REV. Exit 1 with an error if REV cannot be
# resolved.
_full_range_resolve_commit() {
  local repo="$1" rev="$2"
  local id
  id="$(jj -R "$repo" --ignore-working-copy log -r "$rev" --no-graph -T 'commit_id' 2>/dev/null)"
  if [[ -z "$id" ]]; then
    _ui__log "Error: Could not resolve revision '$rev'."
    return 1
  fi
  printf '%s' "$id"
}

# Usage: _full_range_bookmark_task_file BOOKMARK TASK_PREFIX PROJECT_PREFIX
# Prints the canonical task file path owned by BOOKMARK, or nothing if
# BOOKMARK is neither a task nor a project branch.
_full_range_bookmark_task_file() {
  local bookmark="$1" task_prefix="$2" project_prefix="$3"
  if is_task_branch "$bookmark" "$task_prefix"; then
    _path__task_file "${bookmark#"$task_prefix"}"
  elif is_project_branch "$bookmark" "$project_prefix"; then
    _path__task_file "${bookmark#"$project_prefix"}"
  fi
}

# Usage: _full_range_creation_boundary REPO TASK_ID TARGET_FILE TARGET_COMMIT PARENT_COMMIT
# Prints the immutable commit ID of the unique commit that created TARGET_FILE
# within the combined ancestry of TARGET_COMMIT and PARENT_COMMIT. Exit 1 with
# an error if no such commit, or more than one, is found.
_full_range_creation_boundary() {
  local repo="$1" task_id="$2" target_file="$3" target_commit="$4" parent_commit="$5"
  local matches
  matches="$(jj -R "$repo" --ignore-working-copy log --no-graph -r \
    "roots(files(root-file:\"${target_file}\") & ::(${target_commit} | ${parent_commit}))" \
    -T 'commit_id ++ "\n"' 2>/dev/null)" || true
  local count
  count="$(printf '%s' "$matches" | grep -c . || true)"
  if [[ "$count" -ne 1 ]]; then
    _ui__log "Error: Could not resolve a unique creation boundary for '$task_id'."
    return 1
  fi
  printf '%s' "$matches"
}

# Usage: _full_range_query_waypoints REPO BOUNDED_REVSET TARGET_FILE
# Prints one tab-separated line per commit, oldest first, for every commit
# within BOUNDED_REVSET that changes TARGET_FILE, changes the root TASK.md
# symlink, or is a merge with a parent that changes the root TASK.md symlink:
#   <commit-id>\t<parent-ids space-separated>\t<timestamp>\t<target-changed 0|1>
_full_range_query_waypoints() {
  local repo="$1" bounded="$2" target_file="$3"
  local target_changes="files(root-file:\"${target_file}\")"
  local symlink_changes="files(root-file:\"${TT_TASK_SYMLINK_FILENAME}\")"
  local merge_candidates="merges() & children(${symlink_changes})"
  jj -R "$repo" --ignore-working-copy log --no-graph --reversed \
    -r "(${bounded}) & (${target_changes} | ${symlink_changes} | ${merge_candidates})" \
    -T 'commit_id ++ "\t" ++ parents.map(|p| p.commit_id()).join(" ") ++ "\t" ++ committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ") ++ "\t" ++ if(self.diff("root-file:\"'"${target_file}"'\"").files().len() > 0, "1", "0") ++ "\n"' \
    2>/dev/null
}

# Usage: _full_range_symlink_diff REPO REV
# Prints the Git-format diff of the root TASK.md symlink at REV.
_full_range_symlink_diff() {
  local repo="$1" rev="$2"
  jj -R "$repo" --ignore-working-copy log --no-graph -r "$rev" \
    -T 'self.diff("root-file:\"'"${TT_TASK_SYMLINK_FILENAME}"'\"").git()' 2>/dev/null
}

# Usage: _full_range_parse_symlink_removed DIFF_TEXT
# Prints the removed symlink target from a Git-format TASK.md diff, or nothing.
_full_range_parse_symlink_removed() {
  printf '%s\n' "$1" | grep -E '^-[^-]' | head -1 | cut -c2-
}

# Usage: _full_range_parse_symlink_added DIFF_TEXT
# Prints the added symlink target from a Git-format TASK.md diff, or nothing.
_full_range_parse_symlink_added() {
  printf '%s\n' "$1" | grep -E '^\+[^+]' | head -1 | cut -c2-
}

# Usage: _full_range_span_empty REPO BASE TIP
# Returns 0 (true) if the revset "BASE..TIP" contains no commits.
_full_range_span_empty() {
  local repo="$1" base="$2" tip="$3"
  local count
  count="$(_repo__count_revisions "$repo" "${base}..${tip}")"
  [[ "$count" -eq 0 ]]
}

# Usage: _full_range_covered_by REPO BASE TIP BROAD_REVSET
# Returns 0 (true) if every commit in "BASE..TIP" is already in BROAD_REVSET.
_full_range_covered_by() {
  local repo="$1" base="$2" tip="$3" broad="$4"
  local count
  count="$(_repo__count_revisions "$repo" "(${base}..${tip}) ~ (${broad})")"
  [[ "$count" -eq 0 ]]
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
    path="$(_path__task_file "$suffix")"
    local c
    c="$(_repo__read_file_at_revision "$repo" "$branch" "$path")" || continue
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
# caller *before* _history__begin_transaction, since resolution can trigger a jj snapshot.
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
      _ui__log "Error: Could not resolve current branch: $current_branch"
      exit 1
    fi
    if is_task_branch "$current_branch" "$task_prefix"; then
      printf '%s\n%s\n%s\n' "$parent_rev" "$(_path__task_file "${current_branch#$task_prefix}")" "$current_branch"
    elif is_project_branch "$current_branch" "$project_prefix"; then
      printf '%s\n%s\n%s\n' "$parent_rev" "$(_path__task_file "${current_branch#$project_prefix}")" "$current_branch"
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
      if is_task_branch "$subtask_id" "$task_prefix"; then
        sub_suffix="${subtask_id#$task_prefix}"
      elif is_project_branch "$subtask_id" "$project_prefix"; then
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
  dir="$(_path__task_dir "$suffix")"
  local file
  file="$(_path__task_file "$suffix")"
  local ts
  ts="$(_string__generate_timestamp)"
  mkdir -p "$repo/$dir"
  local REWRITE_LABELS=() REWRITE_CONTEXTS=() REWRITE_SUBTASKS=()
  _frontmatter__write_task_file "$repo/$file" "" "TODO" "" "$ts" "$ts"
  _ui__log "Created task file: $file"
}
