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
        _ui__log "Error: No enclosing jj repository. Use --repo or set TT_REPO."
        exit 1
      fi
    fi
  fi

  if [[ ! -d "$repo/.jj" ]]; then
    _ui__log "Error: Not a jj repository: $repo"
    exit 1
  fi

  # Canonicalize to match jj's own path representation (e.g. /var → /private/var on macOS)
  repo="$(_path__resolve_symlinks "$repo")"
  printf '%s' "$repo"
}

# Read task_prefix from .tt/config.toml; default "task/" if missing or unreadable.
get_task_prefix() {
  local repo="$1"
  local config="$repo/$(_path__metadata 'config.toml')"
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
  local config="$repo/$(_path__metadata 'config.toml')"
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
  _path__make_absolute_symlink "$virtual_dir" "$repo/$(_path__metadata 'workspace')"
}

# Usage: init_tt_history REPO
# Creates an empty .tt/history file in REPO if it does not already exist.
# The history file is gitignored (via .tt/.gitignore) and used by the
# transaction system to record before/after jj operation IDs for `tt history undo`.
init_tt_history() {
  local repo="$1"
  local history_file="$repo/$(_path__metadata 'history')"
  if [[ ! -f "$history_file" ]]; then
    touch "$history_file"
  fi
}

# Read workspace dir from .tt/workspace symlink; returns 1 if not configured.
# Always resolves to an absolute path to prevent symlink loops.
get_workspace_dir() {
  local repo="$1"
  local symlink="$repo/$(_path__metadata 'workspace')"
  if [[ -L "$symlink" ]]; then
    local ws_dir
    ws_dir="$(readlink "$symlink")"
    if [[ -n "$ws_dir" ]]; then
      # Resolve relative targets against the symlink's parent directory,
      # then canonicalise to strip OS-level symlinks (e.g. /var -> /private/var).
      if [[ "$ws_dir" != /* ]]; then
        ws_dir="$(_path__resolve_symlinks "$(cd "$(dirname "$symlink")" && cd "$ws_dir" && pwd)")"
      else
        ws_dir="$(_path__resolve_symlinks "$ws_dir")"
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
    _ui__log "Error: There are commits since the last checkpoint that are not tracked by the task bookmark."
    _ui__log "  Run 'tt task checkpoint' to record them before checking in."
    _ui__log "  Alternatively, pass the task ID explicitly to skip this check:"
    _ui__log "    tt task checkin ${bookmark}"
    exit 1
  fi
}

# Usage: update_head_symlink WORKSPACE_DIR TARGET_PATH
# Updates <workspace-dir>/HEAD to point at TARGET_PATH using an absolute path
# to prevent symlink loops.
update_head_symlink() {
  local workspace_dir="$1" target_path="$2"
  [[ -z "$workspace_dir" ]] && return 0
  [[ ! -d "$workspace_dir" ]] && return 0
  local head_path="$workspace_dir/HEAD"
  _path__make_absolute_symlink "$target_path" "$head_path"
  _ui__log "Updated HEAD -> $target_path"
}

# Usage: perform_workspace_switch REPO WORKSPACE_DIR TASK_ID TARGET_WORKTREE OUTGOING_WORKTREE PREVIOUS_TASK_ID
# Fires pre-checkout hook, updates HEAD symlink, fires post-checkout hook.
perform_workspace_switch() {
  local repo="$1" workspace_dir="$2" task_id="$3"
  local target_worktree="$4" outgoing_worktree="$5" previous_task_id="$6"

  _ui__log "Switching to $task_id"

  _hook__run "$repo" "pre-checkout" true "$outgoing_worktree" "${workspace_dir:-}" \
    "TT_TASK_ID=$task_id" \
    "TT_TASK_BRANCH=$task_id" \
    "TT_PREVIOUS_TASK_ID=${previous_task_id}" \
    "TT_PREVIOUS_TASK_BRANCH=${previous_task_id}"

  update_head_symlink "$workspace_dir" "$target_worktree"

  _hook__run "$repo" "post-checkout" false "$target_worktree" "${workspace_dir:-}" \
    "TT_TASK_ID=$task_id" \
    "TT_TASK_BRANCH=$task_id" \
    "TT_PREVIOUS_TASK_ID=${previous_task_id}" \
    "TT_PREVIOUS_TASK_BRANCH=${previous_task_id}"
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
    path="$(_path__task_file "$suffix")"
    local content
    content="$(jj_show_at_revision "$repo" "$branch" "$path")" || continue
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
  task_prefix="$(get_task_prefix "$repo")"
  project_prefix="$(get_project_prefix "$repo")"

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
  task_prefix="$(get_task_prefix "$repo")"
  project_prefix="$(get_project_prefix "$repo")"

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
  count="$(count_revs_in_revset "$repo" "${base}..${tip}")"
  [[ "$count" -eq 0 ]]
}

# Usage: _full_range_covered_by REPO BASE TIP BROAD_REVSET
# Returns 0 (true) if every commit in "BASE..TIP" is already in BROAD_REVSET.
_full_range_covered_by() {
  local repo="$1" base="$2" tip="$3" broad="$4"
  local count
  count="$(count_revs_in_revset "$repo" "(${base}..${tip}) ~ (${broad})")"
  [[ "$count" -eq 0 ]]
}

# Usage: mainline_commit_records REPO TIP BASE
#
# Outputs one record per commit on TIP's first-parent mainline that is not an
# ancestor of BASE, oldest first. Records are tab-separated:
#   <commit-id>\t<change-id>\t<timestamp>\t<parent-ids>\t<description-first-line>
#
# <parent-ids> is a space-separated list of full commit IDs; a merge commit lists
# the branch it was created on first and the branch merged into it second.
# <timestamp> is the committer timestamp in ISO 8601 UTC. The description comes
# last so a tab inside a commit message cannot displace the structured fields.
#
# Following first parents only excludes commits that arrived through a merge:
# those belong to the branch that was merged in, not to TIP's own mainline.
#
# Returns jj's exit code; nothing is printed if the revset cannot be resolved.
mainline_commit_records() {
  local repo="$1" tip="$2" base="$3"
  jj -R "$repo" --ignore-working-copy log \
    -r "first_ancestors($tip) ~ ::$base" --no-graph --reversed \
    -T 'commit_id ++ "\t" ++ change_id ++ "\t" ++ committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ") ++ "\t" ++ parents.map(|p| p.commit_id()).join(" ") ++ "\t" ++ description.first_line() ++ "\n"' \
    2>/dev/null
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
      _ui__log "Error: Multiple workspaces found for '$bookmark'; use --worktree=<path>:"
      printf '%s\n' "$found" | while IFS= read -r p; do _ui__log "  $p"; done
      return 1
      ;;
  esac
}

# Usage: jj_workspace_list REPO
# Prints one line per jj workspace in REPO, formatted as "name: /absolute/path",
# or "name: <Error: ...>" when the workspace has no resolvable path.
# Parse each line with parse_workspace_list_line.
jj_workspace_list() {
  local repo="$1"
  jj -R "$repo" --ignore-working-copy workspace list --no-pager \
    -T 'name ++ ": " ++ root ++ "\n"' 2>/dev/null
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

# Usage: list_worktree_entries REPO
# Prints one tab-separated "name<TAB>path" record per jj workspace in REPO.
# path is the empty string when the workspace has no resolvable path.
# Returns 1 if the workspace list cannot be read.
list_worktree_entries() {
  local repo="$1"
  local ws_raw
  ws_raw="$(jj_workspace_list "$repo")" || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local parsed
    parsed="$(parse_workspace_list_line "$line")"
    printf '%s\t%s\n' \
      "$(printf '%s' "$parsed" | sed -n '1p')" \
      "$(printf '%s' "$parsed" | sed -n '2p')"
  done <<< "$ws_raw"
}

# Usage: find_worktrees_for_branch REPO BOOKMARK TASK_PREFIX PROJECT_PREFIX
# Outputs one workspace root path per line for each jj workspace where
# BOOKMARK is the current branch (resolved via resolve_current).
find_worktrees_for_branch() {
  local repo="$1" bookmark="$2" task_prefix="$3" project_prefix="$4"
  local entries
  entries="$(list_worktree_entries "$repo")" || return 0
  local ws_root ws_bookmark
  while IFS=$'\t' read -r _ ws_root; do
    [[ -z "$ws_root" || ! -d "$ws_root" ]] && continue
    ws_bookmark="$(resolve_current_bookmark "$ws_root" "$task_prefix" "$project_prefix" 2>/dev/null)" || continue
    [[ "$ws_bookmark" == "$bookmark" ]] && printf '%s\n' "$ws_root"
  done <<< "$entries"
  return 0
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

# Usage: resolve_workspace_name REPO WORKTREE_PATH
# Prints the jj workspace name for the workspace at WORKTREE_PATH.
# Returns 0 and prints name if found, returns 1 if not found.
resolve_workspace_name() {
  local repo="$1" worktree_path="$2"
  local entries
  entries="$(list_worktree_entries "$repo")" || return 1
  local name path
  while IFS=$'\t' read -r name path; do
    [[ "$path" == "$worktree_path" ]] || continue
    printf '%s' "$name"
    return 0
  done <<< "$entries"
  return 1
}

# Usage: resolve_workspace_path REPO WS_NAME
# Prints the recorded filesystem path of the jj workspace named WS_NAME.
# Prints an empty string if the workspace has no recorded path.
# Returns 0 if found, 1 if no workspace bears that name.
resolve_workspace_path() {
  local repo="$1" ws_name="$2"
  local entries
  entries="$(list_worktree_entries "$repo")" || return 1
  local name path
  while IFS=$'\t' read -r name path; do
    [[ "$name" == "$ws_name" ]] || continue
    printf '%s' "$path"
    return 0
  done <<< "$entries"
  return 1
}

# Usage: list_workspaces REPO TASK_PREFIX PROJECT_PREFIX
# Prints tab-separated workspace data, one line per workspace:
#   name\tpath\ttask_id
# path is empty string if unavailable; task_id is empty string if unresolved.
list_workspaces() {
  local repo="$1" task_prefix="$2" project_prefix="$3"
  local entries
  entries="$(list_worktree_entries "$repo")" || return 0
  local ws_name ws_path task_id
  while IFS=$'\t' read -r ws_name ws_path; do
    [[ -z "$ws_name" ]] && continue

    task_id=''
    if [[ -n "$ws_path" && -d "$ws_path" ]]; then
      task_id="$(resolve_current_bookmark "$ws_path" "$task_prefix" "$project_prefix" 2>/dev/null)" || true
    fi

    printf '%s\t%s\t%s\n' "$ws_name" "$ws_path" "$task_id"
  done <<< "$entries"
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
  resolved="$(_path__resolve_symlinks "$head_target")"
  printf '%s' "$resolved"
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
      || { _ui__log "Error: Could not resolve canonical repo from $repo_entry"; return 1; }
    # target = /path/to/canonical/.jj/repo — strip /.jj/repo to get repo root
    dirname "$(dirname "$target")"
  else
    # Canonical repo: .jj/repo is a directory (the actual op store)
    printf '%s' "$repo"
  fi
}

# Usage: resolve_canonical_repo_path REPO
# Prints the symlink-resolved path of the canonical repository root for REPO.
# REPO may be any workspace, including a dedicated worktree whose own .jj points
# at the canonical repo. Use when the result is compared against another
# canonicalized path, so that a symlinked root (e.g. /var -> /private/var on
# macOS) does not defeat the comparison.
# Returns 1 if the canonical root cannot be resolved.
resolve_canonical_repo_path() {
  local repo="$1"
  local canonical_repo
  canonical_repo="$(resolve_canonical_repo "$repo")" || return 1
  _path__resolve_symlinks "$canonical_repo" 2>/dev/null
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
  printf '%s/%s' "$canonical_repo" "$(_path__metadata 'history')"
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
    _ui__log "Error: Could not read jj operation ID to begin transaction"
    exit 1
  }

  # Check for in-progress transaction (last line has empty after-op-id)
  if [[ -f "$history_file" && -s "$history_file" ]]; then
    local last_line
    last_line="$(tail -n 1 "$history_file" 2>/dev/null)" || true
    if [[ -n "$last_line" ]]; then
      local last_after="${last_line#*:}"
      if [[ -z "$last_after" ]]; then
        _ui__log "Error: Another tt command is in progress (incomplete transaction)."
        _ui__log "  To revert a crashed process: tt history undo --force"
        _ui__log "  Or to keep the current state: tt history unlock --force"
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
    _ui__log "Warning: Could not derive canonical repo from history file path; history may be incomplete"
    canonical_repo="$repo"
  }

  # Capture current jj operation ID
  local after_op
  after_op="$(get_jj_op_id "$canonical_repo")" || {
    _ui__log "Warning: Could not read jj operation ID for transaction commit; history may be incomplete"
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

  _ui__log "Rolling back transaction (restoring jj operation: ${before_op:0:12}...)"

  # Restore jj to before-op state.
  # Use a subshell to cd into the canonical repo first, so jj can resolve CWD
  # even when the caller's working directory has been deleted (e.g. after
  # worktree delete).
  (cd "$canonical_repo" && jj -R "$canonical_repo" op restore "$before_op" 2>/dev/null) || \
    _ui__log "Warning: Could not restore jj operation state; manual recovery may be needed"

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

