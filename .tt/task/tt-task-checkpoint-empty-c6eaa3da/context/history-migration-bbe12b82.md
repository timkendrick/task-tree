---
title: "History migration: merge-based checkpoints"
created: 2026-11-13T21:22:25Z
updated: 2026-11-13T21:22:25Z
---
A script that rewrites an existing tt repository's history so that it follows the merge-based checkpoint conventions: commits that tt creates hold only task metadata, and user commits reach a task branch through an empty `[tt:<ns>:<id>:merge] <title>` commit followed by an empty `[tt:<ns>:<id>:checkpoint] <message>` commit.

## What it changes

The script rewrites only the `[tt:` era: the oldest commit whose message starts with `[tt:task:`, and every commit descended from it. Older commits stay as they are. These include commits in older message formats (`Checkpoint: ...`, `Complete task: ...`) and workspace setup commits that precede the first task.

1. Empty, undescribed commits that are not a workspace's working copy (leftover working copies) are abandoned.
2. A tt merge commit with more than two parents loses each parent that is an ancestor of another parent. The descendant parent takes the position of the ancestor. The tree of the merge does not change.
3. A `[checkpoint]` commit that changes files is split. Its changes move into a new commit beneath it, described by the checkpoint message without the `[tt:...]` prefix. The checkpoint itself becomes empty.
4. User commits directly beneath a `[checkpoint]` move onto a side arm. A new `[merge]` commit joins them to the branch. Its first parent is the previous tt commit and its second parent is the newest user commit.
5. User commits directly beneath any other non-merge tt commit get the same `[merge]`. A generated `[checkpoint]` follows it, described by the first line of the newest user commit. Examples are a `[complete]` or `[context:add]` made without a checkpoint first.

```
before                                   after

o  [T:checkpoint] Add parser             o  (empty) [T:checkpoint] Add parser
|  (changes parser.rs)                   o    (empty) [T:merge] <title>
o  Add tokenizer                         |\
o  [T:checkout]                          | o  Add parser       (changes parser.rs)
                                         | o  Add tokenizer
                                         |/
                                         o  [T:checkout]
```

New commits copy the author and author timestamp of the commit they derive from. Every rewrite preserves the file contents of every bookmark and every working copy.

### Committer timestamps

jj gives every rewritten commit the current time as its committer timestamp. A final phase restores the committer line (name, email and timestamp) that each commit had before the run:

- A commit that existed before the run gets its own original committer line.
- A new commit gets the original committer line of its source commit. The source is the nearest commit, within three parent or child steps, that existed before the run and has the same author line. For a merge, a child checkpoint wins a tie.
- A commit without a source gets its own author timestamp.

jj cannot set committer timestamps. The phase therefore rewrites the git commit objects directly. It changes only committer lines and parent IDs, so change IDs, trees, authors and messages stay the same. It then moves bookmarks and working copies onto the rewritten commits and abandons the replaced commits.

## Usage

Extract the script from this context file, then run it from anywhere:

```shell
tt task context get <context-id> --task task/tt-task-checkpoint-empty-c6eaa3da \
  | awk '/^```bash migrate-checkpoint-history.sh$/ { f = 1; next } /^```$/ { f = 0 } f' > migrate-checkpoint-history.sh
bash migrate-checkpoint-history.sh -R <repo> --check     # list convention violations
bash migrate-checkpoint-history.sh -R <repo> --dry-run   # list the fixes a run would apply
bash migrate-checkpoint-history.sh -R <repo>             # rewrite
```

`tt task context list task/tt-task-checkpoint-empty-c6eaa3da` prints the context ID.

A real run:

- requires `python3`;
- refuses unless every workspace of the repository is clean and not stale, every workspace's recorded path belongs to this repository, and no tt command is in progress;
- records an in-progress entry in `.tt/history`, and records the commit of every local bookmark, working copy and git branch;
- applies the fixes and restores the committer timestamps;
- verifies that the bookmark set is unchanged, that every bookmark and working copy has the same file contents as before, and that `--check` passes;
- restores the starting operation and git branches if anything fails;
- otherwise updates every workspace (`jj workspace update-stale`) and completes the `.tt/history` entry, so `tt history undo` reverts the whole migration.

## Before running it

- **Time.** Every fix rewrites all commits descended from it, so the cost grows with the square of the history size. A repository with about 2,000 commits and 155 fixes took 35 minutes. A repository with about 4,800 commits and 528 fixes took 6.3 hours. The committer timestamp phase takes seconds.
- **Storage.** The repeated rewrites leave many unreachable objects behind. On a repository with about 2,000 commits, `.git` grew from 50 MB to 1.9 GB. Run `jj util gc` afterwards to reclaim the space. On a large repository it can run for hours. Do not interrupt it: an interrupted run leaves a stale lock file under `.git/refs/jj/keep/`.
- **Remotes.** Every rewritten commit gets a new ID, so bookmarks that were pushed need a force-push. Branches that other people built on the old commits need a rebase onto the new ones. The script never pushes.
- **Copied repositories.** jj records workspace paths absolutely, so a copy of a repository still names the workspace directories of the original. The script refuses to run in that state. Forget the other workspaces in the copy first (`jj workspace forget <name>`). On APFS, `cp -Rc` makes the copy in minutes. After a run, the copy holds hundreds of thousands of small files, so deleting it is slow.
- **Shapes the script cannot fix.** A real run with any of these shapes fails at the end and restores the starting state, possibly after hours. Find them with `--check` and `--dry-run`, and repair them by hand first:
  - a `--dry-run` line that starts with `  skip`;
  - a user commit with two or more tt children that each need a fix (the second fix would create a second merge of the same two commits);
  - a user commit that changes task metadata (`R5`);
  - a tt commit other than a checkpoint that changes project files (`R5`);
  - a checkpoint that changes only task metadata. The split would move the metadata into a user commit. This revset finds them: `description(regex:"^\\[tt:[^]]*:checkpoint\\]") & ~empty() & files(root:".tt/task" | root-file:"TASK.md")`;
  - a tt merge with more than two parents where no parent is an ancestor of another.

  `R1` and `R5` violations on checkpoints that change only project files are expected: fix 3 handles them.
- **Known remaining issue.** `tt task propagate --rebase` and `tt task move` can leave a merge whose first parent is already in the parent branch, which bends the first-parent line (see `task/propagate-checkpoint-merge-parents-2837f3d1`). The script does not address it.

## Verification rules (`--check`)

The rules apply to the `[tt:` era. "tt commit" includes the older message formats, which start with a keyword and a colon (`Checkpoint: ...`). A message such as `Checkpoint before ...` is a user commit.

- **R1** Every `[checkpoint]` is empty and has exactly one parent, which is a tt commit.
- **R2** Every `[merge]` is empty, has a tt commit as first parent and a user commit as second parent, and is followed by a `[checkpoint]` of the same task.
- **R3** Every other `[tt:` commit has exactly one parent, except `checkin`, `propagate` and `publish`, which have two.
- **R4** No `[tt:` commit sits on a user commit. The exceptions are the second parent of `[merge]`, the base of `[new]`, the target side of `[publish]`, and the parents of the oldest commits of the era.
- **R5** No `[tt:` commit changes files outside `.tt/` and `TASK.md`, and no user commit changes task metadata.
- **R6** No leftover empty, undescribed commits remain.

## Tested

- The task-tree repository (about 2,000 commits, 2 workspaces): 7 leftovers abandoned and 155 fixes in 35 minutes. All 182 bookmarks kept their file contents, and `--check` reported no violations.
- The grfn repository (about 4,800 commits in the era, 5 workspaces): 10 leftovers abandoned and 528 fixes in 6.3 hours. All 335 bookmarks kept their file contents, and `--check` reported no violations. One-off repairs before the run handled the shapes listed above:
  - an orphaned `[edit]` commit was abandoned;
  - three metadata-only checkpoints, and the metadata part of one user commit, were folded into the `[context:add]` commits that created those files;
  - a stray symlink was split out of a `[create]` and a `[handoff]` commit into user commits.
- The committer timestamp phase on both repositories: 1,273 and 5,388 commits rewritten in seconds. No existing commit kept a changed committer timestamp, and every bookmark kept its file contents.
- Synthetic repositories in colocated and non-colocated layouts. They cover each fix, a three-parent publish, setup commits before the first task, an orphan head and a second workspace. A failing run restored the commits, git branches and `.tt/history` exactly. A second run on a migrated repository changed nothing.
- jj 0.47.1, Python 3.12.

## Script

```bash migrate-checkpoint-history.sh
#!/usr/bin/env bash
set -euo pipefail

# migrate-checkpoint-history: rewrite a tt repository's history so that it
# follows the merge-based checkpoint conventions.
#
# The conventions:
#   - Commits that tt creates hold only task metadata; user commits hold only
#     project files.
#   - User commits reach a task branch through an empty
#     `[tt:<ns>:<id>:merge] <title>` commit, whose first parent is the
#     previous tip of the branch and whose second parent is the newest user
#     commit, followed by an empty `[tt:<ns>:<id>:checkpoint] <message>`
#     commit.
#
# Fixes applied, in order, within the `[tt:` era (every descendant of the
# oldest `[tt:task:`-prefixed commit; earlier history, including workspace
# setup commits that precede the first task, is left untouched):
#   1. Empty, undescribed commits that are not a workspace's working copy are
#      abandoned.
#   2. A tt merge commit with more than two parents loses every parent that is
#      an ancestor of another parent: the descendant parent takes the
#      ancestor's position. The commit's tree is unchanged.
#   3. A checkpoint commit that changes files is split: its changes move into a
#      new commit described by the checkpoint message, inserted beneath it.
#   4. User commits sitting directly beneath a checkpoint are moved onto a side
#      arm joined by a new merge commit.
#   5. User commits sitting directly beneath any other non-merge tt commit are
#      moved onto a side arm joined by a new merge commit, followed by a new
#      checkpoint commit described by the first line of the newest user commit.
# The oldest commits of the era may sit on user commits outside it.
# New commits copy their author and author timestamp from the commit they are
# derived from.
#
# jj stamps every rewritten commit with the current committer timestamp. A
# final phase restores the committer line that each commit had before the run.
# A new commit gets the original committer line of the commit it derives from.
#
# Every rewrite preserves the tree of every bookmark and every working copy; a
# real run verifies this and restores the starting operation if it does not
# hold.

readonly SCRIPT_NAME="${0##*/}"

readonly LEGACY_PATTERN='^(Add context|Assign subtask|Begin task|Checkpoint|Complete task|Create project|Create task|Create workspace|Delete context|Describe task|Edit task|Handoff|Merge project|Merge subtask|Move task|Publish|Remove subtask|Reorder task|Resume task):'

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [--dry-run | --check] [-R PATH]

Rewrite a tt repository's history so that checkpoints follow the merge-based
conventions: tt commits hold only task metadata, and user commits reach a task
branch through an empty [merge] commit followed by an empty [checkpoint] commit.

Modes:
  (default)    Rewrite history, verify the result, and restore the starting
               operation if verification fails.
  --dry-run    Print the fixes a real run would apply, without changing anything.
  --check      Check the conventions and print every violation. Exits 1 when
               any are found.

Options:
  -R PATH      Repository or workspace to operate on (default: current directory).
  -h, --help   Show this help.

A real run requires python3, every workspace of the repository to be clean and
not stale, and no tt command to be in progress. It restores the original
committer timestamps of rewritten commits. It records the rewrite in
.tt/history, so 'tt history undo' reverts it, and updates every workspace
afterwards. Rewritten commits that were pushed must be force-pushed.
EOF
}

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "Error: $*"
  exit 1
}

# ---------------------------------------------------------------------------
# jj access
# ---------------------------------------------------------------------------

REPO=''

jjr() {
  jj -R "$REPO" --ignore-working-copy --no-pager "$@"
}

jjw() {
  jj -R "$REPO" --ignore-working-copy --ignore-immutable --no-pager --quiet "$@"
}

readonly TT_REVSET='description(regex:"^\\[tt:")'
readonly LEGACY_REVSET="description(regex:\"${LEGACY_PATTERN}\")"
readonly TOOL_REVSET="(${TT_REVSET}) | (${LEGACY_REVSET})"
readonly TT_TASK_REVSET='description(regex:"^\\[tt:task:")'
readonly ERA_REVSET="descendants(roots(${TT_TASK_REVSET}))"
readonly LEFTOVER_REVSET="(${ERA_REVSET}) & empty() & description(exact:\"\") & ~working_copies() & ~merges() & ~bookmarks() & ~root()"
readonly CHECKPOINT_REVSET='description(regex:"^\\[tt:[^]]*:checkpoint\\]")'
readonly NO_RUN_OPS_REVSET='description(regex:"^\\[tt:[^]]*:(merge|new|checkin|propagate|publish)\\]")'
readonly TT_MERGE_OPS_REVSET='description(regex:"^\\[tt:[^]]*:(merge|checkin|propagate|publish)\\]")'

# Usage: list_ids REVSET
# Prints the change IDs of REVSET, oldest first.
list_ids() {
  jjr log -r "$1" --reversed --no-graph -T 'change_id ++ "\n"'
}

count_revs() {
  jjr log -r "$1" --no-graph -T '"x\n"' | grep -c . || true
}

field() {
  jjr log -r "$1" --no-graph -T "$2"
}

is_tool_commit() {
  local desc="$1"
  [[ "$desc" == '[tt:'* ]] && return 0
  printf '%s\n' "$desc" | head -n 1 | grep -qE "$LEGACY_PATTERN"
}

first_line() {
  printf '%s\n' "$1" | head -n 1
}

# ---------------------------------------------------------------------------
# tt metadata
# ---------------------------------------------------------------------------

# Usage: parse_tag DESCRIPTION
# Prints "<namespace>\t<entity>\t<operation>" for a `[tt:<ns>:<entity>:<op>]`
# description.
parse_tag() {
  local line tag ns rest entity op
  line="$(first_line "$1")"
  tag="${line#\[tt:}"
  tag="${tag%%\]*}"
  ns="${tag%%:*}"
  rest="${tag#*:}"
  entity="${rest%%:*}"
  op="${rest#*:}"
  printf '%s\t%s\t%s\n' "$ns" "$entity" "$op"
}

# Usage: read_config_prefix REV KEY DEFAULT
read_config_prefix() {
  local rev="$1" key="$2" default="$3" value
  value="$(jjr file show -r "$rev" 'root-file:".tt/config.toml"' 2>/dev/null \
    | sed -nE "s/^${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\\1/p" | head -n 1)" || true
  printf '%s\n' "${value:-$default}"
}

# Usage: read_task_symlink REV
# Prints the target of the repo-root TASK.md symlink at REV.
read_task_symlink() {
  jjr diff --git --from 'root()' --to "$1" -- 'root-file:"TASK.md"' 2>/dev/null \
    | awk '/^new file mode 120000/ { link = 1 } link && /^\+[^+]/ { print substr($0, 2); exit }'
}

# Usage: decode_title RAW
# Decodes a frontmatter title value as tt writes it, and flattens it to one line.
decode_title() {
  printf '%s' "$1" | awk '
    {
      s = $0
      if (substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") {
        s = substr(s, 2, length(s) - 2)
        out = ""
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (c == "\\" && i < length(s)) {
            i++
            d = substr(s, i, 1)
            if (d == "n" || d == "r" || d == "t") out = out " "
            else if (d == "\"" || d == "\\" || d == "/") out = out d
            else if (d == "b" || d == "f") out = out ""
            else out = out "\\" d
          } else {
            out = out c
          }
        }
        s = out
      }
      print s
    }'
}

# Usage: read_task_title REV SUFFIX
read_task_title() {
  local rev="$1" suffix="$2" raw
  raw="$(jjr file show -r "$rev" "root-file:\".tt/task/${suffix}/TASK.md\"" 2>/dev/null \
    | awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
           NR > 1 && /^title:/ { sub(/^title:[[:space:]]*/, ""); print; exit }')" || true
  [[ -n "$raw" ]] || return 1
  decode_title "$raw"
}

# Usage: entity_suffix ENTITY REV
# Strips the configured task or project prefix from a task ID.
entity_suffix() {
  local entity="$1" rev="$2" task_prefix project_prefix
  task_prefix="$(read_config_prefix "$rev" task_prefix 'task/')"
  project_prefix="$(read_config_prefix "$rev" project_prefix 'project/')"
  if [[ "$entity" == "$task_prefix"* ]]; then
    printf '%s\n' "${entity#"$task_prefix"}"
  elif [[ "$entity" == "$project_prefix"* ]]; then
    printf '%s\n' "${entity#"$project_prefix"}"
  else
    printf '%s\n' "${entity##*/}"
  fi
}

# Usage: entity_at REV
# Prints the task ID that REV's TASK.md symlink names, as it appears in tt
# commit messages.
entity_at() {
  local rev="$1" target suffix prefix candidate
  target="$(read_task_symlink "$rev")"
  [[ "$target" =~ ^\.tt/task/([^/]+)/TASK\.md$ ]] || return 1
  suffix="${BASH_REMATCH[1]}"
  for prefix in "$(read_config_prefix "$rev" task_prefix 'task/')" \
                "$(read_config_prefix "$rev" project_prefix 'project/')"; do
    candidate="${prefix}${suffix}"
    if [[ "$(count_revs "description(substring:\"]\") & description(substring:\":${candidate}:\")")" -gt 0 ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Rewrites
# ---------------------------------------------------------------------------

# Usage: copy_author SOURCE TARGET
copy_author() {
  local source="$1" target="$2" name email timestamp
  name="$(field "$source" 'author.name()')" || return 1
  email="$(field "$source" 'author.email()')" || return 1
  timestamp="$(field "$source" 'author.timestamp().format("%Y-%m-%dT%H:%M:%S%:z")')" || return 1
  jjw metaedit -r "$target" --author "$name <$email>" --author-timestamp "$timestamp"
}

# Usage: single_id REVSET
# Prints the change ID of the single commit REVSET names, or fails.
single_id() {
  local ids
  ids="$(list_ids "$1")"
  [[ -n "$ids" && "$ids" != *$'\n'* ]] || return 1
  printf '%s\n' "$ids"
}

# Usage: create_merge BASE HEAD MESSAGE AUTHOR_SOURCE
create_merge() {
  local base="$1" head="$2" message="$3" author_source="$4" merge
  [[ "$(count_revs "children(${base}) & children(${head})")" -eq 0 ]] \
    || die "a commit already joins $base and $head"
  jjw new --no-edit "$base" "$head" -m "$message" || die "could not create a merge on $base and $head"
  merge="$(single_id "children(${base}) & children(${head})")" \
    || die "could not find the merge commit created on $base and $head"
  copy_author "$author_source" "$merge" || die "could not set the author of $merge"
  printf '%s\n' "$merge"
}

# Usage: create_child PARENT MESSAGE AUTHOR_SOURCE
create_child() {
  local parent="$1" message="$2" author_source="$3" child
  [[ "$(count_revs "children(${parent})")" -eq 0 ]] || die "$parent already has children"
  jjw new --no-edit "$parent" -m "$message" || die "could not create a commit on $parent"
  child="$(single_id "children(${parent})")" || die "could not find the commit created on $parent"
  copy_author "$author_source" "$child" || die "could not set the author of $child"
  printf '%s\n' "$child"
}

# Usage: split_checkpoint CHECKPOINT MESSAGE
# Moves CHECKPOINT's changes into a new commit inserted beneath it, described
# by MESSAGE. Prints the new commit's change ID.
split_checkpoint() {
  local checkpoint="$1" message="$2" data
  jjw new --no-edit -B "$checkpoint" -m "$message" || die "could not insert a commit beneath $checkpoint"
  data="$(single_id "${checkpoint}-")" || die "could not find the commit inserted beneath $checkpoint"
  jjw squash --from "$checkpoint" --into "$data" --keep-emptied --use-destination-message \
    || die "could not move the changes of $checkpoint into $data"
  copy_author "$checkpoint" "$data" || die "could not set the author of $data"
  printf '%s\n' "$data"
}

# Usage: describe_run COMMIT
# Walks COMMIT's single-parent ancestry through user commits. Prints the
# change ID of the commit the walk stops at (the base), then the number of
# user commits passed. Fails when a user commit has several parents or the
# walk reaches the root.
describe_run() {
  local commit="$1" parent desc count=0 leftover
  while :; do
    parent="$(single_id "${commit}-")" || return 1
    desc="$(field "$parent" 'description')"
    if is_tool_commit "$desc"; then
      printf '%s\n%s\n' "$parent" "$count"
      return 0
    fi
    leftover="$(count_revs "(${parent}) & (${LEFTOVER_REVSET})")"
    [[ "$leftover" -gt 0 ]] || count=$((count + 1))
    commit="$parent"
  done
}

FIX_COUNT=0
SKIP_COUNT=0

# Usage: fix_commit CHANGE_ID MODE
# MODE is 'apply' or 'plan'.
fix_commit() {
  local commit="$1" mode="$2"
  local desc tag ns entity op nonempty base run_length line
  desc="$(field "$commit" 'description')"
  line="$(first_line "$desc")"
  tag="$(parse_tag "$desc")"
  IFS=$'\t' read -r ns entity op <<< "$tag"
  nonempty="$(field "$commit" 'if(empty, "", "yes")')"

  local run
  if ! run="$(describe_run "$commit")"; then
    log "  skip  $line"
    log "        (user commits beneath it are a merge or reach the root)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    return 0
  fi
  base="${run%%$'\n'*}"
  run_length="${run##*$'\n'}"

  local split=false
  [[ "$op" == checkpoint && -n "$nonempty" ]] && split=true
  if [[ "$split" == false && "$run_length" -eq 0 ]]; then
    return 0
  fi

  local task_id suffix title
  if [[ "$op" == checkpoint ]]; then
    task_id="$entity"
  else
    task_id="$(entity_at "$base")" || {
      log "  skip  $line"
      log "        (cannot tell which task the commit beneath it belongs to)"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      return 0
    }
  fi
  suffix="$(entity_suffix "$task_id" "$base")"
  title="$(read_task_title "$base" "$suffix")" || title="$task_id"

  FIX_COUNT=$((FIX_COUNT + 1))
  if [[ "$mode" == plan ]]; then
    log "  fix   $line"
    [[ "$split" == true ]] && log "        split its changes into a commit beneath it"
    local merged="$run_length"
    [[ "$split" == true ]] && merged=$((merged + 1))
    log "        merge $merged user commit(s) into $task_id"
    [[ "$op" != checkpoint ]] && log "        add a checkpoint beneath it"
    return 0
  fi

  log "  fix   $line"
  local head
  if [[ "$split" == true ]]; then
    local message="${desc#*\] }"
    message="${message%$'\n'}"
    head="$(split_checkpoint "$commit" "$message")"
  else
    head="$(single_id "${commit}-")" || die "could not find the parent of $commit"
  fi

  local merge_message merge
  merge_message="[tt:${ns}:${task_id}:merge] ${title}"
  if [[ "$op" == checkpoint ]]; then
    merge="$(create_merge "$base" "$head" "$merge_message" "$commit")"
    jjw rebase -s "$commit" -d "$merge" || die "could not move $commit onto $merge"
  else
    local checkpoint_message checkpoint head_line
    merge="$(create_merge "$base" "$head" "$merge_message" "$head")"
    head_line="$(first_line "$(field "$head" 'description')")"
    checkpoint_message="[tt:${ns}:${task_id}:checkpoint] ${head_line:-$title}"
    checkpoint="$(create_child "$merge" "$checkpoint_message" "$head")"
    jjw rebase -s "$commit" -d "$checkpoint" || die "could not move $commit onto $checkpoint"
  fi
}

# Usage: is_proper_ancestor ANCESTOR DESCENDANT
is_proper_ancestor() {
  [[ "$1" != "$2" && "$(count_revs "(${1}) & ::(${2})")" -gt 0 ]]
}

# Usage: reduce_parents CHANGE_ID MODE
# Drops every parent of a tt merge commit that is an ancestor of another of its
# parents. The descendant parent takes the ancestor's position.
reduce_parents() {
  local commit="$1" mode="$2" line before_id
  local -a parents=() notes=()
  line="$(first_line "$(field "$commit" 'description')")"
  before_id="$(field "$commit" 'commit_id')"
  read -r -a parents <<< "$(field "$commit" 'parents.map(|p| p.commit_id()).join(" ")')"

  local reduced=true i j
  while [[ "$reduced" == true ]]; do
    reduced=false
    for (( i = 0; i < ${#parents[@]}; i++ )); do
      for (( j = 0; j < ${#parents[@]}; j++ )); do
        if is_proper_ancestor "${parents[$i]}" "${parents[$j]}"; then
          notes+=("drop parent ${parents[$i]:0:12}, an ancestor of parent ${parents[$j]:0:12}")
          parents[$i]="${parents[$j]}"
          parents=("${parents[@]:0:$j}" "${parents[@]:$((j + 1))}")
          reduced=true
          break 2
        fi
      done
    done
  done

  if [[ ${#parents[@]} -ne 2 ]]; then
    [[ "$mode" == plan ]] || die "$line has ${#parents[@]} parents after dropping redundant ones"
    log "  skip  $line"
    log "        (has ${#parents[@]} parents after dropping redundant ones)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    return 0
  fi

  FIX_COUNT=$((FIX_COUNT + 1))
  log "  fix   $line"
  for (( i = 0; i < ${#notes[@]}; i++ )); do
    log "        ${notes[$i]}"
  done
  [[ "$mode" == apply ]] || return 0

  jjw rebase -s "$commit" -d "${parents[0]}" -d "${parents[1]}" \
    || die "could not move $commit onto ${parents[0]} and ${parents[1]}"
  [[ "$(field "$commit" 'parents.len()')" -eq 2 ]] \
    || die "$commit does not have 2 parents after dropping redundant ones"
  [[ -z "$(jjr diff --from "$before_id" --to "$commit" --summary)" ]] \
    || die "the tree of $commit changed after dropping redundant parents"
}

reduce_merges() {
  local mode="$1" candidates commit
  candidates="$(jjr log -r "(${ERA_REVSET}) & (${TT_MERGE_OPS_REVSET}) & merges()" --reversed --no-graph \
    -T 'if(parents.len() > 2, change_id ++ "\n", "")')"
  log "Merges with more than 2 parents: $(printf '%s' "$candidates" | grep -c . || true)"
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    reduce_parents "$commit" "$mode"
  done <<< "$candidates"
}

abandon_leftovers() {
  local mode="$1" count
  count="$(count_revs "$LEFTOVER_REVSET")"
  log "Leftover commits to abandon: $count"
  [[ "$count" -gt 0 && "$mode" == apply ]] || return 0
  jjw abandon "$LEFTOVER_REVSET" || die "could not abandon the leftover commits"
}

fix_commits() {
  local mode="$1" candidates commit
  candidates="$(list_ids "(${ERA_REVSET}) & ~roots(${ERA_REVSET}) & (${TT_REVSET}) & ~merges() & ~(${NO_RUN_OPS_REVSET}) \
    & ((${CHECKPOINT_REVSET} & ~empty()) | children(~(${TOOL_REVSET})))")"
  log "Commits to examine: $(printf '%s' "$candidates" | grep -c . || true)"
  while IFS= read -r commit; do
    [[ -n "$commit" ]] || continue
    fix_commit "$commit" "$mode"
  done <<< "$candidates"
  log "Fixed: $FIX_COUNT, skipped: $SKIP_COUNT"
}

# ---------------------------------------------------------------------------
# Convention checks
# ---------------------------------------------------------------------------

# Prints one line per violation; returns 1 when there are any.
check_conventions() {
  local scratch
  scratch="$(mktemp -d)"
  jjr log -r "$TOOL_REVSET" --no-graph -T 'commit_id ++ "\n"' > "$scratch/tool"
  jjr log -r "$LEFTOVER_REVSET" --no-graph -T 'commit_id ++ "\n"' > "$scratch/leftover"
  jjr log -r "$ERA_REVSET" --no-graph -T 'commit_id ++ "\n"' > "$scratch/inrange"
  jjr log -r "(${ERA_REVSET}) & files(~(root:\".tt\" | root-file:\"TASK.md\"))" \
    --no-graph -T 'commit_id ++ "\n"' > "$scratch/data"
  jjr log -r "(${ERA_REVSET}) & files(root:\".tt/task\" | root-file:\"TASK.md\")" \
    --no-graph -T 'commit_id ++ "\n"' > "$scratch/meta"
  jjr log -r "(${ERA_REVSET}) & ~working_copies()" --no-graph \
    -T 'commit_id ++ "\t" ++ parents.map(|p| p.commit_id()).join(" ") ++ "\t" ++ if(empty, "E", "D") ++ "\t" ++ description.first_line() ++ "\n"' \
    > "$scratch/era"
  local status=0
  awk -F '\t' -v legacy="$LEGACY_PATTERN" '
    FILENAME ~ /\/tool$/     { tool[$1] = 1; next }
    FILENAME ~ /\/leftover$/ { leftover[$1] = 1; next }
    FILENAME ~ /\/inrange$/  { inrange[$1] = 1; next }
    FILENAME ~ /\/data$/     { data[$1] = 1; next }
    FILENAME ~ /\/meta$/     { meta[$1] = 1; next }
    {
      n++
      id[n] = $1; nparents[n] = split($2, ps, " ")
      for (i = 1; i <= nparents[n]; i++) parent[n, i] = ps[i]
      empty[n] = ($3 == "E"); line[n] = $4
      op[n] = ""; entity[n] = ""
      if (line[n] ~ /^\[tt:/) {
        tag = line[n]; sub(/^\[tt:/, "", tag); sub(/\].*/, "", tag)
        k = split(tag, parts, ":")
        entity[n] = parts[2]
        op[n] = parts[3]; for (i = 4; i <= k; i++) op[n] = op[n] ":" parts[i]
        if (k < 3) { entity[n] = ""; op[n] = parts[2] }
      }
      oldest[n] = 1
      for (i = 1; i <= nparents[n]; i++) {
        children[parent[n, i]] = children[parent[n, i]] " " n
        if (parent[n, i] in inrange) oldest[n] = 0
      }
    }
    function report(rule, i, reason) {
      printf "%s %s %s: %s\n", rule, substr(id[i], 1, 12), line[i], reason
      bad = 1
    }
    END {
      for (i = 1; i <= n; i++) {
        tt = (line[i] ~ /^\[tt:/)
        is_legacy = (line[i] ~ legacy)
        if (op[i] == "checkpoint") {
          if (!empty[i]) report("R1", i, "checkpoint changes files")
          if (nparents[i] != 1) report("R1", i, "checkpoint has " nparents[i] " parents")
          else if (!(parent[i, 1] in tool)) report("R1", i, "checkpoint sits on a user commit")
        }
        if (op[i] == "merge") {
          if (!empty[i]) report("R2", i, "merge changes files")
          if (nparents[i] != 2) report("R2", i, "merge has " nparents[i] " parents")
          else {
            if (!(parent[i, 1] in tool)) report("R2", i, "first parent is not a tt commit")
            if (parent[i, 2] in tool) report("R2", i, "second parent is a tt commit")
          }
          found = 0
          m = split(children[id[i]], kids, " ")
          for (j = 1; j <= m; j++) {
            c = kids[j]
            if (op[c] == "checkpoint" && entity[c] == entity[i]) found = 1
          }
          if (!found) report("R2", i, "no checkpoint of the same task follows the merge")
        }
        if (tt) {
          if (op[i] ~ /^(merge|checkin|propagate|publish)$/) {
            if (nparents[i] != 2 && op[i] != "merge") report("R3", i, op[i] " has " nparents[i] " parents")
          } else if (nparents[i] != 1) {
            report("R3", i, "has " nparents[i] " parents")
          }
          for (p = 1; p <= nparents[i]; p++) {
            if (parent[i, p] in tool) continue
            if (oldest[i]) continue
            if (op[i] == "merge" && p == 2) continue
            if (op[i] == "new") continue
            if (op[i] == "publish" && p == 1) continue
            if (op[i] == "checkpoint" || op[i] == "merge") continue
            report("R4", i, "parent " p " is a user commit")
          }
          if (id[i] in data) report("R5", i, "tt commit changes project files")
        } else if (!is_legacy && (id[i] in meta)) {
          report("R5", i, "user commit changes task metadata")
        }
        if (id[i] in leftover) report("R6", i, "empty, undescribed commit")
      }
      exit bad
    }
  ' "$scratch/tool" "$scratch/leftover" "$scratch/inrange" "$scratch/data" "$scratch/meta" "$scratch/era" || status=$?
  rm -rf "$scratch"
  return "$status"
}

# ---------------------------------------------------------------------------
# Workspaces and tt history
# ---------------------------------------------------------------------------

STORE=''
CANONICAL=''
CURRENT_WORKSPACE=''
WORKSPACE_NAMES=()
WORKSPACE_ROOTS=()

# Usage: store_of WORKSPACE_ROOT
# Prints the real path of the repository store a workspace uses.
store_of() {
  local root="$1" pointer
  pointer="$root/.jj/repo"
  if [[ -d "$pointer" ]]; then
    (cd "$pointer" && pwd -P)
  elif [[ -f "$pointer" ]]; then
    local target
    target="$(cat "$pointer")"
    [[ "$target" == /* ]] || target="$root/.jj/$target"
    (cd "$target" && pwd -P)
  else
    return 1
  fi
}

resolve_repository() {
  local path="$1"
  REPO="$(jj -R "$path" --ignore-working-copy --no-pager workspace root)" \
    || die "not a jj repository: $path"
  STORE="$(store_of "$REPO")" || die "cannot locate the repository store of $REPO"
  CANONICAL="$(dirname "$(dirname "$STORE")")"
  CURRENT_WORKSPACE="$(jjr workspace list -T 'if(current_workspace, name ++ "\n", "")')"
  [[ -n "$CURRENT_WORKSPACE" ]] || die "cannot tell which workspace $REPO is"
}

# Lists every other workspace and refuses any whose recorded path is missing
# or belongs to a different repository.
collect_workspaces() {
  local name root
  WORKSPACE_NAMES=()
  WORKSPACE_ROOTS=()
  while IFS=$'\t' read -r name root; do
    [[ -n "$name" ]] || continue
    [[ "$name" != "$CURRENT_WORKSPACE" ]] || continue
    [[ -n "$root" && -d "$root" ]] \
      || die "workspace '$name' has no recorded path on disk; forget it or recreate it first"
    [[ "$(store_of "$root" 2>/dev/null || true)" == "$STORE" ]] \
      || die "workspace '$name' records path '$root', which belongs to a different repository; forget it first"
    WORKSPACE_NAMES+=("$name")
    WORKSPACE_ROOTS+=("$root")
  done < <(jjr workspace list -T 'name ++ "\t" ++ if(root, root, "") ++ "\n"')
}

# Usage: ensure_workspace_clean NAME ROOT
ensure_workspace_clean() {
  local name="$1" root="$2" empty
  empty="$(jj -R "$root" --no-pager log -r @ --no-graph -T 'if(empty, "yes", "no")' 2>/dev/null)" \
    || die "workspace '$name' at $root is stale or unreadable; recover it first"
  [[ "$empty" == yes ]] || die "workspace '$name' at $root has uncommitted changes; commit or discard them first"
}

ensure_workspaces_clean() {
  ensure_workspace_clean "$CURRENT_WORKSPACE" "$REPO"
  local i
  for (( i = 0; i < ${#WORKSPACE_NAMES[@]}; i++ )); do
    ensure_workspace_clean "${WORKSPACE_NAMES[$i]}" "${WORKSPACE_ROOTS[$i]}"
  done
}

update_workspaces() {
  jj -R "$REPO" --no-pager --quiet workspace update-stale >/dev/null 2>&1 || true
  local i
  for (( i = 0; i < ${#WORKSPACE_NAMES[@]}; i++ )); do
    jj -R "${WORKSPACE_ROOTS[$i]}" --no-pager --quiet workspace update-stale >/dev/null 2>&1 \
      || log "Warning: could not update workspace '${WORKSPACE_NAMES[$i]}'; run 'jj workspace update-stale' in ${WORKSPACE_ROOTS[$i]}"
  done
}

HISTORY=''
HISTORY_LOCK=''
HISTORY_OPEN=false

take_history_lock() {
  local tries=0
  until mkdir "$HISTORY_LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    [[ "$tries" -lt 50 ]] || die "timed out waiting for the tt history lock: $HISTORY_LOCK"
    sleep 0.1
  done
}

release_history_lock() {
  rmdir "$HISTORY_LOCK" 2>/dev/null || true
}

# Usage: begin_history BEFORE_OP
begin_history() {
  HISTORY="$CANONICAL/.tt/history"
  HISTORY_LOCK="$CANONICAL/.tt/history.lock"
  [[ -f "$HISTORY" ]] || { HISTORY=''; return 0; }
  [[ ! -e "$HISTORY_LOCK" ]] || die "the tt history lock is held: $HISTORY_LOCK"
  take_history_lock
  local last
  last="$(tail -n 1 "$HISTORY")"
  if [[ -n "$last" && "$last" == *: ]]; then
    release_history_lock
    die "a tt command is in progress (incomplete entry in $HISTORY)"
  fi
  printf '%s:\n' "$1" >> "$HISTORY"
  HISTORY_OPEN=true
  release_history_lock
}

# Usage: end_history AFTER_OP   (empty AFTER_OP removes the entry)
end_history() {
  [[ -n "$HISTORY" && "$HISTORY_OPEN" == true ]] || return 0
  take_history_lock
  local scratch
  scratch="$(mktemp)"
  sed '$d' "$HISTORY" > "$scratch"
  if [[ -n "$1" ]]; then
    printf '%s%s\n' "$(tail -n 1 "$HISTORY")" "$1" >> "$scratch"
  fi
  cat "$scratch" > "$HISTORY"
  rm -f "$scratch"
  HISTORY_OPEN=false
  release_history_lock
}

current_operation() {
  jjr op log -n 1 --no-graph -T 'id'
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

# Usage: record_targets FILE
# Records every local bookmark and working copy with its commit ID.
record_targets() {
  {
    jjr bookmark list -T 'if(!remote && present && !conflict, "bookmark\t" ++ name ++ "\t" ++ normal_target.commit_id() ++ "\n", "")'
    jjr workspace list -T '"workspace\t" ++ name ++ "\t" ++ target.commit_id() ++ "\n"'
  } | sort > "$1"
}

# Usage: verify_targets FILE
# Fails when the bookmark or workspace set changed, or any tree differs.
verify_targets() {
  local recorded="$1" now kind name commit rev changes status=0
  now="$(mktemp)"
  record_targets "$now"
  if ! diff <(cut -f1,2 "$recorded") <(cut -f1,2 "$now") >/dev/null; then
    log "Error: the set of bookmarks or workspaces changed"
    status=1
  fi
  while IFS=$'\t' read -r kind name commit; do
    if [[ "$kind" == bookmark ]]; then
      rev="bookmarks(exact:\"${name}\")"
    else
      rev="\"${name}\"@"
    fi
    changes="$(jjr diff --from "$commit" --to "$rev" --summary 2>&1)" || {
      log "Error: cannot compare $kind '$name'"; status=1; continue; }
    if [[ -n "$changes" ]]; then
      log "Error: the tree of $kind '$name' changed:"
      log "$changes"
      status=1
    fi
  done < "$recorded"
  rm -f "$now"
  return "$status"
}

# ---------------------------------------------------------------------------
# Committer timestamps
# ---------------------------------------------------------------------------

# Usage: restore_committer_timestamps BASE_OP
# Gives every visible commit the committer line it had at BASE_OP:
#   - a commit whose change existed at BASE_OP gets that commit's committer line;
#   - a new commit gets the BASE_OP committer line of its source commit: the
#     nearest commit (within three parent or child steps) that existed at
#     BASE_OP and has an identical author line. For a merge, a child
#     checkpoint wins a tie;
#   - a commit with no source gets its own author timestamp.
# jj cannot set committer timestamps, so the phase rewrites the git commit
# objects directly. It changes only committer lines and parent IDs, so change
# IDs, trees, authors and messages are unchanged. It then moves bookmarks and
# working copies onto the rewritten commits and abandons the replaced ones. On
# failure it restores the operation and git refs it started from.
restore_committer_timestamps() {
  python3 - "$REPO" "$1" <<'PY' || die "could not restore committer timestamps"
import collections
import hashlib
import os
import subprocess
import sys
import tempfile

SEP = "\x1f"
ROOT_COMMIT = "0" * 40
TEMP_REF_PREFIX = "migrate-checkpoint-history/"


def log(message):
    print(message, file=sys.stderr, flush=True)


class Failure(Exception):
    pass


def run(args, input_bytes=None):
    result = subprocess.run(args, input=input_bytes, capture_output=True)
    if result.returncode != 0:
        raise Failure(f"command failed: {' '.join(args)}\n{result.stderr.decode(errors='replace')}")
    return result.stdout


class Repo:
    def __init__(self, root):
        self.root = root
        self.git_dir = self.jj("git", "root").strip()

    def jj(self, *args, at_op=None):
        command = ["jj", "-R", self.root, "--ignore-working-copy", "--no-pager"]
        if at_op:
            command += ["--at-op", at_op]
        return run(command + list(args)).decode()

    def jj_write(self, *args, root=None):
        command = ["jj", "-R", root or self.root, "--ignore-working-copy", "--ignore-immutable", "--no-pager", "--quiet"]
        return run(command + list(args)).decode()

    def git(self, *args, input_bytes=None):
        return run(["git", f"--git-dir={self.git_dir}"] + list(args), input_bytes=input_bytes)

    def current_operation(self):
        return self.jj("op", "log", "-n", "1", "--no-graph", "-T", "id").strip()

    def raw_commits(self, commit_ids):
        request = "".join(f"{c}\n" for c in commit_ids).encode()
        out = self.git("cat-file", "--batch", input_bytes=request)
        objects = {}
        pos = 0
        for commit_id in commit_ids:
            header_end = out.index(b"\n", pos)
            oid, kind, size = out[pos:header_end].decode().split()
            if oid != commit_id or kind != "commit":
                raise Failure(f"unexpected object for {commit_id}: {oid} {kind}")
            size = int(size)
            objects[commit_id] = out[header_end + 1:header_end + 1 + size]
            pos = header_end + 1 + size + 1
        return objects


COMMIT_TEMPLATE = (
    'commit_id ++ "\\x1f" ++ change_id ++ "\\x1f" ++ parents.map(|p| p.commit_id()).join(" ") '
    '++ "\\x1f" ++ if(hidden, "hidden", "visible") ++ "\\x1f" ++ description.first_line() ++ "\\n"'
)


def load_visible(repo, at_op=None):
    out = repo.jj("log", "--no-graph", "-r", "::visible_heads()", "-T", COMMIT_TEMPLATE, at_op=at_op)
    commits = {}
    for line in out.splitlines():
        commit_id, change_id, parents, hidden, title = line.split(SEP)
        if hidden != "visible" or commit_id == ROOT_COMMIT:
            continue
        if change_id in commits:
            raise Failure(f"change {change_id} is divergent")
        commits[change_id] = {
            "commit_id": commit_id,
            "change_id": change_id,
            "parents": [p for p in parents.split() if p != ROOT_COMMIT],
            "title": title,
        }
    return commits


def header_line(raw, name):
    for line in raw.split(b"\n\n", 1)[0].split(b"\n"):
        if line.startswith(name + b" "):
            return line
    return None


def ident_and_time(line):
    body = line.split(b" ", 1)[1]
    ident, _, rest = body.rpartition(b"> ")
    return ident + b">", rest


def list_workspaces(repo):
    out = repo.jj("workspace", "list", "-T", 'name ++ "\\x1f" ++ if(root, root, "") ++ "\\x1f" ++ target.commit_id() ++ "\\n"')
    workspaces = []
    for line in out.splitlines():
        name, root, commit_id = line.split(SEP)
        workspaces.append({"name": name, "root": root, "commit_id": commit_id})
    return workspaces


def find_source(change_id, now, base, author_of, children):
    author = author_of[change_id]
    seen = {change_id}
    frontier = [change_id]
    for _ in range(3):
        following = []
        for c in frontier:
            for neighbor in now[c]["parent_changes"] + children[c]:
                if neighbor not in seen:
                    seen.add(neighbor)
                    following.append(neighbor)
        found = [n for n in following if n in base and author_of.get(n) == author]
        if found:
            if len(found) > 1 and len(now[change_id]["parents"]) == 2:
                checkpoints = [n for n in found if n in children[change_id] and ":checkpoint]" in now[n]["title"]]
                if len(checkpoints) == 1:
                    return checkpoints[0], False
            return found[0], len(found) > 1
        frontier = following
    return None, False


def plan(repo, base_op):
    now = load_visible(repo)
    base = load_visible(repo, at_op=base_op)
    by_commit = {c["commit_id"]: c for c in now.values()}
    for commit in now.values():
        commit["parent_changes"] = [by_commit[p]["change_id"] for p in commit["parents"]]
    children = collections.defaultdict(list)
    for commit in now.values():
        for parent in commit["parent_changes"]:
            children[parent].append(commit["change_id"])

    raw_now = repo.raw_commits([c["commit_id"] for c in now.values()])
    raw_base = repo.raw_commits([c["commit_id"] for c in base.values()])
    author_of = {change_id: header_line(raw_now[c["commit_id"]], b"author") for change_id, c in now.items()}

    targets = {}
    stats = collections.Counter()
    for change_id, commit in now.items():
        if change_id in base:
            targets[change_id] = header_line(raw_base[base[change_id]["commit_id"]], b"committer")
            stats["existing"] += 1
            continue
        source, ambiguous = find_source(change_id, now, base, author_of, children)
        if ambiguous:
            raise Failure(f"change {change_id} has several possible source commits")
        if source is not None and author_of[source] != header_line(raw_base[base[source]["commit_id"]], b"author"):
            source = None
        if source is not None:
            targets[change_id] = header_line(raw_base[base[source]["commit_id"]], b"committer")
            stats["new, from source commit"] += 1
        else:
            ident, _ = ident_and_time(header_line(raw_now[commit["commit_id"]], b"committer"))
            _, author_time = ident_and_time(author_of[change_id])
            targets[change_id] = b"committer " + ident + b" " + author_time
            stats["new, from author timestamp"] += 1
    return now, raw_now, targets, stats


def topological(now):
    by_commit = {c["commit_id"]: c for c in now.values()}
    remaining = {c["commit_id"]: len([p for p in c["parents"] if p in by_commit]) for c in now.values()}
    children = collections.defaultdict(list)
    for c in now.values():
        for p in c["parents"]:
            children[p].append(c["commit_id"])
    ready = [cid for cid, count in remaining.items() if count == 0]
    order = []
    while ready:
        cid = ready.pop()
        order.append(cid)
        for child in children[cid]:
            remaining[child] -= 1
            if remaining[child] == 0:
                ready.append(child)
    if len(order) != len(by_commit):
        raise Failure("the commit graph has a cycle")
    return order


def rewrite_objects(now, raw_now, targets):
    by_commit = {c["commit_id"]: c for c in now.values()}
    mapping = {}
    new_objects = {}
    for commit_id in topological(now):
        commit = by_commit[commit_id]
        raw = raw_now[commit_id]
        headers, sep, message = raw.partition(b"\n\n")
        lines = headers.split(b"\n")
        target = targets[commit["change_id"]]
        if target == header_line(raw, b"committer") and not any(p in mapping for p in commit["parents"]):
            continue
        if [l for l in lines if l.startswith(b"change-id ")] != [b"change-id " + commit["change_id"].encode()]:
            raise Failure(f"commit {commit_id} lacks a matching change-id header")
        if any(l.startswith(b"gpgsig") for l in lines):
            raise Failure(f"commit {commit_id} is signed")
        rewritten = []
        for line in lines:
            if line.startswith(b"parent "):
                parent = line[7:].decode()
                rewritten.append(b"parent " + mapping.get(parent, parent).encode())
            elif line.startswith(b"committer "):
                rewritten.append(target)
            else:
                rewritten.append(line)
        new_raw = b"\n".join(rewritten) + sep + message
        new_id = hashlib.sha1(b"commit %d\0" % len(new_raw) + new_raw).hexdigest()
        mapping[commit_id] = new_id
        new_objects[new_id] = new_raw
    return mapping, new_objects


def write_objects(repo, new_objects):
    with tempfile.TemporaryDirectory() as scratch:
        paths = []
        for i, raw in enumerate(new_objects.values()):
            path = os.path.join(scratch, str(i))
            with open(path, "wb") as handle:
                handle.write(raw)
            paths.append(path)
        out = repo.git("hash-object", "-t", "commit", "-w", "--stdin-paths", input_bytes="".join(p + "\n" for p in paths).encode())
        if out.decode().split() != list(new_objects):
            raise Failure("git wrote different object IDs than computed")


def local_bookmarks(repo):
    out = repo.jj("bookmark", "list", "-T", 'if(!remote && present, name ++ "\\x1f" ++ if(conflict, "conflict", normal_target.commit_id()) ++ "\\n", "")')
    bookmarks = {}
    for line in out.splitlines():
        name, target = line.split(SEP)
        if target == "conflict":
            raise Failure(f"bookmark {name} is conflicted")
        bookmarks[name] = target
    return bookmarks


def update_refs(repo, updates):
    """updates: list of (ref, new, old); an empty old creates the ref, an empty new deletes it."""
    if not updates:
        return
    lines = []
    for ref, new, old in updates:
        if new and old:
            lines.append(f"update {ref} {new} {old}")
        elif new:
            lines.append(f"create {ref} {new}")
        else:
            lines.append(f"delete {ref} {old}")
    repo.git("update-ref", "--stdin", input_bytes=("\n".join(lines) + "\n").encode())


def adopt(repo, mapping, bookmarks, workspaces, ref_log):
    visible_heads = repo.jj("log", "--no-graph", "-r", "visible_heads()", "-T", 'commit_id ++ "\\n"').split()
    bookmark_updates = []
    for name, target in bookmarks.items():
        if target in mapping:
            ref = f"refs/heads/{name}"
            actual = repo.git("rev-parse", "--verify", "-q", ref).decode().strip()
            if actual != target:
                raise Failure(f"git ref {ref} is {actual}, but bookmark {name} is {target}")
            bookmark_updates.append((ref, mapping[target], target))
    temp_refs = [(f"refs/heads/{TEMP_REF_PREFIX}{i}", mapping.get(h, h), "") for i, h in enumerate(visible_heads)]
    ref_log.extend(bookmark_updates + temp_refs)
    update_refs(repo, bookmark_updates + temp_refs)

    repo.jj_write("--config", "git.abandon-unreachable-commits=false", "git", "import")

    for ws in workspaces:
        if ws["commit_id"] in mapping:
            repo.jj_write("edit", mapping[ws["commit_id"]], root=ws["root"])

    replaced = "::visible_heads() ~ ::(bookmarks() | working_copies())"
    leftovers = repo.jj("log", "--no-graph", "-r", replaced, "-T", 'commit_id ++ "\\n"').split()
    unexpected = [c for c in leftovers if c not in mapping]
    if unexpected:
        raise Failure(f"{len(unexpected)} visible commits are neither rewritten nor reachable: {unexpected[:5]}")
    if leftovers:
        repo.jj_write("abandon", replaced)
    repo.jj_write("bookmark", "delete", f"glob:{TEMP_REF_PREFIX}*")
    repo.jj_write("git", "export")


def verify(repo, before, mapping, bookmarks, workspaces):
    after = load_visible(repo)
    problems = []
    if set(after) != set(before):
        problems.append(f"visible changes differ: {len(set(before) - set(after))} missing, {len(set(after) - set(before))} added")
    for change_id, commit in before.items():
        expected = mapping.get(commit["commit_id"], commit["commit_id"])
        if change_id in after and after[change_id]["commit_id"] != expected:
            problems.append(f"change {change_id} is {after[change_id]['commit_id']}, expected {expected}")
    now_bookmarks = local_bookmarks(repo)
    if set(now_bookmarks) != set(bookmarks):
        problems.append("the bookmark set changed")
    for name, target in bookmarks.items():
        if now_bookmarks.get(name) != mapping.get(target, target):
            problems.append(f"bookmark {name} is {now_bookmarks.get(name)}, expected {mapping.get(target, target)}")
    for ws in list_workspaces(repo):
        original = next(w for w in workspaces if w["name"] == ws["name"])
        if ws["commit_id"] != mapping.get(original["commit_id"], original["commit_id"]):
            problems.append(f"workspace {ws['name']} is on {ws['commit_id']}")
    if repo.git("for-each-ref", f"refs/heads/{TEMP_REF_PREFIX}").decode().strip():
        problems.append("temporary git branches remain")
    if problems:
        raise Failure("verification failed:\n  " + "\n  ".join(problems[:20]))


def rollback(repo, start_op, ref_log):
    undo = []
    for ref, new, old in ref_log:
        result = subprocess.run(["git", f"--git-dir={repo.git_dir}", "rev-parse", "--verify", "-q", ref], capture_output=True)
        actual = result.stdout.decode().strip()
        if old and actual != old:
            undo.append((ref, old, actual))
        elif not old and actual:
            undo.append((ref, "", actual))
    try:
        update_refs(repo, undo)
    except Failure as error:
        log(f"Error: could not reset git refs: {error}")
    subprocess.run(["jj", "-R", repo.root, "--ignore-working-copy", "--no-pager", "--quiet", "op", "restore", start_op], capture_output=True)


def main(root, base_op):
    repo = Repo(root)
    repo.jj_write("git", "export")
    now, raw_now, targets, stats = plan(repo, base_op)
    mapping, new_objects = rewrite_objects(now, raw_now, targets)
    log("  " + ", ".join(f"{key}: {count}" for key, count in sorted(stats.items())))
    log(f"  commits to rewrite: {len(mapping)}")
    if not mapping:
        return
    start_op = repo.current_operation()
    bookmarks = local_bookmarks(repo)
    workspaces = list_workspaces(repo)
    ref_log = []
    try:
        write_objects(repo, new_objects)
        adopt(repo, mapping, bookmarks, workspaces, ref_log)
        verify(repo, now, mapping, bookmarks, workspaces)
    except BaseException:
        rollback(repo, start_op, ref_log)
        raise


try:
    main(sys.argv[1], sys.argv[2])
except Failure as error:
    log(f"Error: {error}")
    sys.exit(1)
PY
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

BEFORE_OP=''
GIT_REFS=''
ROLLBACK_ARMED=false

# Usage: record_git_refs FILE
# Records every git branch of the backing git repository with its commit ID.
record_git_refs() {
  git --git-dir="$(jjr git root)" for-each-ref --format='%(refname) %(objectname)' refs/heads/ | LC_ALL=C sort > "$1"
}

# Usage: restore_git_refs FILE
# Resets the git branches of the backing git repository to those recorded in
# FILE. jj does not export a restored operation to the git repository of a
# non-colocated workspace, so a rollback resets the branches itself.
restore_git_refs() {
  local recorded="$1" now
  now="$(mktemp)"
  record_git_refs "$now"
  {
    LC_ALL=C join -v 1 "$now" "$recorded" | awk '{ print "delete " $1 }'
    awk '{ print "update " $1 " " $2 }' "$recorded"
  } | git --git-dir="$(jjr git root)" update-ref --stdin
  rm -f "$now"
}

rollback() {
  local status=$?
  [[ "$ROLLBACK_ARMED" == true ]] || exit "$status"
  ROLLBACK_ARMED=false
  trap - EXIT
  log "Restoring operation $BEFORE_OP"
  restore_git_refs "$GIT_REFS" || log "Error: could not reset the git branches recorded in $GIT_REFS"
  if jj -R "$REPO" --no-pager --quiet op restore "$BEFORE_OP" >/dev/null 2>&1; then
    end_history ''
  else
    log "Error: could not restore operation $BEFORE_OP; run 'jj op restore $BEFORE_OP' manually."
  fi
  exit "$(( status == 0 ? 1 : status ))"
}

main() {
  local mode=apply path='.'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) mode=plan; shift ;;
      --check)   mode=check; shift ;;
      -R)
        [[ $# -ge 2 ]] || { usage >&2; exit 1; }
        path="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 1 ;;
    esac
  done

  resolve_repository "$path"
  if [[ "$(count_revs "$TT_TASK_REVSET")" -eq 0 ]]; then
    log "No tt commits found; nothing to do."
    exit 0
  fi
  [[ "$(count_revs "divergent() & (${ERA_REVSET})")" -eq 0 ]] \
    || die "the repository has divergent commits; resolve them first"

  case "$mode" in
    check)
      if check_conventions; then
        log "No violations."
        exit 0
      fi
      exit 1
      ;;
    plan)
      abandon_leftovers plan
      reduce_merges plan
      fix_commits plan
      exit 0
      ;;
  esac

  command -v python3 >/dev/null || die "python3 is required to restore committer timestamps"
  collect_workspaces
  ensure_workspaces_clean

  BEFORE_OP="$(current_operation)"
  local targets
  targets="$(mktemp)"
  record_targets "$targets"
  GIT_REFS="$(mktemp)"
  record_git_refs "$GIT_REFS"

  begin_history "$BEFORE_OP"
  ROLLBACK_ARMED=true
  trap rollback EXIT

  abandon_leftovers apply
  reduce_merges apply
  fix_commits apply

  log "Restoring committer timestamps"
  restore_committer_timestamps "$BEFORE_OP"

  log "Verifying trees"
  verify_targets "$targets" || die "verification failed"
  log "Checking conventions"
  check_conventions || die "convention violations remain"

  update_workspaces

  local after_op
  after_op="$(current_operation)"
  end_history "$after_op"
  ROLLBACK_ARMED=false
  trap - EXIT
  rm -f "$targets" "$GIT_REFS"

  log "Done. Operation before the rewrite: $BEFORE_OP"
  log "Undo with 'tt history undo' or 'jj op restore $BEFORE_OP'."
  log "Bookmarks that were pushed now differ from their remotes and need a force-push."
}

main "$@"
```
