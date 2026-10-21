#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "${BASH_SOURCE[0]%/*}" && pwd)/../../harness/harness.sh"


# ---------------------------------------------------------------------------
# Rename-specific introspection helpers
#
# A rename rewrites every commit that carries the task directory, so most of
# what has to be checked is a property of the whole repository rather than of
# one revision: these helpers render the repository into strings that can be
# compared before and after, or searched for traces of the old task ID.
# ---------------------------------------------------------------------------

# Print every change ID in the repository, sorted. Change IDs survive a
# rewrite, so this must be identical before and after a rename.
rename_change_ids() {
  jj -R "$REPO" log -r 'all()' --no-graph -T 'change_id ++ "\n"' 2>/dev/null | sort
}

# Print a fingerprint of all NON-task content in the repository: one section
# per commit, oldest first, holding the commit's change ID, its description and
# the exact diff it applies to everything outside the tt metadata. Identical
# before and after a rename means project content and its incremental history
# were left completely alone.
rename_content_fingerprint() {
  local commit
  while IFS= read -r commit; do
    [[ -z "$commit" ]] && continue
    jj -R "$REPO" log -r "$commit" --no-graph \
      -T '"=== " ++ change_id ++ " " ++ description.first_line() ++ "\n"' 2>/dev/null
    jj -R "$REPO" diff -r "$commit" --git \
      '~(root:".tt" | root-file:"TASK.md")' 2>/dev/null
  done < <(jj -R "$REPO" log -r 'all()' --no-graph --reversed \
    -T 'change_id ++ "\n"' 2>/dev/null)
}

# Print every repo-relative path recorded anywhere in the repository's visible
# history, one per line (with duplicates across commits).
rename_recorded_paths() {
  local commit
  while IFS= read -r commit; do
    [[ -z "$commit" ]] && continue
    jj -R "$REPO" file list -r "$commit" 2>/dev/null
  done < <(jj -R "$REPO" log -r 'all()' --no-graph -T 'commit_id ++ "\n"' 2>/dev/null)
}

# Print the concatenated content of every task file recorded anywhere in the
# repository's visible history, including the copies a child branch inherited
# from its parent.
rename_recorded_task_files() {
  local commit path
  while IFS= read -r commit; do
    [[ -z "$commit" ]] && continue
    while IFS= read -r path; do
      case "$path" in
        .tt/task/*/TASK.md)
          jj -R "$REPO" file show -r "$commit" -- "$path" 2>/dev/null || true
          ;;
      esac
    done < <(jj -R "$REPO" file list -r "$commit" 2>/dev/null)
  done < <(jj -R "$REPO" log -r 'all()' --no-graph -T 'commit_id ++ "\n"' 2>/dev/null)
}

# Print the target of the root TASK.md symlink as RECORDED at REV, or nothing
# (status 1) when the entry is absent or is not stored as a symlink. Read out
# of a Git-format diff against the empty root tree, since a symlink's target is
# not readable as file content.
rename_recorded_symlink() {
  local rev="$1" diff
  diff="$(jj -R "$REPO" diff --git --from 'root()' --to "$rev" \
    -- 'root-file:"TASK.md"' 2>/dev/null)" || return 1
  printf '%s\n' "$diff" | awk '
    /^new file mode 120000$/ { symlink = 1 }
    symlink && !found && /^\+[^+]/ { found = 1; print substr($0, 2) }
    END { exit(found ? 0 : 1) }
  '
}

# Print every local bookmark name in the repository, one per line.
rename_all_bookmark_names() {
  jj -R "$REPO" log -r 'bookmarks()' --no-graph \
    -T 'local_bookmarks.map(|b| b.name()).join("\n") ++ "\n"' 2>/dev/null \
    | grep . || true
}

# Print every Git ref in the store backing the repository, one per line. The
# staging machinery makes each commit reachable through a temporary ref before
# removing it again, so a surviving ref would show up here whether it is loose
# or packed. The store's location is read from the pointer jj keeps beside it,
# and is relative to the pointer itself.
rename_all_git_refs() {
  local store="$REPO/.jj/repo/store" git_dir
  git_dir="$(cd "$store" && cd "$(cat git_target)" && pwd -P)" || return 0
  git --git-dir="$git_dir" for-each-ref --format='%(refname)' 2>/dev/null || true
}

# Print the first line of every commit description in the repository.
rename_descriptions() {
  jj -R "$REPO" log -r 'all()' --no-graph \
    -T 'description.first_line() ++ "\n"' 2>/dev/null
}

# Run `tt task rename` with TMPDIR pointed at PROBE_DIR, so the scratch
# directories the command creates can be checked for afterwards. Invokes the
# CLI directly rather than through run_tt: a temporary environment assignment
# in front of a shell function does not reliably stay scoped to the call.
run_rename_with_probe() {
  local probe="$1"; shift
  ( TMPDIR="$probe" TT_REPO="${TT_REPO:-$REPO}" "$TT" task rename "$@" 2>&1 )
}

# assert_rename_outcomes LABEL OLD_ID NEW_ID CHANGES_BEFORE FINGERPRINT_BEFORE PROBE_DIR
#
# The complete set of outcomes every successful rename must produce, whatever
# the shape of the history it ran against.
assert_rename_outcomes() {
  local label="$1" old_id="$2" new_id="$3"
  local changes_before="$4" fingerprint_before="$5" probe="$6"

  local old_suffix="${old_id#*/}" new_suffix="${new_id#*/}"
  local old_dir=".tt/task/$old_suffix" new_dir=".tt/task/$new_suffix"

  # Identity of every commit in the graph is preserved: the rename replaces
  # what commits record, never which commits exist.
  assert_eq "$label: every change ID unchanged" \
    "$(rename_change_ids)" "$changes_before"

  # No commit anywhere still records the old task directory.
  local paths
  paths="$(rename_recorded_paths)"
  assert_not_contains "$label: no commit records the old task directory" \
    "$paths" "$old_dir/"
  assert_contains "$label: the new task directory is recorded" \
    "$paths" "$new_dir/"

  # No task file references the old task ID — including the copies of the
  # parent's task file that child and sibling branches inherited.
  assert_not_contains "$label: no task file references the old task ID" \
    "$(rename_recorded_task_files)" "$old_id"

  # The repo-root pointer is still a symlink, and points at the new location.
  assert_eq "$label: recorded root TASK.md is a symlink to the new task file" \
    "$(rename_recorded_symlink '@')" "$new_dir/TASK.md"
  assert_symlink "$label: on-disk root TASK.md retargeted" \
    "$REPO/TASK.md" "$new_dir/TASK.md"

  # Project content and its incremental history are untouched.
  assert_eq "$label: non-task content and history untouched" \
    "$(rename_content_fingerprint)" "$fingerprint_before"

  # The working-copy commit carries no diff, and the files on disk have caught
  # up with the rewrite.
  assert_wc_clean "$label: working-copy commit has an empty diff"
  assert_file_exists "$label: renamed task directory on disk" "$REPO/$new_dir"
  assert_file_not_exists "$label: old task directory gone from disk" \
    "$REPO/$old_dir"

  # Nothing anywhere is conflicted.
  assert_no_conflicts "$label: no conflicts" 'all()'

  # The staging commits, their temporary refs and the scratch directory that
  # held the rewrite plan are all gone.
  assert_not_contains "$label: no staging commits survive" \
    "$(rename_descriptions)" ":rename]"
  assert_output_empty "$label: no staging bookmarks survive" \
    "$(rename_all_bookmark_names | grep 'tt-tmp' || true)"
  assert_output_empty "$label: no staging git refs survive" \
    "$(rename_all_git_refs | grep 'tt-tmp' || true)"
  assert_output_empty "$label: no scratch directories survive" \
    "$(find "$probe" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)"

  assert_tt_workspace_integrity "$label: workspace integrity"
}


test_task_rename__basic_rename() {
  setup_workspace "rename-basic"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "old-name" "Old Task" "Task body") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task rename --slug "new-name" 2>&1) || exit_code=$?
  assert_success "rename succeeds" "$exit_code"
  assert_contains "output has rename message" "$output" "new-name"

  # Old bookmark gone
  old_hex="${task_id#task/old-name-}"
  old_id="task/old-name-${old_hex}"
  assert_bookmark_not_exists "old bookmark gone" "$old_id"

  # New bookmark exists
  new_id="task/new-name-${old_hex}"
  assert_bookmark_exists "new bookmark exists" "$new_id"
  assert_task_title "title preserved" "$new_id" "Old Task"
  assert_task_body_contains "body preserved" "$new_id" "Task body"
}


test_task_rename__same_slug_is_no_op() {
  setup_workspace "rename-same"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "same" "Same Task") || true
  checkout_task "$task_id" >/dev/null || true
  bm_before=$(get_bookmark_commit "$task_id")

  output="" exit_code=0
  output=$(run_tt task rename --slug "same" 2>&1) || exit_code=$?
  assert_success "same slug succeeds" "$exit_code"
  bm_after=$(get_bookmark_commit "$task_id")
  assert_eq "bookmark unchanged" "$bm_before" "$bm_after"
}


test_task_rename__invalid_slug_rejected() {
  setup_workspace "rename-invalid"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  output="" exit_code=0
  output=$(run_tt task rename --slug "UPPERCASE" 2>&1) || exit_code=$?
  assert_failure "invalid slug rejected" "$exit_code"
}


test_task_rename__dirty_wc_rejected() {
  setup_workspace "rename-dirty"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true
  edit_file "dirty.txt" "dirty"

  output="" exit_code=0
  output=$(run_tt task rename --slug "new" 2>&1) || exit_code=$?
  assert_failure "dirty WC rejected" "$exit_code"
  assert_contains "error names the precondition" "$output" "Working copy is not clean"
  assert_bookmark_exists "task not renamed" "$task_id"
}


test_task_rename__parent_subtask_entry_updated() {
  setup_workspace "rename-parent"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "child" "Child") || true
  checkout_task "$task_id" >/dev/null || true

  run_tt task rename --slug "renamed" >/dev/null 2>&1 || true

  old_hex="${task_id#task/child-}"
  new_id="task/renamed-${old_hex}"
  assert_subtask_entry "parent subtask updated" "$proj_id" "$new_id" "[ ]"
  assert_no_subtask_entry "old subtask removed" "$proj_id" "$task_id"
}


test_task_rename__after_a_move_to_a_newer_parent() {
  setup_workspace "rename-after-move"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "child" "Child") || true
  checkout_task "$proj_id" >/dev/null || true
  new_parent=$(create_task "newparent" "New parent") || true
  run_tt task move --task "$task_id" --parent "$new_parent" >/dev/null 2>&1 || true
  assert_subtask_entry "fixture: the child moved under the newer parent" \
    "$new_parent" "$task_id" "[ ]"

  # The child's introduction commit predates the new parent's task file.
  checkout_task "$task_id" >/dev/null || true
  output="" exit_code=0
  output=$(run_tt task rename --slug "child2" 2>&1) || exit_code=$?
  assert_success "the rename succeeds" "$exit_code"
  local new_id="task/child2-${task_id#task/child-}"
  assert_subtask_entry "the parent lists the renamed child" "$new_parent" "$new_id" "[ ]"
}

test_task_rename__preserves_task_file_content() {
  setup_workspace "rename-preserve"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(run_tt task create --slug "t" --title "T" --label "bug" <<< "Body text" 2>/dev/null | tail -1) || true
  checkout_task "$task_id" >/dev/null || true

  run_tt task rename --slug "renamed" >/dev/null 2>&1 || true

  old_hex="${task_id#task/t-}"
  new_id="task/renamed-${old_hex}"
  assert_task_title "title preserved" "$new_id" "T"
  assert_task_body_contains "body preserved" "$new_id" "Body text"
  assert_task_label "label preserved" "$new_id" "bug"
  assert_task_status "status preserved" "$new_id" "IN-PROGRESS"
}


test_task_rename__records_transaction() {
  setup_workspace "rename-txn"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "t" "T") || true
  checkout_task "$task_id" >/dev/null || true

  get_history_lines; hc_before="${#HISTORY_LINES[@]}"
  run_tt task rename --slug "renamed" >/dev/null 2>&1 || true
  get_history_lines
  assert_eq "one new entry" "$((${#HISTORY_LINES[@]} - hc_before))" "1"
  assert_history_integrity "history after rename"
}


# Topology 1: a task that has just been forked from its parent — its own
# branch holds nothing but the commits `tt task create` and `tt task checkout`
# made, and the parent's tip is still the commit the task forked from.
test_task_rename__topology_fresh_fork() {
  setup_workspace "rename-topo-fresh"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "old-name" "Old Task" "Task body") || true
  checkout_task "$task_id" >/dev/null || true

  old_hex="${task_id#task/old-name-}"
  new_id="task/new-name-${old_hex}"

  probe="$_TEST_ROOT/probe-fresh"; mkdir -p "$probe"
  changes_before="$(rename_change_ids)"
  fingerprint_before="$(rename_content_fingerprint)"

  output="" exit_code=0
  output=$(run_rename_with_probe "$probe" --slug "new-name") || exit_code=$?
  assert_success "rename succeeds" "$exit_code"

  assert_bookmark_not_exists "old bookmark gone" "$task_id"
  assert_bookmark_exists "new bookmark exists" "$new_id"
  assert_subtask_entry "parent subtask repointed" "$proj_id" "$new_id" "[ ]"
  assert_task_title "title preserved" "$new_id" "Old Task"
  assert_task_body_contains "body preserved" "$new_id" "Task body"

  assert_rename_outcomes "fresh fork" "$task_id" "$new_id" \
    "$changes_before" "$fingerprint_before" "$probe"
}


# Topology 2: a task with commits made past its own bookmark (plain commits
# that no checkpoint has recorded) and a context file in its task directory.
# The trailing commits are inside the rewrite range even though the bookmark
# does not reach them.
test_task_rename__topology_trailing_commits_and_context() {
  setup_workspace "rename-topo-trailing"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "old-name" "Old Task" "Task body") || true
  checkout_task "$task_id" >/dev/null || true

  # A context file, which lives in the task directory alongside TASK.md.
  echo "Handoff notes" | run_tt task context add --title "Research" --slug "research" \
    >/dev/null 2>&1 || true

  # Two commits beyond the task bookmark: the bookmark stays where it was.
  edit_file "app.txt" "app v1"
  jj_commit "work 1"
  append_file "app.txt" "app v2"
  jj_commit "work 2"

  old_hex="${task_id#task/old-name-}"
  new_id="task/new-name-${old_hex}"
  bookmark_before="$(get_bookmark_commit "$task_id")"
  trailing_count_before="$(count_commits "${task_id}..@")"

  probe="$_TEST_ROOT/probe-trailing"; mkdir -p "$probe"
  changes_before="$(rename_change_ids)"
  fingerprint_before="$(rename_content_fingerprint)"

  output="" exit_code=0
  output=$(run_rename_with_probe "$probe" --slug "new-name") || exit_code=$?
  assert_success "rename succeeds" "$exit_code"

  assert_bookmark_not_exists "old bookmark gone" "$task_id"
  assert_bookmark_exists "new bookmark exists" "$new_id"
  assert_neq "bookmark commit was rewritten" \
    "$(get_bookmark_commit "$new_id")" "$bookmark_before"
  assert_eq "trailing commits still sit beyond the bookmark" \
    "$(count_commits "${new_id}..@")" "$trailing_count_before"

  # The context file travelled with the task directory, and the task file
  # still lists it.
  ctx_id="$(read_task_file "$new_id" '@' | sed -n 's/^context: *//p' | head -1)"
  assert_output_not_empty "context entry preserved" "$ctx_id"
  assert_file_on_branch "context file moved to the new directory" '@' \
    ".tt/task/new-name-${old_hex}/${ctx_id}.md"
  assert_file_content_at_rev "context body preserved" '@' \
    ".tt/task/new-name-${old_hex}/${ctx_id}.md" "Handoff notes"

  # Non-task work carried past the bookmark is still there, unchanged.
  assert_file_content_at_rev "trailing work preserved" '@' "app.txt" "app v2"

  assert_rename_outcomes "trailing commits" "$task_id" "$new_id" \
    "$changes_before" "$fingerprint_before" "$probe"
}


# Topology 3: a task whose parent advanced past the fork point (a sibling task
# was created on the parent afterwards), so the sibling branch inherited the
# renamed task's stub directory and the parent's tip is not an ancestor of the
# task branch.
test_task_rename__topology_advanced_parent_with_sibling() {
  setup_workspace "rename-topo-sibling"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "old-name" "Old Task" "Task body") || true

  # The parent advances after the task forked: a sibling is created on it.
  # tt task create leaves @ on the branch it wrote, so the parent is checked
  # out explicitly first to make the sibling a child of the project.
  checkout_task "$proj_id" >/dev/null || true
  sibling_id=$(create_task "sibling" "Sibling") || true

  checkout_task "$task_id" >/dev/null || true
  edit_file "app.txt" "app v1"
  checkpoint_task "task work" >/dev/null 2>&1 || true

  old_hex="${task_id#task/old-name-}"
  new_id="task/new-name-${old_hex}"
  sibling_before="$(get_bookmark_commit "$sibling_id")"

  probe="$_TEST_ROOT/probe-sibling"; mkdir -p "$probe"
  changes_before="$(rename_change_ids)"
  fingerprint_before="$(rename_content_fingerprint)"

  output="" exit_code=0
  output=$(run_rename_with_probe "$probe" --slug "new-name") || exit_code=$?
  assert_success "rename succeeds" "$exit_code"

  assert_bookmark_not_exists "old bookmark gone" "$task_id"
  assert_bookmark_exists "new bookmark exists" "$new_id"
  assert_bookmark_exists "sibling bookmark intact" "$sibling_id"
  assert_neq "sibling branch was rewritten too" \
    "$(get_bookmark_commit "$sibling_id")" "$sibling_before"

  # Both the parent's own copy and the sibling's inherited copy of the parent
  # task file name the renamed task.
  assert_subtask_entry "parent subtask repointed" "$proj_id" "$new_id" "[ ]"
  assert_subtask_entry "sibling entry untouched" "$proj_id" "$sibling_id" "[ ]"
  assert_subtask_entry "inherited copy on the sibling branch repointed" \
    "$proj_id" "$new_id" "[ ]" "$sibling_id"
  assert_no_subtask_entry "inherited copy no longer names the old task" \
    "$proj_id" "$task_id" "$sibling_id"

  assert_rename_outcomes "advanced parent" "$task_id" "$new_id" \
    "$changes_before" "$fingerprint_before" "$probe"
}


# A rename rewrites commits it does not own, so it cannot be run while another
# worktree is parked inside the range: rewriting the commit under that
# worktree would strand work that exists only on its disk.
test_task_rename__refuses_foreign_worktree_in_range() {
  setup_workspace "rename-foreign-wt"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "old-name" "Old Task") || true

  checkout_task "$proj_id" >/dev/null || true
  sibling_id=$(create_task "sibling" "Sibling") || true
  sibling_wt=$(create_task_worktree "$sibling_id") || true
  checkout_task "$task_id" >/dev/null || true

  # Work that only exists on the other worktree's disk.
  printf 'not snapshotted\n' > "$sibling_wt/untracked.txt"

  op_before="$(get_jj_op)"
  changes_before="$(rename_change_ids)"
  bookmarks_before="$(get_all_task_bookmarks)"

  output="" exit_code=0
  output=$(run_tt task rename --slug "new-name" 2>&1) || exit_code=$?
  assert_failure "rename refused" "$exit_code"
  assert_contains "error explains the refusal" "$output" \
    "Cannot rename while other worktrees hold commits in the rewrite range"
  assert_contains "error names the blocking worktree path" "$output" "$sibling_wt"
  assert_contains "error names the blocking worktree's task" "$output" "$sibling_id"
  assert_contains "error points at worktree sync" "$output" "tt worktree sync"
  assert_contains "error points at worktree delete" "$output" "tt worktree delete"

  # The repository is completely unmodified.
  assert_eq "no backend operation recorded" "$(get_jj_op)" "$op_before"
  assert_eq "no change IDs added or removed" "$(rename_change_ids)" "$changes_before"
  assert_eq "bookmarks untouched" "$(get_all_task_bookmarks)" "$bookmarks_before"
  assert_bookmark_exists "task not renamed" "$task_id"
  assert_no_pending_transaction "no transaction was opened"

  # The other worktree's un-snapshotted work is still on its disk.
  assert_file_exists "foreign worktree file intact" "$sibling_wt/untracked.txt"

  # --force is not an escape hatch: the refusal stands and nothing is renamed.
  exit_code=0
  output=$(run_tt task rename --slug "new-name" --force 2>&1) || exit_code=$?
  assert_failure "--force does not bypass the refusal" "$exit_code"
  assert_eq "still no backend operation recorded" "$(get_jj_op)" "$op_before"
  assert_bookmark_exists "task still not renamed" "$task_id"
  assert_file_exists "foreign worktree file still intact" "$sibling_wt/untracked.txt"
}


test_task_rename__refuses_bookmark_on_working_copy() {
  setup_workspace "rename-bm-refusal"
  proj_id=$(create_project "proj" "Project") || true
  checkout_task "$proj_id" >/dev/null || true
  task_id=$(create_task "old-name" "Old Task") || true
  checkout_task "$task_id" >/dev/null || true

  # Clean working copy carrying the task's own bookmark: the clean-WC
  # precondition passes, so the working-copy guard itself is what refuses.
  jj -R "$REPO" bookmark set "$task_id" -r '@' >/dev/null 2>&1
  output="" exit_code=0
  output=$(run_tt task rename --slug "new-name" 2>&1) || exit_code=$?
  assert_failure "own bookmark on @ refused" "$exit_code"
  assert_contains "error names the bookmark" "$output" "tip of bookmark"
  assert_bookmark_exists "task not renamed" "$task_id"

  # A bookmark unrelated to the task being renamed is refused just the same.
  jj -R "$REPO" bookmark set "$task_id" -r '@-' --allow-backwards >/dev/null 2>&1
  jj -R "$REPO" bookmark set unrelated -r '@' >/dev/null 2>&1
  exit_code=0
  output=$(run_tt task rename --slug "new-name" --task "$task_id" 2>&1) || exit_code=$?
  assert_failure "unrelated bookmark on @ refused" "$exit_code"
  assert_contains "error names the unrelated bookmark" "$output" "unrelated"
  assert_bookmark_exists "task still not renamed" "$task_id"
}


test_task_rename__help() {
  setup_workspace "rename-help"
  output="" exit_code=0
  output=$(run_tt task rename --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt task rename"
  assert_required_usage_argument "argument: --slug" "$output" "--slug"
  assert_required_usage_argument "argument: --task" "$output" "--task"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


test_task_rename__refuses_when_the_canonical_workspace_is_stale() {
  setup_workspace "rename-stale-canonical"
  setup_guard_fixture "renamed"
  # A rename refuses outright when another worktree sits inside the range it
  # rewrites, and that check runs first. Park the canonical workspace outside
  # the range so the staleness guard is what this test exercises.
  jj -R "$REPO" new main >/dev/null 2>&1
  make_worktree_stale "$REPO"

  assert_refuses_stale_canonical "$STALE_WORKTREE" \
    task rename --slug "renamed-again" --task "$STALE_TASK_ID"
}

run_tests "tt task rename"
