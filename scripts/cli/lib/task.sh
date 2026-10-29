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
#   _task__check_revision_exists     — arbitrary revision expression resolves
#   _task__list_branch_names         — every bookmark name in the repository
#   _task__resolve_revision          — immutable commit ID of a revision
#   _task__resolve_change            — stable change ID of a revision
#   _task__delete_branch             — delete a task/project bookmark
#   _task__rename_branch             — rename a task/project bookmark
#   _task__read_file                 — read a repo file as recorded on a branch
#   _task__resolve_suffix            — slug-hex suffix of a task ID
#   _task__resolve_file              — repo-relative task file path of a task ID
#   _task__read_fields               — frontmatter fields of a task at a revision
#   _task__read_status               — status of a task at a revision
#   _task__read_title                — decoded title of a task at a revision
#   _task__parse_subtask_entry       — checkbox and subtask ID of a raw subtask entry
#   _task__resolve_context_file      — repo-relative path of a task's context file
#   _task__read_context_fields       — frontmatter fields of a context file at a revision
#   _task__format_context            — render a context file with its context ID
#   _task__check_file_exists         — whether a task's file exists at a revision
#   _task__check_path_exists         — whether a repo-relative path exists at a revision
#   _task__read_commit_message       — description recorded on a commit
#   _task__list_commits_since_branch — commits on a branch's line since its tip
#   _task__list_mainline_commits     — first-parent commit records of a range
#   _task__filter_reachable_commits  — commits of a set that a revision can reach
#   _task__read_symlink              — read a symlink target as recorded on a branch
#   _task__list_files                — files recorded at a revision, under a prefix
#   _task__format_range              — render a revision range in a named format
#   _task__show_diff                 — Git-format diff of a range, minus exclusions
#   _task__find_parent_branch        — parent branch listing a task as a subtask
#   _task__find_parent_project       — nearest ancestor project branch
#   _task__find_branch               — canonical branch for a task ("where to read" rule)
#   _task__get_range_context         — task id + parent bookmark + upper bound
#   _task__resolve_range             — parent bookmark + upper bound only
#   _task__resolve_fork_point        — fork point commit between parent and upper bound
#   _task__get_full_range_records    — every commit component attributable to a task
#   _task__resolve_current           — task-file/bookmark of the task checked out here
#   _task__resolve_current_branch    — bookmark name of the task checked out here
#   _task__find_for_revision         — task/project branch recorded by a revision
#   _task__collect_descendant_dirs   — task dirs for all descendants of a task
#   _task__write_stub                — minimal task file stub for a new task
#   _task__write_file                — write a new task file
#   _task__write_context_file        — write a new context file
#   _task__write_symlink             — repo-root task symlink pointing at a task file
#   _task__set_subtask_status        — set a subtask entry's checkbox in a staged task file
#   _task__set_field                 — set a single-valued field of a staged task file
#   _task__set_labels                — replace the label entries of a staged task file
#   _task__set_subtasks              — replace the subtask entries of a staged task file
#   _task__add_subtask               — add a subtask entry to a staged task file
#   _task__remove_subtask            — remove a subtask entry from a staged task file
#   _task__rename_subtask            — repoint a subtask entry at a new task ID
#   _task__add_context               — add a context entry to a staged task file
#   _task__remove_context            — remove a context entry from a staged task file
#   _task__commit_on_branch          — staged bare write committed onto a bookmark
#   _task__commit_fork               — fork commit pointing the task symlink at a task
#   _task__start_branch              — point a new (or re-created) bookmark at a commit
#   _task__commit_handoff            — staged bare write on a branch tip, bookmark unmoved
#   _task__commit_detached           — staged bare write reachable only by its own ID
#   _task__merge_branch              — check-in merge commit (branch tip + handoff)
#   _task__check_conflicts           — whether a revision has merge conflicts
#   _task__check_descendant_conflicts — whether a revision or its descendants conflict
#   _task__check_range_conflicts     — whether a task's unmerged range carries conflicts
#   _task__advance_branch            — move a branch bookmark forward to a revision
#   _task__list_unmerged_changes     — paths changed by a branch's unmerged range
#   _task__list_unmerged_roots       — attachment points of a task's unmerged range
#   _task__list_unmerged_root_parents — commits a task's unmerged range hangs off
#   _task__move_unmerged_range       — reparent a task's unmerged range
#   _task__restore_symlink           — set a commit's task symlink from another commit
#   _task__check_up_to_date          — whether a task already sits on a base revision
#   _task__find_directory_introduction — commit that first added a task directory
#   _task__list_rewrite_range        — change IDs of a commit and its descendants
#   _task__replace_tree              — set a commit's tree wholesale from another
#   _task__discard_commit            — abandon a commit built as scratch state
#
# The _task__full_range_* helpers are internal to _task__get_full_range_records,
# __task__commit_staged is the private staging engine shared by the staged
# commit builders (_task__commit_on_branch, _task__commit_fork,
# _task__commit_handoff and _task__commit_detached).

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

# Usage: _task__check_revision_exists REPO REV
# Returns 0 when REV names something that resolves in REPO, non-zero otherwise.
# Unlike _task__check_branch_exists this makes no claim about REV being a
# bookmark: it is the check for a revision a user supplied (a `--since`
# argument, say), which may equally be a commit ID or any other expression the
# VCS understands. Documented pass-through to _repo__check_revision_exists.
_task__check_revision_exists() {
  local repo="$1" rev="$2"
  _repo__check_revision_exists "$repo" "$rev"
}

# Usage: _task__list_branch_names REPO
# Prints every bookmark name in REPO, one per line, unsorted and unfiltered —
# task branches, project branches and any other bookmark alike. Callers filter
# to the ones they care about with _task__check_is_task_branch /
# _task__check_is_project_branch. Documented pass-through to
# _repo__list_bookmark_names so commands can enumerate the task tree's branches
# without reaching into the VCS layer.
_task__list_branch_names() {
  local repo="$1"
  _repo__list_bookmark_names "$repo"
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

# Usage: _task__resolve_change REPO REV
# Prints the stable change ID of REV. Returns non-zero with nothing printed
# when REV does not resolve. Change IDs survive a rewrite of the commit they
# name, so commands that rewrite several commits in one pass must hold their
# working set as change IDs rather than commit IDs. Documented pass-through to
# _repo__resolve_change.
_task__resolve_change() {
  local repo="$1" rev="$2"
  local change
  change="$(_repo__resolve_change "$repo" "$rev")" || return 1
  [[ -n "$change" ]] || return 1
  printf '%s' "$change"
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

# Usage: _task__resolve_suffix TASK_ID TASK_PREFIX PROJECT_PREFIX
# Prints the slug-hex suffix of TASK_ID, a task or project ID: the part that
# names its task directory. Returns 1 (nothing printed) when TASK_ID is
# neither. Performs no VCS access.
_task__resolve_suffix() {
  local task_id="$1" task_prefix="$2" project_prefix="$3"
  if _task__check_is_task_branch "$task_id" "$task_prefix"; then
    printf '%s' "${task_id#"$task_prefix"}"
  elif _task__check_is_project_branch "$task_id" "$project_prefix"; then
    printf '%s' "${task_id#"$project_prefix"}"
  else
    return 1
  fi
}

# Usage: _task__resolve_file TASK_ID TASK_PREFIX PROJECT_PREFIX
# Prints the repo-relative task file path of TASK_ID, a task or project ID.
# Returns 1 (nothing printed) when TASK_ID is neither. Performs no VCS access.
_task__resolve_file() {
  local suffix
  suffix="$(_task__resolve_suffix "$1" "$2" "$3")" || return 1
  _path__task_file "$suffix"
}

# Usage: _task__read_fields REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX FIELD...
# Prints the frontmatter FIELDs of TASK_ID's task file as recorded at REV, in
# argument order. A repeatable field (label, context, subtask) must be
# requested as a list, with a '[]' suffix; a single-valued field must not be:
#   title, status, created, updated
#       one line holding the decoded value (empty when absent).
#   label[], context[], subtask[]
#       a line holding the entry count, then one line per raw entry in file
#       order.
#   ...
#       the body, verbatim, to the end of the output (last request only).
# See _frontmatter__parse_values for the unpacking pattern. Reads the file
# once, whatever the number of fields.
# Returns 1 (nothing printed) when a FIELD is unknown or requested in the
# wrong form (an error is logged), when TASK_ID is not a task or project ID, or
# when the task file cannot be read at REV.
_task__read_fields() {
  local repo="$1" rev="$2" task_id="$3" task_prefix="$4" project_prefix="$5"
  shift 5
  __task__check_document_requests 'title status created updated' 'label context subtask' \
    "$@" || return 1
  local task_file
  task_file="$(_task__resolve_file "$task_id" "$task_prefix" "$project_prefix")" || return 1
  __task__read_document_fields "$repo" "$rev" "$task_file" "$@"
}

# Usage: _task__check_path_exists REPO REV PATH
# Returns 0 when the repo-relative PATH is recorded at REV, non-zero otherwise.
# Documented pass-through to _repo__check_file_exists_at_revision for paths
# that are not named by a task ID, such as a task file at a path a rename is
# moving away from.
_task__check_path_exists() {
  _repo__check_file_exists_at_revision "$1" "$2" "$3"
}

# Usage: _task__resolve_context_file TASK_ID CTX_ID TASK_PREFIX PROJECT_PREFIX
# Prints the repo-relative path of context CTX_ID of TASK_ID, a task or project
# ID. Returns 1 (nothing printed) when TASK_ID is neither. Performs no VCS
# access.
_task__resolve_context_file() {
  local suffix
  suffix="$(_task__resolve_suffix "$1" "$3" "$4")" || return 1
  _path__task_context "$suffix" "$2"
}

# Usage: _task__read_context_fields REPO REV TASK_ID CTX_ID TASK_PREFIX PROJECT_PREFIX FIELD...
# As _task__read_fields, for context CTX_ID of TASK_ID. A context file has the
# single-valued fields title, created and updated, no repeatable fields, and a
# body ('...').
_task__read_context_fields() {
  local repo="$1" rev="$2" task_id="$3" ctx_id="$4" task_prefix="$5" project_prefix="$6"
  shift 6
  __task__check_document_requests 'title created updated' '' "$@" || return 1
  local ctx_file
  ctx_file="$(_task__resolve_context_file "$task_id" "$ctx_id" \
    "$task_prefix" "$project_prefix")" || return 1
  __task__read_document_fields "$repo" "$rev" "$ctx_file" "$@"
}

# Usage: _task__format_context REPO REV TASK_ID CTX_ID TASK_PREFIX PROJECT_PREFIX
# Prints context CTX_ID of TASK_ID as recorded at REV: a frontmatter block
# naming the context ID, followed by its title, created and updated fields
# (each omitted when empty), then the body with leading and trailing blank
# lines and trailing whitespace removed, then a blank line. Returns 1 (nothing
# printed) when the context file cannot be read at REV.
_task__format_context() {
  local repo="$1" rev="$2" task_id="$3" ctx_id="$4" task_prefix="$5" project_prefix="$6"
  local fields title='' created='' updated='' body=''
  fields="$(_task__read_context_fields "$repo" "$rev" "$task_id" "$ctx_id" \
    "$task_prefix" "$project_prefix" title created updated '...')" || return 1
  { IFS= read -r title; IFS= read -r created; IFS= read -r updated
    IFS= read -r -d '' body
  } <<< "$fields" || true
  body="${body%$'\n'}"

  local -a pairs=(context "$ctx_id")
  [[ -n "$title" ]] && pairs+=(title "$(_frontmatter__quote "$title")")
  [[ -n "$created" ]] && pairs+=(created "$created")
  [[ -n "$updated" ]] && pairs+=(updated "$updated")
  _frontmatter__format_block "${pairs[@]}"
  body="$(_string__trim_text "$body")"
  [[ -n "$body" ]] && printf '%s\n' "$body"
  printf '\n'
}

# Usage: __task__check_document_requests SINGLE_FIELDS LIST_FIELDS FIELD...
# Checks each FIELD request against a document schema: SINGLE_FIELDS and
# LIST_FIELDS are space-separated field names. A single-valued field is
# requested by name, a repeatable field as 'NAME[]', and the body as '...'.
# Logs an error and returns 1 for the first request that does not fit.
__task__check_document_requests() {
  local single=" $1 " list=" $2 "
  shift 2
  local field
  for field in "$@"; do
    if [[ "$field" == '...' ]]; then
      continue
    elif [[ "$field" == *'[]' ]]; then
      [[ "$list" == *" ${field%\[\]} "* ]] && continue
      if [[ "$single" == *" ${field%\[\]} "* ]]; then
        printf "Error: Single-valued field '%s' cannot be requested as a list.\n" \
          "${field%\[\]}" >&2
        return 1
      fi
    else
      [[ "$single" == *" $field "* ]] && continue
      if [[ "$list" == *" $field "* ]]; then
        printf "Error: Repeatable field '%s' must be requested as '%s[]'.\n" \
          "$field" "$field" >&2
        return 1
      fi
    fi
    printf "Error: Unknown field '%s'.\n" "$field" >&2
    return 1
  done
}

# Usage: __task__read_document_fields REPO REV PATH FIELD...
# Reads the document at PATH as recorded at REV once, and prints its FIELDs
# (_frontmatter__parse_values). Returns 1 (nothing printed) when the file
# cannot be read at REV.
__task__read_document_fields() {
  local repo="$1" rev="$2" path="$3"
  shift 3
  local content
  content="$(_task__read_file "$repo" "$rev" "$path" 2>/dev/null)" || return 1
  _frontmatter__parse_values "$content" "$@"
}

# Usage: _task__read_status REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX
# Prints the status of TASK_ID's task file at REV. Fails as _task__read_fields.
_task__read_status() {
  _task__read_fields "$1" "$2" "$3" "$4" "$5" status
}

# Usage: _task__read_title REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX
# Prints the decoded title of TASK_ID's task file at REV. Fails as
# _task__read_fields.
_task__read_title() {
  _task__read_fields "$1" "$2" "$3" "$4" "$5" title
}

# Usage: _task__check_file_exists REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX
# Returns 0 when TASK_ID's task file exists at REV. Returns 1 when TASK_ID is
# not a task or project ID, or the file does not exist there. Prints nothing.
_task__check_file_exists() {
  local repo="$1" rev="$2" task_id="$3" task_prefix="$4" project_prefix="$5"
  local task_file
  task_file="$(_task__resolve_file "$task_id" "$task_prefix" "$project_prefix")" || return 1
  _repo__check_file_exists_at_revision "$repo" "$rev" "$task_file" 2>/dev/null
}

# Usage: _task__read_commit_message REPO REV
# Prints the full description recorded on REV (empty when it has none).
# Documented pass-through to _repo__get_commit_description so commands can reuse
# the wording of an existing commit — e.g. to prefill a checkpoint message
# editor — without reaching into the VCS layer.
_task__read_commit_message() {
  local repo="$1" rev="$2"
  _repo__get_commit_description "$repo" "$rev"
}

# Usage: _task__list_commits_since_branch REPO BRANCH TIP
# Prints the commit IDs, one per line and oldest first, of the commits that
# descend from BRANCH's tip and are ancestors of TIP, with BRANCH's own tip
# excluded — the work recorded on the branch's line of descent since its
# bookmark last moved. Nothing is printed (status 0) when there is no such
# commit or the range does not resolve.
#
# The descent condition is what distinguishes this from the plain BRANCH..TIP
# range: a commit that reached TIP through a merge from another line is an
# ancestor of TIP without descending from the branch tip, and it is not work
# that belongs to this branch's own line. Documented pass-through to
# _repo__list_commits_in_dag_range.
_task__list_commits_since_branch() {
  local repo="$1" branch="$2" tip="$3"
  _repo__list_commits_in_dag_range "$repo" "$branch" "$tip"
}

# Usage: _task__list_mainline_commits REPO TIP BASE
# Prints one tab-separated record per commit on TIP's own line of descent that
# BASE does not already reach, oldest first:
#   <commit-id>\t<change-id>\t<timestamp>\t<parent-ids>\t<description-first-line>
# <parent-ids> is space-separated; on a check-in merge the branch that was
# merged into comes first and the handoff commit merged in comes second.
#
# Commits that arrived through a merge are excluded: they belong to the branch
# that was merged in, so a report about TIP names the merge itself rather than
# repeating everything the merge brought along. Documented pass-through to
# _repo__list_mainline_commits.
_task__list_mainline_commits() {
  local repo="$1" tip="$2" base="$3"
  _repo__list_mainline_commits "$repo" "$tip" "$base"
}

# Usage: _task__filter_reachable_commits REPO REV COMMIT [COMMIT ...]
# Prints those of the given COMMITs that REV can already reach (its ancestors,
# REV itself included), one per line and in no guaranteed order. Nothing is
# printed (status 0) when no COMMIT is given or none is reachable.
#
# Commands use this to apply a "since" boundary to a set of commits gathered
# from several ranges: whatever the boundary revision already reaches is work
# the report should leave out. Documented pass-through to
# _repo__filter_commits_reachable_from.
_task__filter_reachable_commits() {
  local repo="$1" rev="$2"
  shift 2
  _repo__filter_commits_reachable_from "$repo" "$rev" "$@"
}

# Usage: _task__rename_branch REPO OLD_BRANCH NEW_BRANCH
# Renames the OLD_BRANCH bookmark to NEW_BRANCH, leaving it on the same
# revision. Documented pass-through to _repo__rename_bookmark so commands can
# re-identify a task or project branch without reaching into the VCS layer.
_task__rename_branch() {
  local repo="$1" old_branch="$2" new_branch="$3"
  _repo__rename_bookmark "$repo" "$old_branch" "$new_branch"
}

# Usage: _task__read_symlink REPO REV PATH
# Prints the target of the symlink recorded at the repo-root-relative PATH at
# REV, without a trailing newline. Returns non-zero (nothing printed) when
# PATH is absent at REV or is not recorded as a symlink. The task model stores
# the repo-root task pointer as a symlink into a task directory, so reading its
# target is how a command learns which task a revision points at. Documented
# pass-through to _repo__read_symlink_at_revision.
_task__read_symlink() {
  local repo="$1" rev="$2" path="$3"
  _repo__read_symlink_at_revision "$repo" "$rev" "$path"
}

# Usage: _task__list_files REPO REV [PREFIX]
# Prints the repo-root-relative paths recorded at REV, one per line,
# optionally limited to those at or beneath PREFIX (a file or directory path).
# Nothing is printed (status 0) when the prefix matches no files. Documented
# pass-through to _repo__list_files_at_revision so commands can enumerate a task
# directory's contents as of a given commit without reaching into the VCS layer.
_task__list_files() {
  local repo="$1" rev="$2" prefix="${3:-}"
  _repo__list_files_at_revision "$repo" "$rev" "$prefix"
}

# Usage: _task__format_range REPO FORMAT FROM TO
# Prints the FROM..TO revision range rendered in FORMAT, followed by a newline:
#   'native' — the backend's own range expression over FROM and TO as given, so
#              symbolic endpoints (a bookmark name, '@-') survive into the output
#   'git'    — an immutable Git commit-ID range, both endpoints resolved
# Returns non-zero when FORMAT is unknown or an endpoint of a 'git' range does
# not resolve.
#
# Keeping both forms behind one call means the range syntax of each is owned by
# the VCS layer rather than spelled out by whichever command is printing it.
# Documented pass-through to _repo__format_revision_range.
_task__format_range() {
  local repo="$1" format="$2" from="$3" to="$4"
  _repo__format_revision_range "$repo" "$format" "$from" "$to"
}

# Usage: _task__show_diff REPO FROM TO [EXCLUDE_KIND EXCLUDE_PATH ...]
# Writes the diff between FROM and TO to stdout in Git diff format, which is
# stable and readily parsed by other tools. Each trailing EXCLUDE_KIND /
# EXCLUDE_PATH pair (kinds 'dir' and 'file', as emitted by
# _path__metadata_exclusions) drops one repo-root-relative path from the diff;
# with no pairs the whole range is shown.
#
# The exclusions are passed as plain records so the path-matching syntax stays
# inside the VCS layer. Documented pass-through to _repo__show_diff.
_task__show_diff() {
  local repo="$1" from="$2" to="$3"
  shift 3
  _repo__show_diff "$repo" "$from" "$to" "$@"
}

# Usage: __task__list_subtasks REPO REV TASK_ID TASK_PREFIX PROJECT_PREFIX
# Prints one "CHECKBOX<TAB>SUBTASK_ID" line per well-formed subtask entry of
# TASK_ID's task file at REV, in file order. CHECKBOX is "[ ]", "[-]" or "[x]";
# any title after the subtask ID is dropped. Returns 1 (nothing printed) when
# the task file cannot be read.
__task__list_subtasks() {
  local fields
  fields="$(_task__read_fields "$1" "$2" "$3" "$4" "$5" 'subtask[]')" || return 1
  local subtask_count subtask i
  { IFS= read -r subtask_count
    for (( i = 0; i < subtask_count; i++ )); do
      IFS= read -r subtask
      [[ "$subtask" =~ $__TASK__SUBTASK_ENTRY ]] || continue
      printf '[%s]\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    done
  } <<< "$fields" || true
}

# The shape of a raw 'subtask:' entry: a checkbox, then the subtask ID, then
# anything else (such as a title). Group 1 is the checkbox state, group 2 the ID.
__TASK__SUBTASK_ENTRY='^\[([ x-])\][[:space:]]*([^[:space:]]+)'

# Usage: _task__parse_subtask_entry ENTRY
# Prints "CHECKBOX<TAB>SUBTASK_ID" for a raw 'subtask:' entry value, as read
# with _task__read_fields ... 'subtask[]'. Returns 1 (nothing printed) when
# ENTRY has no well-formed checkbox and ID. Performs no VCS access.
_task__parse_subtask_entry() {
  [[ "$1" =~ $__TASK__SUBTASK_ENTRY ]] || return 1
  printf '[%s]\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# Usage: __task__check_lists_subtask SUBTASKS TASK_ID [CHECKBOX]
# Returns 0 when SUBTASKS (the output of __task__list_subtasks) contains
# TASK_ID, with CHECKBOX when it is given.
__task__check_lists_subtask() {
  local subtasks="$1" task_id="$2" want="${3:-}"
  local checkbox id
  while IFS=$'\t' read -r checkbox id; do
    [[ "$id" == "$task_id" ]] || continue
    [[ -z "$want" || "$checkbox" == "$want" ]] && return 0
  done <<< "$subtasks"
  return 1
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
    [[ "$branch" == "$task_id" ]] && continue
    local subtasks
    subtasks="$(__task__list_subtasks "$repo" "$branch" "$branch" \
      "$task_prefix" "$project_prefix")" || continue
    if __task__check_lists_subtask "$subtasks" "$task_id"; then
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

    # If the WC commit is empty, the range should only extend as far as the parent of the WC commit.
    if _worktree__check_clean "$repo"; then
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
  target_file="$(_task__resolve_file "$task_id" "$task_prefix" "$project_prefix")"
  if ! parent_file="$(_task__resolve_file "$parent_bookmark" "$task_prefix" "$project_prefix")"; then
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
  local line
  while IFS= read -r line; do
    if [[ "$line" == -* && "$line" != --* ]]; then
      printf '%s\n' "${line#-}"
      return 0
    fi
  done <<< "$1"
}

# Usage: _task__full_range_parse_symlink_added DIFF_TEXT
# Prints the added symlink target from a Git-format TASK.md diff, or nothing.
_task__full_range_parse_symlink_added() {
  local line
  while IFS= read -r line; do
    if [[ "$line" == +* && "$line" != ++* ]]; then
      printf '%s\n' "${line#+}"
      return 0
    fi
  done <<< "$1"
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
    local subtasks
    subtasks="$(__task__list_subtasks "$repo" "$branch" "$branch" \
      "$task_prefix" "$project_prefix")" || continue
    if __task__check_lists_subtask "$subtasks" "$task_id" '[x]'; then
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
#          [--copy-from REV PATH]... [--move-prefix OLD NEW]...
#          -- WRITER_FN [ARGS...]
#
# Commits a staged set of file writes and deletions onto BRANCH without
# touching any working copy: builds the change as a bare commit on top of the
# branch tip (_repo__commit_changeset), reattaches the current worktree when it
# is checked out on BRANCH and sat on the old tip (_worktree__reattach_current),
# advances the BRANCH bookmark to it, and prints the new commit ID. A worktree
# on any other branch stays where it is, even when BRANCH is an ancestor of
# its own branch.
#
# The inputs are ORTHOGONAL:
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
#   --copy-from      places PATH (a file, or a directory with everything
#                    beneath it) exactly as recorded at REV, reusing the
#                    recorded content and modes; PATH absent at REV is an
#                    ERROR.
#   --move-prefix    relocates the exact files under OLD at the tip to the
#                    same relative paths under NEW, as recorded (a prefix
#                    matching no files contributes nothing).
# Copied and moved files are not materialized into the staging directory; a
# staged file at the same path replaces them. Removals apply first, then
# copies and moves, then the staging directory.
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
  _worktree__reattach_current "$repo" "$branch" "$tip" "$new_commit" || return 1
  _repo__set_bookmark "$repo" "$branch" "$new_commit" || return 1
  printf '%s\n' "$new_commit"
}

# Usage: _task__commit_fork REPO TASK_ID BASE_REV TITLE [-- WRITER_FN [ARGS...]]
#
# Builds the fork commit of TASK_ID: a bare commit on top of BASE_REV that
# points the repo-root task symlink at TASK_ID's task file
# (_task__write_symlink), described as `[tt:task:<task-id>:fork] <title>`.
# Prints the new commit ID.
#
# The fork commit is where a task's own line begins: every commit above it on
# that line records the task as the one it belongs to, until a check-in
# handoff points the symlink back at the parent. Callers decide where the
# commit lands, so nothing else happens here: no bookmark is created or moved
# and no worktree is reattached. A new task branch starts on it
# (_task__start_branch); a branch resuming above its parent's tip advances
# onto it.
#
# TITLE is passed in rather than read from the task file, because a task's
# title is not always recorded at BASE_REV yet: at creation, the stub there
# still carries a placeholder title.
#
# The optional WRITER_FN stages further files into the same commit (the
# staging contract of _task__commit_on_branch, without the modify/delete
# flags). The symlink is staged after WRITER_FN runs. A non-zero WRITER_FN
# status aborts the call and nothing is committed.
#
# Exit 0: commit created (ID printed to stdout).
# Exit non-zero: TASK_ID is neither a task nor a project ID, unresolvable
# BASE_REV, writer failure, or a failed VCS step (error printed to stderr).
_task__commit_fork() {
  local repo="$1" task_id="$2" base_rev="$3" title="$4"
  shift 4

  local -a writer=()
  if [[ $# -gt 0 ]]; then
    if [[ "$1" != '--' || $# -lt 2 ]]; then
      _ui__log "Error: A fork commit takes an optional '-- WRITER_FN [ARGS...]'."
      return 1
    fi
    shift
    writer=("$@")
  fi

  local task_prefix project_prefix suffix
  task_prefix="$(_workspace__get_task_prefix "$repo")"
  project_prefix="$(_workspace__get_project_prefix "$repo")"
  suffix="$(_task__resolve_suffix "$task_id" "$task_prefix" "$project_prefix")" || {
    _ui__log "Error: '$task_id' is not a recognized task or project ID."
    return 1
  }

  # A full commit ID is already resolved; the bare commit verifies it names a
  # commit in the store.
  local base_commit
  if _repo__check_is_canonical_commit_id "$base_rev"; then
    base_commit="$base_rev"
  else
    base_commit="$(_repo__resolve_commit "$repo" "$base_rev")" || base_commit=''
  fi
  if [[ -z "$base_commit" ]]; then
    _ui__log "Error: Could not resolve revision '$base_rev'."
    return 1
  fi

  local new_commit
  new_commit="$(__task__commit_staged "$repo" "$base_commit" \
    "$(_commit__format_message "task" "fork" "$task_id" "$title")" \
    -- __task__write_fork "$suffix" "${writer[@]+"${writer[@]}"}")" || return 1
  [[ -n "$new_commit" ]] || return 1
  printf '%s\n' "$new_commit"
}

# Usage: __task__write_fork ROOT TASK_SUFFIX [WRITER_FN [ARGS...]]
# Staged-commit writer for _task__commit_fork: runs the caller's WRITER_FN
# (if any) with ROOT, then stages the task symlink for TASK_SUFFIX.
__task__write_fork() {
  local root="$1" suffix="$2"
  shift 2
  if [[ $# -gt 0 ]]; then
    local writer_fn="$1"
    shift
    "$writer_fn" "$root" "$@" || return 1
  fi
  _task__write_symlink "$root" "$suffix"
}

# Usage: _task__start_branch REPO BRANCH REV [--allow-backwards]
#
# Points the BRANCH bookmark at REV, creating the bookmark when it does not
# exist. This is the second half of starting a task branch: the caller first
# builds the branch's first commit as a bare commit (_task__commit_fork,
# _task__commit_detached), then starts the branch on it. No working copy is
# touched, no worktree is reattached, and no out-of-sync report is produced:
# a branch that did not exist before the call has no worktrees sitting on it.
#
# --allow-backwards lets an existing BRANCH bookmark move even when REV is
# not a descendant of its current position (forced branch re-creation).
#
# Exit 0: bookmark set. Exit non-zero: the bookmark update failed.
_task__start_branch() {
  local repo="$1" branch="$2" rev="$3"
  shift 3
  local -a bookmark_flags=()
  if [[ "${1:-}" == '--allow-backwards' ]]; then
    bookmark_flags=(--allow-backwards)
    shift
  fi
  if [[ $# -gt 0 ]]; then
    _ui__log "Error: Unknown start-branch flag: $1"
    return 1
  fi
  _repo__set_bookmark "$repo" "$branch" "$rev" \
    "${bookmark_flags[@]+"${bookmark_flags[@]}"}"
}

# Usage: _task__commit_handoff REPO BRANCH MESSAGE
#          [--modify PATH]... [--delete PATH]... [--delete-prefix PREFIX]...
#          [--copy-from REV PATH]... [--move-prefix OLD NEW]...
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

# Usage: _task__commit_detached REPO BASE_REV MESSAGE
#          [--modify PATH]... [--delete PATH]... [--delete-prefix PREFIX]...
#          [--copy-from REV PATH]... [--move-prefix OLD NEW]...
#          -- WRITER_FN [ARGS...]
#
# Builds a staged bare commit on top of BASE_REV (the same flag and writer
# contract as _task__commit_on_branch) and prints its commit ID. Nothing else
# happens: no bookmark is created or moved, no worktree is reattached, and no
# branch learns about the commit. The result is reachable only through the ID
# returned, which is what makes it usable as scratch state — a tree computed
# ahead of time and parked in the repository until whichever commit needs it
# is rewritten to carry it. The caller owns the commit's lifetime and is
# responsible for abandoning it (_task__discard_commit) once it has been used.
#
# A non-zero WRITER_FN status aborts the call: nothing is committed.
#
# Exit 0: commit created (ID printed to stdout).
# Exit non-zero: bad arguments, unresolvable BASE_REV, absent --modify path,
# writer failure, or a failed VCS step (error printed to stderr).
_task__commit_detached() {
  local repo="$1" base_rev="$2" message="$3"
  shift 3

  local base_commit
  base_commit="$(_repo__resolve_commit "$repo" "$base_rev")" || base_commit=''
  if [[ -z "$base_commit" ]]; then
    _ui__log "Error: Could not resolve revision '$base_rev'."
    return 1
  fi

  local new_commit
  new_commit="$(__task__commit_staged "$repo" "$base_commit" "$message" "$@")" || return 1
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
# The parent order is semantic, not cosmetic. A branch's own line is its
# first-parent mainline, and two mechanisms read the graph that way: full-range
# discovery (_task__get_full_range_records) classifies historical check-ins by
# the shape of a merge's second parent, and mainline listing
# (_repo__list_mainline_commits) reports a branch's own work by following first
# parents. The receiving branch must therefore always be first and the incoming
# line second, whichever of the two is being merged into which.
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

# Usage: _task__check_descendant_conflicts REPO REV
# Returns 0 when REV, or any commit descended from it, carries merge
# conflicts. Used after a range has been reparented: the rebase replays the
# range's commits one by one, so a conflict can surface anywhere above the
# revision the caller named, not just on it. Documented pass-through to
# _repo__check_descendants_have_conflicts.
_task__check_descendant_conflicts() {
  local repo="$1" rev="$2"
  _repo__check_descendants_have_conflicts "$repo" "$rev"
}

# Usage: _task__check_range_conflicts REPO PARENT_BRANCH CHILD_BRANCH
# Returns 0 when any commit of CHILD_BRANCH's unmerged range — everything in
# CHILD_BRANCH's ancestry that PARENT_BRANCH does not already have — carries
# merge conflicts. A check-in merges that whole range into the parent rather
# than only the child's tip, so a conflict anywhere in it would land in the
# parent's history even when the tip itself resolves cleanly. Documented
# pass-through to _repo__check_range_has_conflicts.
_task__check_range_conflicts() {
  local repo="$1" parent="$2" child="$3"
  _repo__check_range_has_conflicts "$repo" "$parent" "$child"
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
# The range is diffed as one unit, so content the child merely inherited from
# the parent at its fork point is never reported, and the range's own roots
# are excluded: the first unmerged commit is the branch's fork commit (its
# task symlink and stub), which is never what a caller needs to inspect. This
# is deliberately a path listing rather than a content diff: its consumer
# (checkin's stray-task-file validation) needs to know WHICH task files the
# range touches, not what changed inside them.
#
# Returns non-zero (nothing printed) when the range cannot be diffed.
_task__list_unmerged_changes() {
  local repo="$1" parent_branch="$2" child_branch="$3" prefix="${4:-}"

  local changed
  changed="$(_repo__list_changed_files_in_range "$repo" \
    "$parent_branch" "$child_branch")" || return 1

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

# Usage: _task__list_unmerged_roots REPO BASE_REV TASK_REV
#
# Prints the commit IDs (one per line, oldest first) of the ROOTS of
# TASK_REV's unmerged range: the commits reachable from TASK_REV but not from
# BASE_REV that have no parent inside that same set. These are the points at
# which the task's own line of work hangs off history it inherited, so moving
# them moves the whole task.
#
# Nothing is printed when the task has no commits of its own relative to
# BASE_REV — which is also the test for "is this range empty at all", since a
# non-empty range always has at least one root.
#
# Documented pass-through to _repo__list_range_root_commits; returns its status.
_task__list_unmerged_roots() {
  local repo="$1" base_rev="$2" task_rev="$3"
  _repo__list_range_root_commits "$repo" "$base_rev" "$task_rev"
}

# Usage: _task__list_unmerged_root_parents REPO BASE_REV TASK_REV
#
# Prints the commit IDs (one per line) of the parents of the roots of
# TASK_REV's unmerged range relative to BASE_REV (_task__list_unmerged_roots).
# These commits are outside the range: they are where the task's own line of
# work hangs off history it shares with BASE_REV, so they are always in
# BASE_REV's ancestry. Reading what they record tells a caller what the range
# inherited before it moves.
#
# Nothing is printed when the range is empty.
#
# Documented pass-through to _repo__list_range_root_parent_commits; returns its
# status.
_task__list_unmerged_root_parents() {
  local repo="$1" base_rev="$2" task_rev="$3"
  _repo__list_range_root_parent_commits "$repo" "$base_rev" "$task_rev"
}

# Usage: _task__move_unmerged_range REPO BASE_REV TASK_REV DEST_REV
#
# Reparents a task's line of work: rebases every root of TASK_REV's unmerged
# range relative to BASE_REV (_task__list_unmerged_roots), together with all of
# their descendants, onto DEST_REV. Commits the task merely inherited from
# BASE_REV stay where they are; bookmarks pointing into the moved range follow
# it, so the task branch ends up on top of DEST_REV.
#
# Returns 0 without doing anything when the range is empty. Nothing is printed
# in any case.
#
# Roots whose subtree does NOT contain the current working-copy commit are
# moved as a bare graph rewrite (_repo__move_commits), which touches no working
# copy at all. A root the working copy sits above is moved through the current
# worktree instead (_worktree__move_subtree) so the on-disk files travel with
# the commits rather than being left behind. Bare roots are moved first so the
# carried subtree is rewritten last, against a graph that is otherwise final.
_task__move_unmerged_range() {
  local repo="$1" base_rev="$2" task_rev="$3" dest_rev="$4"

  local roots
  roots="$(_task__list_unmerged_roots "$repo" "$base_rev" "$task_rev")" || roots=''
  [[ -n "$roots" ]] || return 0

  local worktree wc_commit=''
  worktree="$(_repo__resolve_worktree_root "$repo")" || worktree=''
  if [[ -n "$worktree" ]]; then
    wc_commit="$(_repo__resolve_commit "$worktree" '@')" || wc_commit=''
  fi

  local -a bare_roots=() carried_roots=()
  local root
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    if [[ -n "$wc_commit" ]] && _repo__check_is_ancestor "$repo" "$root" "$wc_commit"; then
      carried_roots+=("$root")
    else
      bare_roots+=("$root")
    fi
  done <<< "$roots"

  if [[ ${#bare_roots[@]} -gt 0 ]]; then
    _repo__move_commits "$repo" "$dest_rev" "${bare_roots[@]}" || return 1
  fi
  for root in "${carried_roots[@]+"${carried_roots[@]}"}"; do
    _worktree__move_subtree "$repo" "$root" "$dest_rev" || return 1
  done
  return 0
}

# Usage: _task__restore_symlink REPO SOURCE_REV TARGET_REV
#
# Sets the repo-root task symlink in TARGET_REV to its state in SOURCE_REV,
# keeping the rest of TARGET_REV's tree and its identity. A conflict on the
# symlink in TARGET_REV is replaced by SOURCE_REV's state, and descendants
# that do not change the symlink inherit it. Nothing is rewritten when the
# symlink already matches.
#
# Used after a task's unmerged range moves onto a different base: the moved
# commits must keep pointing the symlink at their own task, rather than at
# whichever task the new base records. Rewrites TARGET_REV, so its commit ID
# changes; callers hold it by change ID. Touches no working copy, so a
# worktree sitting above TARGET_REV must be refreshed afterwards
# (_worktree__refresh_current). Documented pass-through to _repo__restore_path.
_task__restore_symlink() {
  local repo="$1" source_rev="$2" target_rev="$3"
  _repo__restore_path "$repo" "$source_rev" "$target_rev" "$TT_TASK_SYMLINK_FILENAME"
}

# Usage: _task__check_up_to_date REPO BASE_REV TASK_REV
#
# Returns 0 when TASK_REV has nothing left to receive from BASE_REV, either
# because it has no commits of its own outside BASE_REV's ancestry (all of its
# work has already been absorbed there), or because every root of its unmerged
# range already sits directly on BASE_REV — the shape left behind by an
# earlier reparenting onto this same revision.
#
# "Sits directly on BASE_REV" is tested as: BASE_REV is an ancestor of the
# root AND the range between them holds nothing but the root itself. For a
# range root the two conditions together are exactly "BASE_REV is one of my
# parents" — a root cannot have a parent inside its own range, so any other
# parent it has must already be in BASE_REV's ancestry.
_task__check_up_to_date() {
  local repo="$1" base_rev="$2" task_rev="$3"

  local roots
  roots="$(_task__list_unmerged_roots "$repo" "$base_rev" "$task_rev")" || roots=''
  [[ -n "$roots" ]] || return 0

  local root count
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    _repo__check_is_ancestor "$repo" "$base_rev" "$root" || return 1
    count="$(_repo__count_commits_in_range "$repo" "$base_rev" "$root")"
    [[ "$count" -eq 1 ]] || return 1
  done <<< "$roots"
  return 0
}

# ---------------------------------------------------------------------------
# Whole-history rewrites
#
# A few task operations change something that is recorded in every commit
# carrying it — the location of a task's directory, say — rather than
# appending a new commit that supersedes it. Such an operation has to rewrite
# a whole region of history in place, and these are the primitives it works
# with: find where the thing first appeared, enumerate the region that has to
# change, and replace the tree of each commit in it.
# ---------------------------------------------------------------------------

# Usage: _task__find_directory_introduction REPO TASK_DIR
#
# Prints the commit ID of the commit that first added TASK_DIR (a repo-root-
# relative task directory) anywhere in the repository's visible history. Every
# commit that carries the directory descends from it, so it is the anchor for
# a rewrite that has to reach all of them — including branches that forked
# from the introducing commit's line after the directory appeared.
#
# Returns 1 (nothing printed) when no single commit introduced the directory:
# the caller owns the error message. That happens when the directory was added
# on two lines independently, in which case no one commit anchors the rewrite.
#
# Documented pass-through to _repo__find_prefix_introduction.
_task__find_directory_introduction() {
  local repo="$1" task_dir="$2"
  _repo__find_prefix_introduction "$repo" "$task_dir"
}

# Usage: _task__list_rewrite_range REPO BASE_REV
#
# Prints the change IDs of BASE_REV and every visible commit descended from
# it, one per line, oldest first: the region an in-place rewrite anchored at
# BASE_REV has to cover. Change IDs, not commit IDs, because rewriting one
# commit of the region rebases everything above it and invalidates their
# commit IDs, while their change IDs are stable.
#
# Documented pass-through to _repo__list_descendant_changes.
_task__list_rewrite_range() {
  local repo="$1" base_rev="$2"
  _repo__list_descendant_changes "$repo" "$base_rev"
}

# Usage: _task__replace_tree REPO SOURCE_REV TARGET_REV
#
# Replaces TARGET_REV's tree wholesale with SOURCE_REV's, keeping TARGET_REV's
# own identity: its change ID, description and author all survive, so a rewrite
# built out of these calls leaves the shape of history untouched and changes
# only what each commit records. Descendants of TARGET_REV are rebased with
# their CONTENT preserved rather than their diffs replayed, so a rewrite that
# visits every commit of a region in turn never re-derives a tree it is about
# to set explicitly, and no three-way merge — hence no conflict — is involved.
#
# Documented pass-through to _repo__restore_tree; touches no working copy, so a
# worktree sitting on a rewritten commit must be refreshed afterwards
# (_worktree__refresh_current).
_task__replace_tree() {
  local repo="$1" source_rev="$2" target_rev="$3"
  _repo__restore_tree "$repo" "$source_rev" "$target_rev"
}

# Usage: _task__discard_commit REPO REV
#
# Abandons REV, rebasing any descendants onto its parents. Used to retire the
# scratch commits a whole-history rewrite parks in the repository
# (_task__commit_detached): dropping the refs that made them reachable is not
# enough on its own, because an unreferenced commit stays a visible head until
# it is abandoned. Documented pass-through to _repo__abandon_commit.
_task__discard_commit() {
  local repo="$1" rev="$2"
  _repo__abandon_commit "$repo" "$rev"
}

# Usage: __task__commit_staged REPO TIP MESSAGE
#          [--modify PATH]... [--delete PATH]... [--delete-prefix PREFIX]...
#          [--copy-from REV PATH]... [--move-prefix OLD NEW]...
#          -- WRITER_FN [ARGS...]
#
# Private staging engine shared by the staged commit builders: materializes each --modify path from TIP into a
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

  local -a modify_paths=() delete_paths=() delete_prefixes=() copies=()
  local -a move_olds=() move_news=()
  local saw_separator=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --copy-from|--move-prefix)
        if [[ $# -lt 3 ]]; then
          _ui__log "Error: $1 requires two arguments."
          return 1
        fi
        if [[ "$1" == --copy-from ]]; then
          copies+=(--copy "$2" "$3" "$3")
        else
          move_olds+=("$2")
          move_news+=("$3")
        fi
        shift 3
        ;;
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
  # directory on every path without leaking the trap into the caller. The
  # variables the trap reads are deliberately not `local`: an explicit exit
  # from inside a function unwinds its locals before the trap runs, and the
  # subshell already confines them.
  (
    # A private staging directory named from this process and the shell's
    # generator.
    stage="${TMPDIR:-/tmp}/tt-stage-$$-$RANDOM$RANDOM"
    trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage" || exit 1

    local modify_path
    for modify_path in "${modify_paths[@]+"${modify_paths[@]}"}"; do
      mkdir -p "$stage/$(_path__dirname "$modify_path")" || exit 1
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

    local m
    for (( m = 0; m < ${#move_olds[@]}; m++ )); do
      expanded="$(_repo__list_files_at_revision "$repo" "$tip" "${move_olds[m]}")" \
        || expanded=''
      [[ -n "$expanded" ]] || continue
      copies+=(--copy "$tip" "${move_olds[m]}" "${move_news[m]}")
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
      ${copies[@]+"${copies[@]}"} "${deletions[@]+"${deletions[@]}"}")" || {
      [[ ${#copies[@]} -gt 0 ]] && _ui__log "Error: Could not commit onto '$tip'; check that every copied path exists."
      exit 1
    }
    [[ -n "$new_commit" ]] || exit 1
    printf '%s\n' "$new_commit"
  )
}

# Usage: _task__resolve_current REPO TASK_PREFIX PROJECT_PREFIX
#
# Resolve the task REPO has checked out — the branch its working copy records,
# read from the task symlink the branch's fork commit planted there
# (_worktree__resolve_branch_at). REPO is whichever worktree the command is
# operating on, so each worktree answers for itself.
#
# Outputs two lines to stdout:
#   line 1: task_file — path to .tt/task/<slug>-<hex>/TASK.md, or empty if no task
#   line 2: bookmark  — task or project bookmark name, or empty if no task
#
# Both lines are empty when the working copy records no task, or records one
# whose branch no longer exists: the worktree is then on no branch at all. That
# is a successful answer, not a failure — callers that need a task report the
# absence themselves.
_task__resolve_current() {
  local repo="$1"
  local task_prefix="$2"
  local project_prefix="$3"

  local branch
  branch="$(_worktree__resolve_branch_at "$repo" '@')" || branch=''

  local task_file
  if task_file="$(_task__resolve_file "$branch" "$task_prefix" "$project_prefix")"; then
    printf '%s\n%s\n' "$task_file" "$branch"
  else
    printf '\n\n'
  fi
}

# Usage: _task__resolve_current_branch REPO TASK_PREFIX PROJECT_PREFIX
#
# Convenience wrapper around _task__resolve_current that returns only the bookmark name
# (line 2 of _task__resolve_current's output). Prints the bookmark name to stdout, or
# an empty string when the worktree records no task.
_task__resolve_current_branch() {
  local resolve_output
  resolve_output="$(_task__resolve_current "$@")" || return $?
  local _file line=''
  { read -r _file; read -r line; } <<< "$resolve_output" || true
  printf '%s' "$line"
}

# Usage: _task__find_for_revision REPO REV
#
# Prints the task or project branch that REV belongs to: the task named by the
# task symlink recorded in REV (_worktree__resolve_branch_at), the same record
# that makes a task current in a worktree. Returns 1 (nothing printed) when REV
# does not resolve to exactly one commit, records no task symlink, or records a
# task whose branch no longer exists.
_task__find_for_revision() {
  local repo="$1" rev="$2"
  local commit
  commit="$(_repo__resolve_single_commit "$repo" "$rev")" || return 1
  [[ -n "$commit" ]] || return 1
  _worktree__resolve_branch_at "$repo" "$commit"
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

    local subtasks
    subtasks="$(__task__list_subtasks "$repo" "$branch" "$current" \
      "$task_prefix" "$project_prefix")" || continue

    # Follow every subtask (any checkbox state)
    local _checkbox subtask_id
    while IFS=$'\t' read -r _checkbox subtask_id; do
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
      sub_suffix="$(_task__resolve_suffix "$subtask_id" "$task_prefix" "$project_prefix")" || continue
      _path__task_dir "$sub_suffix"
      printf '\n'

      # Enqueue for further traversal
      queue+=("$subtask_id")
    done <<< "$subtasks"
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
  _task__write_file "$root/$file" "" "TODO" "$ts" "$ts" ""
}

# Usage: _task__write_file FILE TITLE STATUS CREATED UPDATED BODY [LABEL...]
# Writes a new task file FILE (typically in a staging directory): a
# frontmatter block with the quoted TITLE, STATUS, CREATED, UPDATED and one
# 'label:' entry per LABEL, in canonical order, followed by BODY (omitted when
# empty). A new task has no context or subtask entries yet; they are added
# with _task__add_context and _task__add_subtask.
_task__write_file() {
  local file="$1" title="$2" status="$3" created="$4" updated="$5" body="$6"
  shift 6
  local -a pairs=(title "$(_frontmatter__quote "$title")" status "$status"
    created "$created" updated "$updated")
  local label
  for label in "$@"; do pairs+=(label "$label"); done
  __task__write_document "$file" "$body" "${pairs[@]}"
}

# Usage: _task__write_context_file FILE TITLE CREATED UPDATED BODY
# Writes a new context file FILE (typically in a staging directory): a
# frontmatter block with the quoted TITLE, CREATED and UPDATED, followed by
# BODY (omitted when empty).
_task__write_context_file() {
  __task__write_document "$1" "$5" \
    title "$(_frontmatter__quote "$2")" created "$3" updated "$4"
}

# Usage: __task__write_document FILE BODY [KEY VALUE]...
# Writes FILE as a frontmatter block of the raw KEY VALUE pairs
# (_frontmatter__format_block) followed by BODY and a newline, or by nothing
# when BODY is empty.
__task__write_document() {
  local file="$1" body="$2"
  shift 2
  {
    _frontmatter__format_block "$@"
    [[ -z "$body" ]] || printf '%s\n' "$body"
  } > "$file"
}

# _task__write_symlink ROOT TASK_SUFFIX
#
# Writes the repo-root task symlink at ROOT/TASK.md, pointing at the task file
# of TASK_SUFFIX (.tt/task/<suffix>/TASK.md, relative to the repository root).
# ROOT is any directory tree, typically a staging directory for a bare branch
# write; an existing entry at ROOT/TASK.md is replaced.
_task__write_symlink() {
  local root="$1" suffix="$2"
  ln -snf "$(_path__task_file "$suffix")" "$root/$TT_TASK_SYMLINK_FILENAME"
}

# Usage: __task__staged_subtask_entries FILE
# Prints every raw 'subtask:' entry value of the task file FILE, one per line,
# in file order.
__task__staged_subtask_entries() {
  local fields subtask_count subtask i
  fields="$(_frontmatter__parse_values "$(<"$1")" 'subtask[]')"
  { IFS= read -r subtask_count
    for (( i = 0; i < subtask_count; i++ )); do
      IFS= read -r subtask; printf '%s\n' "$subtask"
    done
  } <<< "$fields" || true
}

# A raw 'subtask:' entry split into its checkbox (group 1), the whitespace after
# it (group 2), the subtask ID (group 3) and the rest of the entry (group 4).
__TASK__SUBTASK_ENTRY_PARTS='^(\[[ x-]\])([[:space:]]*)([^[:space:]]+)(.*)$'

# Usage: _task__set_subtask_status FILE TASK_ID STATUS
# Sets the checkbox of every 'subtask:' entry for TASK_ID in the task file FILE
# (typically a staged copy) to the one for STATUS (TODO, IN-PROGRESS or DONE),
# in place. Anything after the task ID on the entry, such as a title, is kept.
# Entries without a well-formed checkbox are left alone. Leaves the file
# unchanged when no entry matches. Logs an error and returns 1, leaving the
# file unchanged, when STATUS is not a known status.
_task__set_subtask_status() {
  local file="$1" task_id="$2" status="$3"
  case "$status" in
    TODO|IN-PROGRESS|DONE) ;;
    *)
      printf "Error: Unknown task status '%s'.\n" "$status" >&2
      return 1 ;;
  esac
  local checkbox subtask entries
  checkbox="$(_format__status_checkbox "$status")"
  entries="$(__task__staged_subtask_entries "$file")"
  while IFS= read -r subtask; do
    [[ "$subtask" =~ $__TASK__SUBTASK_ENTRY_PARTS ]] || continue
    [[ "${BASH_REMATCH[3]}" == "$task_id" ]] || continue
    _frontmatter__replace_entry "$file" subtask "$subtask" \
      "${checkbox}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
  done <<< "$entries"
}

# Usage: _task__add_subtask FILE TASK_ID
# Adds an unchecked 'subtask: [ ] TASK_ID' entry to the task file FILE
# (typically a staged copy), in place, after the existing subtask entries.
_task__add_subtask() {
  _frontmatter__add_entry --before "$(__task__fields_after subtask)" "$1" subtask "[ ] $2"
}

# Usage: _task__remove_subtask FILE TASK_ID
# Removes every 'subtask:' entry for TASK_ID, in any checkbox state and with
# or without a trailing title, from the task file FILE (typically a staged
# copy), in place. Leaves the file unchanged when no entry matches.
_task__remove_subtask() {
  local file="$1" task_id="$2"
  local subtask entries
  entries="$(__task__staged_subtask_entries "$file")"
  while IFS= read -r subtask; do
    [[ "$subtask" =~ $__TASK__SUBTASK_ENTRY_PARTS ]] || continue
    [[ "${BASH_REMATCH[3]}" == "$task_id" ]] || continue
    _frontmatter__remove_entry "$file" subtask "$subtask"
  done <<< "$entries"
}

# Usage: _task__rename_subtask FILE OLD_ID NEW_ID
# Repoints every 'subtask:' entry for OLD_ID in the task file FILE (typically
# a staged copy) at NEW_ID, in place. The checkbox, anything after the ID and
# the entry's position are kept. Leaves the file unchanged when no entry
# matches.
_task__rename_subtask() {
  local file="$1" old_id="$2" new_id="$3"
  local subtask entries
  entries="$(__task__staged_subtask_entries "$file")"
  while IFS= read -r subtask; do
    [[ "$subtask" =~ $__TASK__SUBTASK_ENTRY_PARTS ]] || continue
    [[ "${BASH_REMATCH[3]}" == "$old_id" ]] || continue
    _frontmatter__replace_entry "$file" subtask "$subtask" \
      "${BASH_REMATCH[1]}${BASH_REMATCH[2]}${new_id}${BASH_REMATCH[4]}"
  done <<< "$entries"
}

# Usage: _task__add_context FILE CTX_ID
# Adds a 'context: CTX_ID' entry to the task file FILE (typically a staged
# copy), in place, after the existing context entries and before any subtasks.
_task__add_context() {
  _frontmatter__add_entry --before "$(__task__fields_after context)" "$1" context "$2"
}

# The canonical order of task file frontmatter fields (DESIGN.md §4.2).
__TASK__FIELD_ORDER='title status created updated label context subtask'

# Usage: __task__fields_after FIELD
# Prints the task fields that follow FIELD in the canonical order, space-separated.
__task__fields_after() {
  local rest=" ${__TASK__FIELD_ORDER} "
  rest="${rest#* "$1" }"
  printf '%s' "${rest% }"
}

# Usage: _task__set_field FILE FIELD VALUE
# Sets the single-valued field FIELD (title, status, created or updated) of
# the task file FILE (typically a staged copy) to the raw VALUE, in place. An
# absent field is inserted at its canonical position. A title must be encoded
# by the caller (_frontmatter__quote).
_task__set_field() {
  _frontmatter__set_field --before "$(__task__fields_after "$2")" "$1" "$2" "$3"
}

# Usage: _task__set_labels FILE [LABEL...]
# Replaces the 'label:' entries of the task file FILE (typically a staged copy)
# with LABELs, in argument order, in place. When the task has no labels yet,
# they are inserted at their canonical position.
_task__set_labels() {
  local file="$1"
  shift
  _frontmatter__set_entries --before "$(__task__fields_after label)" "$file" label "$@"
}

# Usage: _task__set_subtasks FILE [ENTRY...]
# Replaces the 'subtask:' entries of the task file FILE (typically a staged
# copy) with the raw ENTRYs, in argument order, in place. When the task has no
# subtasks yet, they are inserted at their canonical position.
_task__set_subtasks() {
  local file="$1"
  shift
  _frontmatter__set_entries --before "$(__task__fields_after subtask)" "$file" subtask "$@"
}

# Usage: _task__remove_context FILE CTX_ID
# Removes every 'context:' entry for CTX_ID from the task file FILE (typically
# a staged copy), in place. Leaves the file unchanged when no entry matches.
_task__remove_context() {
  _frontmatter__remove_entry "$1" context "$2"
}
