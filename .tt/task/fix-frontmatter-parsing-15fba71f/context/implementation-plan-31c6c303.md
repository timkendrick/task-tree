---
title: "Implementation Plan"
created: 2026-08-06T15:03:49Z
updated: 2026-08-06T15:03:49Z
---
# Plan: Fix unbounded frontmatter parsing (`in_fm` toggle bug)

**Status:** Awaiting approval
**Scope:** `scripts/cli/lib/common.sh`, `scripts/cli/task/{tree,propagate,delete,complete,checkin}`, plus test suites

---

## 1. Problem statement

`tt task tree` renders one task with an unknown-status checkbox and no title:

```
- [?] [task/frontmatter-label-ordering-252d77b0](.tt/task/frontmatter-label-ordering-252d77b0/TASK.md) (no title)
```

despite that task's `TASK.md` being present, readable, and well-formed on every relevant branch:

```
$ jj --ignore-working-copy file show -r project/bootstrap-cli-d35756ce \
    -- 'root:.tt/task/frontmatter-label-ordering-252d77b0/TASK.md' | head -8
---
title: "Insert frontmatter labels in correct position"
status: DONE
created: 2026-04-24T07:36:46Z
updated: 2026-04-26T15:22:09Z
context: context/implementation-plan-c6c98cce
context: context/rollback-operation-id-bae68e35
---
```

### 1.1 Root cause

`parse_frontmatter()` in `scripts/cli/task/tree` (line 59) **toggles** an in-frontmatter flag on
every `---` line rather than bounding itself to the leading block:

```awk
/^---$/ { in_fm = !in_fm; next }
in_fm && /^title:[ \t]*/  { ... }
in_fm && /^status:[ \t]*/ { ... }
in_fm && /^subtask:[ \t]*\[[ x\-]\]/ { ... }
```

The body of that task documents the desired frontmatter layout inside a fenced code block:

````markdown
The correct order should be:

```markdown
---
title:
status:
created:
...
````

The `---` inside the fence flips `in_fm` back on, so the parser emits a **second**, empty
`title:` and `status:`:

```
$ parse_frontmatter "$content"
title:Insert frontmatter labels in correct position
status:DONE
title:                 <- from the body code fence
status:                <- from the body code fence
```

`get_metadata_from_content` (tree:118-127) assigns with a last-wins loop, so `title` becomes `''`
(rendered `(no title)`) and `status` becomes `''`, which `status_to_checkbox` maps to `[?]`
(`scripts/cli/lib/common.sh:968-976`).

### 1.2 Blast radius

The same unbounded-toggle idiom appears in **6 awk blocks across 5 files**. Two of them
**write the parsed result back to disk**, so a body line such as `subtask: [x] task/foo`
appearing after a stray `---` can silently corrupt a real task file:

| File | Line | Fields read | Writes result back? |
|---|---|---|---|
| `scripts/cli/task/tree` | 62 | `title`, `status`, `subtask` | no |
| `scripts/cli/task/propagate` | 125 | `subtask` | no |
| `scripts/cli/task/delete` | 85 | `subtask` | no |
| `scripts/cli/task/delete` | 99 | `subtask` | no |
| `scripts/cli/task/delete` | 290 | `subtask` | **yes** |
| `scripts/cli/task/complete` | 149 | `subtask` | no |
| `scripts/cli/task/checkin` | 402 | `subtask` | **yes** |

Task files currently in the repository that contain more than two `---` lines, i.e. that can
trigger the bug today:

- `.tt/task/frontmatter-label-ordering-252d77b0/TASK.md` (4)
- `.tt/task/tt-task-prompt-6060d454/TASK.md` (4)
- `.tt/task/tt-task-prompt-message-f4594828/TASK.md` (3)
- `.tt/task/tt-task-select-configurable-ui-249bd4cb/TASK.md` (5)

### 1.3 What is already safe

Everything in `scripts/cli/lib/common.sh` uses a **counting** idiom
(`/^---$/ { n++; ... }` combined with `n == 1` guards and/or `if (n == 2) exit`), which is immune
to the bug because once `n >= 3` the `n == 1` guard is permanently false. Safe sites include:

- `parse_frontmatter_field` (common.sh:450)
- `parse_body` (common.sh:203)
- `parse_task_frontmatter` (common.sh:1066-1100)
- `_insert_frontmatter_line` (common.sh:1196)
- `update_frontmatter_timestamp` (common.sh:1240)
- `collect_descendant_task_dirs`'s inline awk (common.sh:1045)
- `scripts/cli/task/show`, `scripts/cli/task/prompt`, `scripts/cli/task/context/*`

`scripts/cli/task/tree` is the **only** command that duplicates title/status/subtask parsing
instead of reusing `common.sh`.

---

## 2. Out of scope

This plan fixes **only** the parser bug. Two other defects were identified during investigation
and are explicitly **not** addressed here:

1. **Legacy flat task-file paths.** Tasks created before the `.tt/task/<slug>.md` →
   `.tt/task/<slug>/TASK.md` migration still have bookmarks whose commits contain only the old
   flat path, e.g. `jj file list -r task/tt-task-list-focus-f23d4002` shows
   `.tt/task/tt-task-list-focus-f23d4002.md`. Roughly 30 tasks are affected.
2. **`--focus` builds an incomplete merged map.** `scripts/cli/task/tree` focus mode calls
   `build_merged_map` with only the ancestor chain, so siblings and children rendered under the
   chain fall back to their own bookmark. Combined with (1) this produces the `(no title)` / `[ ]`
   rows seen only under `--focus`; the non-focus listing renders the same tasks correctly because
   `collect_task_ids` feeds every reachable ID into `build_merged_map`.

---

## 3. Design

### 3.1 Measurements that drove the design

| Operation | Measured cost |
|---|---|
| One `printf \| awk` pipeline over a 32-line task file | ~4.6 ms |
| One `jj --ignore-working-copy file show` | ~57 ms |
| Full `tt tree` on this repo (135 rendered nodes) | ~15.5 s |
| 200x `parse_frontmatter_field` via the new wrapper | 1.166 s (~5.8 ms each) |

`tt tree` is dominated by `build_merged_map`'s O(tasks x branches) `jj` invocations, but node
count multiplies every per-node cost. There are **38 call sites** of
`parse_frontmatter_field` / `parse_quoted_frontmatter_field` across the codebase, so the shared
helper must not add a process per call.

Decision: a **single variadic awk pass** (`parse_frontmatter_fields`) with **pure-bash wrappers**
(no `sed`/`head` forks) for the single-value and repeated-value cases. This is DRY *and* strictly
faster than today, because `parse_quoted_frontmatter_field` currently costs awk + sed (~9 ms) and
will now cost one awk (~5.8 ms).

### 3.2 New/changed helpers in `scripts/cli/lib/common.sh`

All three have been prototyped and verified against this machine's BSD awk (macOS).

```bash
# Usage: parse_frontmatter_fields CONTENT FIELD...
# Extracts the requested frontmatter fields in a single pass, preserving file
# order. Emits one "FIELD:VALUE" line per matching frontmatter entry, with the
# key's leading whitespace stripped from VALUE but quotes preserved.
#
# The frontmatter block is strictly the leading delimited block: CONTENT must
# begin with a '---' line, and parsing stops at the closing '---'. Any '---'
# lines appearing later (e.g. inside a fenced code block in the body) are
# ignored, so body content can never be mistaken for frontmatter.
parse_frontmatter_fields() {
  local content="$1"; shift
  printf '%s' "$content" | awk -v fields="$*" '
    BEGIN { n = split(fields, f, " "); for (i = 1; i <= n; i++) want[f[i]] = 1 }
    NR == 1 && $0 != "---" { exit }
    /^---$/ { sep++; if (sep == 2) exit; next }
    sep == 1 {
      key = $0
      if (sub(/:.*$/, "", key) == 0) next
      if (key in want) {
        val = $0
        sub("^" key ":[ \t]*", "", val)
        print key ":" val
      }
    }
  '
}

# Usage: parse_frontmatter_field CONTENT FIELD
# Extracts the raw value of a single-valued frontmatter field, preserving any
# quotes present in the original. If the field appears more than once, the
# first occurrence wins. Outputs nothing if the field is absent.
parse_frontmatter_field() {
  local out first
  out="$(parse_frontmatter_fields "$1" "$2")"
  [[ -z "$out" ]] && return 0
  first="${out%%$'\n'*}"
  printf '%s' "${first#"$2:"}"
}

# Usage: parse_quoted_frontmatter_field CONTENT FIELD
# As parse_frontmatter_field, but strips a matched pair of surrounding
# double quotes from the value.
parse_quoted_frontmatter_field() {
  local value
  value="$(parse_frontmatter_field "$1" "$2")"
  if [[ "$value" == \"*\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  fi
  printf '%s' "$value"
}

# Usage: parse_repeated_frontmatter_field CONTENT FIELD
# Extracts every value of a repeatable frontmatter field (label, context,
# subtask), one per line, in file order. Outputs nothing if absent.
parse_repeated_frontmatter_field() {
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line#"$2:"}"
  done < <(parse_frontmatter_fields "$1" "$2")
}
```

**Behavioural notes / verified edge cases:**

- `NR == 1 && $0 != "---" { exit }` implements the "must start with a delimiter" rule. Verified
  that **every** `.tt/task/*/TASK.md` and `.tt/task/*/context/*.md` in this repo starts with `---`,
  so no existing file regresses.
- Colons inside values are safe: `title: "A: colon"` yields key `title`, value `"A: colon"`.
- Lines with no colon are skipped (`sub(/:.*$/, "", key) == 0`).
- A prefix-collision key such as `titlefoo: x` does **not** match a request for `title`
  (equivalent to the old `$0 ~ "^" field ":"` anchoring).
- Empty `CONTENT` produces empty output and exit status 0.
- `parse_quoted_frontmatter_field` previously used `sed 's/^"\(.*\)"$/\1/'`, which only strips a
  matched leading+trailing pair. The bash replacement preserves that semantic exactly.

### 3.3 `parse_task_frontmatter` refactor

`common.sh:1078-1086` contains three near-identical inline awk blocks for `label:`, `context:`
and `subtask:`. Replace them with calls to the new helper:

```bash
  PARSED_LABELS=()
  while IFS= read -r lbl; do [[ -n "$lbl" ]] && PARSED_LABELS+=("$lbl"); done \
    < <(parse_repeated_frontmatter_field "$content" "label")

  PARSED_CONTEXTS=()
  while IFS= read -r ctx; do [[ -n "$ctx" ]] && PARSED_CONTEXTS+=("$ctx"); done \
    < <(parse_repeated_frontmatter_field "$content" "context")

  PARSED_SUBTASKS=()
  while IFS= read -r st; do [[ -n "$st" ]] && PARSED_SUBTASKS+=("$st"); done \
    < <(parse_repeated_frontmatter_field "$content" "subtask")
```

The unknown-key rejection block (common.sh:1090-1100) is left as-is; it enumerates keys rather
than extracting named ones, so it does not fit the helper's signature. It already uses the safe
counting idiom, but add the `NR == 1 && $0 != "---" { exit }` guard for consistency with the new
delimiter rule.

### 3.4 `scripts/cli/task/tree`

Delete the local `parse_frontmatter()` (lines 53-101) entirely.

`get_metadata_from_content` becomes a **single** `parse_frontmatter_fields` pass covering both
fields, with first-wins semantics and `[?]` for a missing status:

```bash
# Get checkbox and title from content string.
get_metadata_from_content() {
  local content="$1"

  local title='' status='' line
  while IFS= read -r line; do
    case "$line" in
      title:*)  [[ -z "$title"  ]] && title="${line#title:}" ;;
      status:*) [[ -z "$status" ]] && status="${line#status:}" ;;
    esac
  done < <(parse_frontmatter_fields "$content" title status)

  # Strip a matched pair of surrounding double quotes from the title.
  if [[ "$title" == \"*\" ]]; then
    title="${title#\"}"
    title="${title%\"}"
  fi
  title="${title#"${title%%[![:space:]]*}"}"
  title="${title%"${title##*[![:space:]]}"}"
  [[ -z "$title" ]] && title='(no title)'

  printf '%s|%s' "$(status_to_checkbox "$status")" "$title"
}
```

Note the removal of the now-unused `task_id`, `merged_branch`, `all_branches` and `repo`
parameters — they were accepted but never referenced. Update the single call site (tree:213-215):

```bash
  meta="$(get_metadata_from_content "$content")"
```

`get_subtask_entries` (tree:131-149) currently re-parses the `subtask:` output that
`parse_frontmatter` had already reformatted into `CHECKBOX ID TITLE`. It now consumes raw values
of the form `[x] task/foo-abc12345 Some title` directly:

```bash
# Usage: get_subtask_entries CONTENT
# Outputs one line per subtask: CHECKBOX|TASK_ID|TITLE
get_subtask_entries() {
  local content="$1"
  parse_repeated_frontmatter_field "$content" "subtask" | awk '
    /^\[[ x\-]\]/ {
      cb = substr($0, 1, 3)
      rest = substr($0, 4)
      sub(/^[ \t]+/, "", rest)
      id = rest
      sub(/[ \t].*$/, "", id)
      title = rest
      sub(/^[^ \t]+[ \t]*/, "", title)
      if (title == "") title = "(no title)"
      print cb "|" id "|" title
    }
  '
}
```

The `/^\[[ x\-]\]/` guard preserves the old behaviour of ignoring malformed `subtask:` entries
that lack a checkbox.

### 3.5 Status rendering change

Per the decision log, a task file with **no parseable `status:`** now renders `[?]` rather than
`[ ]`. Previously `get_metadata_from_content` initialised `status='TODO'`. Verified that every
`.tt/task/*/TASK.md` in this repo has a `status:` field, so no currently-valid task changes
appearance. Unreadable or missing task files (e.g. the legacy-path tasks described in section 2)
will now render `[?]` instead of masquerading as open work — this is the intended improvement, and
it means fixing this bug also makes defect (1) from section 2 visually obvious rather than silent.

### 3.6 Remaining toggle sites

Replace each `in_fm` block with the shared helper.

**`scripts/cli/task/propagate` (lines 119-131)** — `get_subtask_ids`:

```bash
get_subtask_ids() {
  local repo="$1" bookmark="$2" task_file="$3"
  local content
  content="$(jj_show_at_revision "$repo" "$bookmark" "$task_file")" || true
  [[ -z "$content" ]] && return 0
  parse_repeated_frontmatter_field "$content" "subtask" | awk '
    /^\[[ x\-]\]/ { sub(/^\[[ x\-]\][ \t]*/, ""); if ($1 != "") print $1 }
  '
}
```

**`scripts/cli/task/delete` (lines 80-105)** — both the `own_subs` and `parent_subs` blocks use
identical logic. Extract a local helper in that script and call it twice:

```bash
# Usage: _subtask_ids_from_content CONTENT
# Outputs one subtask task ID per line.
_subtask_ids_from_content() {
  [[ -z "$1" ]] && return 0
  parse_repeated_frontmatter_field "$1" "subtask" | awk '
    /^\[[ x\-]\]/ { sub(/^\[[ x\-]\][ \t]*/, ""); if ($1 != "") print $1 }
  '
}
```

then

```bash
    own_subs="$(_subtask_ids_from_content "$own_content")" || true
    ...
    parent_subs="$(_subtask_ids_from_content "$parent_content")" || true
```

**`scripts/cli/task/complete` (lines 147-152)** — incomplete-subtask precondition:

```bash
    incomplete_subs="$(parse_repeated_frontmatter_field "$task_content" "subtask" \
      | awk '/^\[[ \-]\]/ { print "subtask: " $0 }')" || true
```

Note: the old code printed the whole original line (`subtask: [ ] task/foo`) for the error
message; the helper strips the `subtask:` key, so re-prefix it to keep the user-facing error text
identical.

**`scripts/cli/task/delete` (lines 288-299) and `scripts/cli/task/checkin` (lines 401-413)** —
these **rewrite** the parent file and must preserve every non-matching line verbatim, so they
cannot use the extract-only helper. Convert them to the bounded counting idiom in place:

```awk
# delete: remove this task's subtask entry from the parent frontmatter
BEGIN { sep = 0 }
NR == 1 && $0 != "---" { print; done = 1 }
!done && /^---$/ { sep++; print; next }
!done && sep == 1 && /^subtask:/ {
  rest = $0
  sub(/^subtask:[[:space:]]*\[[[:space:]x\-]\][[:space:]]*/, "", rest)
  split(rest, parts, /[[:space:]]/)
  if (parts[1] == id) next
}
{ print }
```

Simpler and equivalent, given every task file is known to start with `---`: drop the `done`
machinery and rely on the `sep == 1` guard alone, which is already immune to extra `---` lines:

```awk
BEGIN { sep = 0 }
/^---$/ { sep++; print; next }
sep == 1 && /^subtask:/ {
  rest = $0
  sub(/^subtask:[[:space:]]*\[[[:space:]x\-]\][[:space:]]*/, "", rest)
  split(rest, parts, /[[:space:]]/)
  if (parts[1] == id) next
}
{ print }
```

Apply the identical `sep`-counting transformation to `checkin`'s rewrite block, keeping its
`cb` substitution logic unchanged:

```awk
BEGIN { sep = 0 }
/^---$/ { sep++; print; next }
sep == 1 && /^subtask:[[:space:]]*\[[ \-x]\]/ {
  rest = $0
  sub(/^subtask:[[:space:]]*\[[[:space:]\-x]\][[:space:]]*/, "", rest)
  split(rest, parts, /[[:space:]]/)
  if (parts[1] == id) {
    sub(/\[[ \-x]\]/, cb)
  }
  print; next
}
{ print }
```

---

## 4. Testing

Test harness usage is documented in `DEVELOPER.md`. Relevant commands:

```bash
scripts/test lib/common                 # unit tests for the helpers
scripts/test task/tree                  # tree suite
scripts/test --parallel                 # full suite (slow; use a RAM disk)
RAMDISK=$(scripts/ramdisk create) && TT_TEST_ROOT=$RAMDISK scripts/test --parallel; \
  scripts/ramdisk destroy $RAMDISK
```

### 4.1 New unit tests in `scripts/cli/lib/common.test.sh`

This suite already exists and unit-tests the frontmatter awk helpers directly against temp files
(see its `_make_task_file` helper). Add tests for:

1. `parse_frontmatter_fields` returns only leading-block entries when the body contains a fenced
   code block with `---`, `title:` and `status:` lines (**the regression test for this bug**).
2. `parse_frontmatter_fields` with multiple requested fields returns them in file order.
3. `parse_frontmatter_fields` returns nothing when the first line is not `---`.
4. `parse_frontmatter_field` returns the **first** occurrence when a key is duplicated within the
   frontmatter.
5. `parse_frontmatter_field` preserves quotes; `parse_quoted_frontmatter_field` strips a matched
   pair and leaves unmatched quotes alone.
6. `parse_frontmatter_field` handles a value containing a colon (`title: "A: colon"`).
7. `parse_repeated_frontmatter_field` returns all `subtask:` values in order, and nothing for an
   absent key.
8. `parse_task_frontmatter` populates `PARSED_SUBTASKS` / `PARSED_CONTEXTS` / `PARSED_LABELS`
   correctly for a file whose body contains a `---` fence.

### 4.2 New scenario tests

- **`scripts/cli/task/tree.test.sh`** — add `test_task_tree__body_with_frontmatter_fence`:
  create a task whose body contains a fenced `---`/`title:`/`status:` block, mark it DONE, and
  assert the tree row shows `[x]` and the real title. The suite has 7 existing tests
  (`test_task_tree__basic_tree_output` etc.) to model the setup on.
- **`scripts/cli/task/checkin.test.sh`** — add a test that checks in a child whose **parent's**
  body contains a `subtask:` line inside a `---` fence, and asserts that body line is byte-for-byte
  unchanged after checkin while the real frontmatter entry flips to `[x]`.
- **`scripts/cli/task/delete.test.sh`** — the equivalent test for `delete`'s parent-file rewrite.
- **`scripts/cli/task/complete.test.sh`** — a task whose body contains `subtask: [ ] task/fake`
  inside a fence must still complete without `--force`.
- **`scripts/cli/task/propagate.test.sh`** — a parent whose body contains a fenced `subtask:` line
  must not attempt to propagate to the non-existent task ID.

### 4.3 Manual verification

```bash
./scripts/cli/tt tree | grep frontmatter-label-ordering-252d77b0
# expect: - [x] [task/frontmatter-label-ordering-252d77b0](...) Insert frontmatter labels in correct position
```

Also confirm the other three multi-`---` task files render correctly:
`tt-task-prompt-6060d454`, `tt-task-prompt-message-f4594828`,
`tt-task-select-configurable-ui-249bd4cb`.

---

## 5. Task list

- [ ] Create a `tt` checkpoint / VCS commit before starting (per `AGENTS.md`).
- [ ] Add `parse_frontmatter_fields` to `scripts/cli/lib/common.sh` (section 3.2).
- [ ] Rewrite `parse_frontmatter_field` and `parse_quoted_frontmatter_field` as pure-bash wrappers.
- [ ] Add `parse_repeated_frontmatter_field`.
- [ ] Refactor `parse_task_frontmatter`'s three inline awks onto the helper; add the leading-
      delimiter guard to its unknown-key block (section 3.3).
- [ ] Commit.
- [ ] `scripts/cli/task/tree`: delete local `parse_frontmatter`, rewrite
      `get_metadata_from_content` (drop unused params, first-wins, `[?]` default) and
      `get_subtask_entries`; update the call site at tree:213-215 (section 3.4).
- [ ] Commit.
- [ ] `scripts/cli/task/propagate`: rewrite `get_subtask_ids` (section 3.6).
- [ ] `scripts/cli/task/delete`: add `_subtask_ids_from_content`, replace both read blocks, and
      convert the parent-rewrite awk to `sep` counting.
- [ ] `scripts/cli/task/complete`: rewrite the incomplete-subtask precondition, preserving the
      exact error text.
- [ ] `scripts/cli/task/checkin`: convert the parent-rewrite awk to `sep` counting.
- [ ] Verify no `in_fm` occurrences remain: `grep -rn 'in_fm' scripts/` returns nothing.
- [ ] Commit.
- [ ] Add unit tests to `scripts/cli/lib/common.test.sh` (section 4.1).
- [ ] Add scenario tests to the five command suites (section 4.2).
- [ ] Run `scripts/test lib/common task/tree task/checkin task/delete task/complete task/propagate`.
- [ ] Run the full suite in parallel on a RAM disk; confirm no regressions.
- [ ] Manual verification per section 4.3.
- [ ] Run `shellcheck` on every modified script.
- [ ] Commit.
- [ ] Update `DESIGN.md` if the `[?]` status-rendering change is user-facing documentation.

---

## 6. Decision log

| # | Decision | Rationale |
|---|---|---|
| 1 | Fix all 6 toggle sites via a shared helper in `common.sh`, not just `tree` | Two sites write parsed results back to disk and can corrupt task files; a shared helper also removes duplication |
| 2 | Single variadic `parse_frontmatter_fields` pass, with pure-bash wrappers | Per-field decomposition would take `tree` from 2 to 4-5 processes per node across 135 nodes (~+5% on a 15.5 s command) and would add a process to each of 38 existing call sites. Bash wrappers add zero forks |
| 3 | Frontmatter must begin at line 1 with `---`; a non-delimiter first line means "no frontmatter" | Strictest rule, matches what tt itself writes; verified every existing task and context file complies |
| 4 | Duplicate keys: **first** occurrence wins | Matches the existing `parse_frontmatter_field` semantics (it printed and exited on first match); keeps all commands consistent |
| 5 | Missing/unparseable `status:` renders `[?]`, not `[ ]` | Distinguishes "no status field" from "status: TODO" so unreadable task files are visible rather than silently looking like open work. No existing task file is affected |
| 6 | `parse_task_frontmatter` refactored onto the helper | Its `label:`/`context:`/`subtask:` extraction is three near-identical inline awks; not buggy, but duplicated |
| 7 | The two write-back sites use bounded `sep` counting in place rather than the extract helper | They must preserve every non-matching line verbatim, which an extract-only helper cannot do |
| 8 | Legacy flat task paths and the `--focus` merged-map bug are out of scope | Separate defects with separate fixes; tracked in section 2 |

---

## 7. Questionnaire transcript

**Q: How wide should the fix go?**
Options: *All 6 sites, shared helper in common.sh (Recommended)* / All 6 toggle sites, fixed in
place / `scripts/cli/task/tree` only.
**A:** All 6 sites, shared helper in `common.sh`.

**Q: For `scripts/cli/task/tree`, should its local `parse_frontmatter` be replaced by common.sh
helpers entirely?**
Options: Keep local parser, make it bounded (Recommended) / Reuse `parse_frontmatter_field` +
subtask helper / Reuse `parse_task_frontmatter` wholesale.
**A:** *"let's discuss in more detail - I imagine small passes looking for specific named fields
and returning early would be quick? maybe combine with a new parse_repeated_frontmatter_field for
'zero-or-more' fields such as `subtask:`?"*

**Q (follow-up, with measurements): Given ~4.6ms per awk pass and 135 nodes in `tt tree`, which
shared-helper shape do you prefer?**
Options: *Variadic multi-field extractor (Recommended)* / Per-field helpers only / Raw
frontmatter-lines extractor.
**A:** Variadic multi-field extractor.

**Q: Should `parse_task_frontmatter` in common.sh also be refactored onto the new helper?**
Options: *Yes, replace its 3 inline awks (Recommended)* / No, leave it alone.
**A:** Yes, replace its 3 inline awks.

**Q: What should count as the frontmatter block?**
Options: *Require file to start with a delimiter (Recommended)* / Tolerate a non-delimiter first
line.
**A:** Require file to start with a delimiter.

**Q: If `title:` or `status:` appears twice inside the real frontmatter block, which wins?**
Options: *First occurrence (Recommended)* / Last occurrence.
**A:** First occurrence.

**Q: How should a task file with no parseable `status:` render in `tt tree`?**
Options: Keep current default of TODO / `[ ]` (Recommended) / *Render as `[?]` unknown*.
**A:** Render as `[?]` unknown.

---

## 8. Reference: verified prototype output

Run against the real offending file and synthetic edge cases on macOS BSD awk:

```
--- real file (--- / title: / status: inside body fence):
title:"Insert frontmatter labels in correct position"
status:DONE
context:context/implementation-plan-c6c98cce
context:context/rollback-operation-id-bae68e35

--- no leading delimiter:
(empty)

--- empty content:
(empty)

--- duplicate keys + colon in value + body fence:
title:"A: colon"
subtask:[x] task/a-1 Title A
subtask:[ ] task/b-2
title:SECOND

--- wrappers:
field(title)=["A: colon"]
quoted(title)=[A: colon]
field(status)=[DONE]
field(missing)=[]
repeated(subtask):
[x] task/a-1 Title A
[ ] task/b-2
repeated(none):[]
```

---

## 9. Style constraints

Per `.agents/rules/bash-style.mdc` (applies to all shell code in this repo):

- Shebang `#!/usr/bin/env bash`, `set -euo pipefail` in scripts (not in sourced `common.sh`).
- Diagnostics to stderr via `log()`; script output to stdout.
- Propagate errors in compound commands.
- Extract reusable subroutines into DRY helper functions — this plan's core motivation.
- Every new helper gets a `# Usage: ...` comment block matching the existing `common.sh` style.
