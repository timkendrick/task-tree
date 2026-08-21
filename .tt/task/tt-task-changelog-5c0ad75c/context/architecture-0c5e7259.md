---
title: "Architecture"
created: 2026-08-21T10:47:23Z
updated: 2026-08-21T10:47:23Z
---
# `tt task changelog` — Architecture

Requirements: `.agents/plans/tt-task-changelog.requirements.md` (task context
`context/requirements-e3effbab`).

## Files

| File | Change |
|------|--------|
| `scripts/cli/task/changelog` | New command executable. |
| `scripts/cli/task/changelog.test.sh` | New test suite. |
| `scripts/cli/lib/common.sh` | Two new shared helpers: `parse_commit_message`, `mainline_commit_records`. |
| `scripts/cli/tt` | Register the `tt changelog` alias (dispatch `case` + usage text). |
| `DESIGN.md` | Alias table (§5), command bullet (§5.4), new §6 subsection. |
| `.agents/skills/tt/SKILL.md` | Command reference entry. |

## Load-bearing VCS facts (verified against jj 0.43 in a scratch repo)

- A checkin merge commit has exactly two parents, **in order**: the parent branch's
  mainline tip, then the handoff commit — `jj new "$parent_bookmark" "$handoff_commit"`
  in `scripts/cli/task/checkin`.
- `first_ancestors(x)` (jj ≥ 0.28) traverses **first parents only**, so
  `first_ancestors(<tip>) ~ ::<base>` yields exactly the mainline commits of a scope.
  Verified: on a real branch this returns the checkpoint/checkin chain and omits every
  merged-in arm.
- For a checkin merge `C` with parents `(m, h)`, the work newly merged by `C` is
  `first_ancestors(h) ~ ::m`. Because `m` already contains any earlier partial handoff
  from the same task, repeated (partial → final) checkins never re-report earlier work.
  Verified in the scratch repo: the second checkin's arm contained only the commits
  created after the first partial checkin.
- `tt task propagate --merge` creates a merge whose **first** parent is the child's own
  tip, so a first-parent walk naturally skips work merged in from the parent branch.
- `commit_id` in a git-backed jj repo *is* the git commit hash, so
  `commit_id.short(8)` satisfies the "8-char git SHA, not the jj change ID" requirement.

## New helpers in `lib/common.sh`

```bash
# Usage: parse_commit_message MESSAGE
# Inverse of format_commit_message. Parses a tt commit message of the form
#   [tt:<namespace>:<entity-id>:<operation>] <description>
#   [tt:<namespace>:<operation>] <description>          (no entity id)
# Outputs a single tab-separated record to stdout:
#   <namespace>\t<entity-id>\t<operation>\t<description>
# The operation may itself contain colons (e.g. "context:add"); the entity id
# may not, so a tag with three or more colon-separated fields is read as
# namespace, entity id, and the remaining fields joined as the operation.
# Exit 0: parsed (printed to stdout). Exit 1: not a tt commit message.
parse_commit_message() { ... }
```

```bash
# Usage: mainline_commit_records REPO TIP BASE
# Outputs one record per commit on TIP's first-parent mainline that is not an
# ancestor of BASE, oldest first, tab-separated:
#   <commit-id>\t<change-id>\t<timestamp>\t<parent-ids>\t<description-first-line>
# where <parent-ids> is a space-separated list of full commit IDs and
# <timestamp> is the committer timestamp as ISO 8601 UTC.
mainline_commit_records() {
  local repo="$1" tip="$2" base="$3"
  jj -R "$repo" --ignore-working-copy log \
    -r "first_ancestors($tip) ~ ::$base" --no-graph --reversed \
    -T 'commit_id ++ "\t" ++ change_id ++ "\t"
        ++ committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ") ++ "\t"
        ++ parents.map(|p| p.commit_id()).join(" ") ++ "\t"
        ++ description.first_line() ++ "\n"' 2>/dev/null
}
```

The description is last so that a stray tab in a commit message cannot shift the
structured fields.

## Control flow

```
main
├─ parse args (--task, --since, --repo, --help)
├─ resolve_repo
├─ resolve tip bookmark
│    --task given  → validate is_task_branch || is_project_branch, bookmark exists
│    otherwise     → resolve_current_bookmark  (error if not on a task/project branch)
├─ resolve reference commit
│    --since given → resolve_task_fork_point REPO <since> <tip>
│    otherwise     → find_parent_branch  (error: "pass --since" when absent)
│                    resolve_task_fork_point REPO <parent-bookmark> <tip>
├─ mainline_commit_records REPO <tip> <ref>          # one jj call
│    ├─ [tt:task:<tip>:checkpoint] → checkpoint lines
│    └─ [tt:task:<sub>:checkin]    → depth-0 tree entries
├─ render_entries 0 <records>                        # recursive
└─ emit sections (tree, blank line, checkpoints)
```

`render_entries` is the recursive core:

```bash
# Usage: render_entries REPO TASK_PREFIX PROJECT_PREFIX DEPTH  (records on stdin)
# Prints the rendered tree lines for one scope, recursing into each checkin's arm.
render_entries() {
  # Pass 1 — group checkins by task id, preserving first-seen order
  #   entry_task[i]    task id
  #   entry_commits[i] "<c1> <c2> ..."   chronological checkin commits
  #   entry_arms[i]    "<m1>:<h1> ..."   mainline/handoff parent pairs
  # Pass 2 — for each entry, in first-seen order:
  #   title/status  ← task file at the LAST checkin commit
  #   print line, then recurse with the concatenated arm records of ALL its
  #   checkin commits, so children are deduplicated across partial checkins
}
```

Grouping uses parallel indexed arrays plus a linear `index_of` scan (bash 3.2 has no
associative arrays); scopes hold at most tens of commits.

Recursion terminates because every arm range is disjoint from its ancestors' ranges and
the commit graph is acyclic.

## Entry resolution

```bash
task_file="$(task_file_path "${sub_id#"$task_prefix"}")"
content="$(jj_show_at_revision "$repo" "$checkin_commit" "$task_file")" || content=''
title="$(parse_quoted_frontmatter_field "$content" "title")"
status="$(parse_frontmatter_field "$content" "status")"
```

Line rendering (indent two spaces per depth):

```bash
line="- \`${sub_id}\`"
[[ "$status" == "IN-PROGRESS" ]] && line="$line [IN-PROGRESS]"
[[ -n "$title" ]] && line="$line - $title"
printf '%*s%s\n' "$((depth * 2))" '' "$line"
```

Checkpoint rendering:

```bash
printf -- '- `%s` %s\n' "${commit_id:0:8}" "$message"
```

## Output assembly

Tree lines and checkpoint lines are accumulated into two arrays; nothing is written to
stdout until both are known, so section separators can collapse:

```bash
if tree non-empty:        print tree lines
if both non-empty:        print blank line
if checkpoints non-empty: print checkpoint lines
```

Exit 0 with no output when both are empty. All diagnostics go to stderr.

## Read-only guarantees

No `tt_begin_transaction`, no hooks, no bookmark or working-copy mutation. Every `jj`
invocation passes `--ignore-working-copy` so running the command never snapshots the
working copy.
