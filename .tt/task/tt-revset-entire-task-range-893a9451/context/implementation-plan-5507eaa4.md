---
title: "Implementation Plan"
created: 2026-08-27T11:27:02Z
updated: 2026-08-27T11:27:02Z
---
# Complete task range implementation plan

## Executive summary

Add an opt-in `--all` mode to the bootstrap CLI's task `revset`, `diff`, and `changelog` commands. The mode discovers every connected range attributable to an existing non-project task, including previously checked-in work, current unmerged work, direct task operations, and direct-child lifecycle work. A shared ordered range-record abstraction will ensure that all three commands use identical selection semantics while preserving their existing default behavior.

The implementation will be delivered as one logical feature slice containing shared discovery, all command integrations, tests, and design documentation. Relevant checks will run after each internal change, followed by the complete shell test suite and code review before the slice is checkpointed. The top-level task will remain checked out for user review rather than being checked in automatically.

## 1. Background

The bootstrap CLI currently defines a task's range as the commits reachable from the task branch but not from its current parent branch. This correctly represents unmerged work but stops selecting a component after that work is checked into the parent. Partial check-ins, continued task work, task operations performed on a retained checked-in task, and direct-child lifecycle operations can therefore leave a task's complete history spread across several disconnected parts of the commit graph.

The requested `--all` mode expands task-range selection to the union of those components. Calls without `--all` must retain established behavior, including implicit-task trailing commits, explicit-task bookmark bounds, diff metadata filtering, changelog depth and since options, command aliases, usage errors, and output formatting.

Jujutsu 0.43 can diff a connected multi-root/multi-head revset but rejects a revset containing gaps. The implementation must therefore preserve connected components as ordered records. Revset output can join them as a union, while diff output must process them independently and concatenate their Git-format patches.

## 2. Research

### Canonical references

- Refined requirements: `.agents/plans/tt-revset-entire-task-range-893a9451.requirements.md`
- Canonical requirements context: `context/refined-requirements-2e6916bf`
- Architecture: `.agents/plans/tt-revset-entire-task-range-893a9451.architecture.md`
- Canonical architecture context: `context/complete-range-architecture-8b2f2475`
- Topology refinement: `.agents/plans/tt-revset-entire-task-range-893a9451.topology-range-context.md`
- Canonical topology context: `context/topology-based-complete-range-discovery-214f5912`
- Current task: `task/tt-revset-entire-task-range-893a9451`
- Parent project: `project/bootstrap-cli-d35756ce`

### Production code

- `scripts/cli/lib/common.sh`
  - `parse_commit_message` parses structured `[tt:<namespace>:<entity>:<operation>]` descriptions.
  - `metadata_exclusion_fileset` supplies diff's metadata filter.
  - `find_parent_branch` finds the current task parent from `subtask:` frontmatter.
  - `resolve_task_range` resolves the current parent and upper bound while preserving implicit trailing work.
  - `resolve_task_fork_point` resolves existing endpoint ranges.
  - `mainline_commit_records` walks first-parent records oldest-first.
  - `find_branch_for_task` implements the current-state “where to read” rule.
- `scripts/cli/task/revset`
  - Currently emits `<parent>..<upper-bound>` or one immutable Git endpoint range.
- `scripts/cli/task/diff`
  - Currently diffs the fork point to the upper bound and optionally excludes `.tt/` and `TASK.md`.
- `scripts/cli/task/changelog`
  - Classifies first-parent checkpoint/check-in records, recursively renders incoming check-in arms, groups repeat check-ins, and applies depth limits.
- `scripts/cli/task/checkin`
  - Creates one off-mainline handoff child of the task tip, then a parent-side merge whose first parent is the receiving branch and second parent is the handoff.
- `scripts/cli/task/reorder` and `scripts/cli/task/rename`
  - Demonstrate operations that may be committed to a task's canonical retained location rather than only its own bookmark.
- `scripts/cli/tt`
  - Already maps top-level aliases to canonical task commands; no dedicated completion subsystem exists.

### Tests and documentation

- `scripts/cli/task/revset.test.sh`
- `scripts/cli/task/diff.test.sh`
- `scripts/cli/task/changelog.test.sh`
- `scripts/harness/harness.sh`
- `DEVELOPER.md`
- `DESIGN.md`
  - §6.0 defines branch topology and structured commit descriptions.
  - §6.5 defines handoff/check-in parent ordering.
  - §6.8 defines current unmerged ranges.
  - §6.10 defines rename behavior.
  - §6.14 defines changelog traversal, grouping, and rendering.

### Jujutsu findings

The installed binary is `jj 0.43.0-89f62ede8c1c611eaf134c0c49252efd65c7945d`. Its revset language provides range, union, difference, ancestry, first-parent, root/head, bookmark, and description predicates needed for discovery and validation. `jj diff -r` reports `Cannot diff revsets with gaps in` for a disconnected union; `--from` and `--to` each require one resolved revision. Connected components must consequently remain available independently.

## 3. Decision log

- `--all` is opt-in; default command behavior remains unchanged.
- The complete range contains merged and current unmerged components.
- The feature supports non-project tasks only; published project ranges are out of scope.
- Discovery is bounded by the target task bookmark, its current parent bookmark, and the task creation commit identified from the target task-file path.
- Task move, task rename, deleted-task recovery, and project publish ranges are outside scope.
- Complete-range discovery does not inspect structured commit descriptions.
- Commits modifying the target task file provide metadata and direct-child lifecycle waypoints.
- Check-ins are identified by topology: a symlink-changing one-parent handoff is the second parent of a two-parent receiving merge.
- A root `TASK.md` transition from target to parent identifies a historical target check-in; the wrapper commits are excluded and only the delivered range is retained.
- A root `TASK.md` transition from another task to target identifies a direct-child check-in; its delivered work and receiving merge are retained.
- Ambiguous symlink transitions are ignored without marker-based fallback.
- A direct-child check-in component includes the descendant work delivered by that merge.
- Shared ordered connected-range records are the authoritative model for all three commands.
- Historical endpoints use immutable commit IDs.
- Duplicate candidates are removed; broad task-work components take precedence over narrower covered components.
- Comparable components retain ancestry order; otherwise committer timestamp and commit ID provide deterministic order; current unmerged work is last.
- Jujutsu revset output is a parenthesized union.
- Git-mode revset output is one ordered immutable `<base>..<tip>` range per line.
- Diff output is one chronological Git patch stream produced by concatenating component diffs without headings.
- Changelog reuses its existing presentation and applies `--since` as a complete-range boundary.
- No backward-compatibility layer is needed beyond preserving behavior when `--all` is absent.

## 4. Technical strategy

### 4.1 Scope and authority

Use `context/topology-based-complete-range-discovery-214f5912` as the authoritative refinement of the earlier architecture for range discovery. Support existing non-project tasks with current task and parent bookmarks. Do not add move history, rename history, deleted-task recovery, or project publish-range support.

### 4.2 Native waypoint traversal

Resolve the target task bookmark, current parent bookmark, implicit or explicit upper bound, target task-file path, and creation boundary before discovery. Build one bounded Jujutsu revset covering the task and current parent histories from creation onward.

Within one templated `jj log`, select and return:

- commits modifying the target task file;
- two-parent merge candidates with a parent that changes root `TASK.md`;
- those symlink-changing parent commits.

The template must emit machine-parseable immutable commit IDs, ordered parent IDs, committer timestamps, relevant changed paths, and a framed Git-format diff of root `TASK.md` for symlink-changing commits. The framing must remain unambiguous when descriptions or patches contain tabs and newlines.

### 4.3 Topology-only check-in classification

For each merge candidate, require exactly two parents and require the symlink-changing handoff to be its second parent. Parse the handoff's root `TASK.md` transition:

- target task path to current parent task path: recover a historical target-task component from the merge's first parent to the handoff's parent, excluding the handoff and receiving merge;
- another task path to target task path: recover a direct-child component from the merge's first parent to the receiving merge, including delivered child work;
- absent, conflicting, unrelated, or otherwise ambiguous transition: ignore the candidate.

Do not consult commit descriptions as validation or fallback. Changelog may continue parsing descriptions only after selection because that is its established rendering model.

### 4.4 Connected record normalization

Represent every selected component as an immutable base/tip record with kind, ordering commit, and timestamp. Exclude the task creation boundary. Add the established current unmerged component, preserving implicit trailing work and explicit task bounds.

Deduplicate identical candidates and omit individual target-path waypoints already contained in a broader merged, direct-child, or unmerged component. Preserve ancestry order when comparable; otherwise sort by committer timestamp and immutable commit ID. Place current unmerged work last.

### 4.5 Command integration

Keep each current command path intact when `--all` is absent. Under `--all`:

- `revset` formats connected records as one parenthesized Jujutsu union;
- `revset --git` resolves immutable endpoints and prints one Git range per line;
- `diff` invokes `jj diff -r` for each connected record oldest-first and concatenates Git-format patches without headings, applying the existing metadata fileset to every component;
- `changelog` gathers and deduplicates first-parent records from every component, applies `--since` to the complete selection, then reuses existing grouping, depth, metadata, and rendering behavior.

The top-level aliases already dispatch to the same scripts and require behavioral tests rather than separate implementation.

### 4.6 Verification strategy

Add focused helper scenarios to `scripts/cli/lib/common.test.sh` and command-facing scenarios to the three command-local suites. Cover:

- unchanged default behavior;
- one and multiple historical check-ins plus current unmerged work;
- repeated partial check-ins whose receiving checkbox is unchanged;
- direct-child create, check-in, and delete operations;
- target metadata operations after check-in;
- unrelated merges and ambiguous symlink candidates;
- exclusion of target creation, handoff, and receiving merge wrappers;
- exclusion of unrelated intervening parent work;
- revset union validity and Git range lines;
- ordered diff patches and metadata filtering;
- changelog grouping, depth, ordering, and `--since`;
- canonical and alias help/flag behavior.

After each internal code change, run `bash -n` for changed shell scripts and the narrowest relevant test filter. Before checkpointing the implementation slice, run configured ShellCheck diagnostics if available, the four directly affected suites, `scripts/test --parallel`, and the mandatory code-review skill. Resolve every introduced failure before completion.

### 4.7 Delivery

Implement shared discovery, all three command integrations, tests, and `DESIGN.md` as one logical implementation slice. Checkpoint only after the complete slice passes required diagnostics and review. Do not check in the top-level task; leave it available for user inspection.

## 5. Implementation details

### 5.1 Implement the full feature as one atomic slice

This is the only implementation step and therefore the only feature checkpoint described by this plan. Complete all substeps below, keep the working copy on the current top-level task, and create the checkpoint only after every required check succeeds.

#### 5.1.1 Centralize task range context resolution

Modify `scripts/cli/lib/common.sh` to add a verb-led helper that resolves the task ID as well as the existing range endpoints:

```bash
# Usage: get_task_range_context REPO [TASK_ID]
# Output: <task-id>\t<parent-bookmark>\t<upper-bound>
get_task_range_context()
```

Preserve `resolve_task_range REPO [TASK_ID]` as the existing two-field interface. Implement it as a compatibility wrapper over `get_task_range_context` so current callers and default command output remain unchanged.

`get_task_range_context` must preserve:

- implicit current task/project resolution and established errors;
- explicit bookmark validation;
- implicit `@` upper bound for a non-empty working copy;
- implicit `@-` upper bound for an empty working copy;
- explicit task bookmark as upper bound;
- current parent discovery and multiple-parent errors;
- rejection of parentless project branches for this task-range feature.

Run `bash -n scripts/cli/lib/common.sh` and the existing range-related `common.test.sh` scenarios immediately after this refactor. Do not continue until existing behavior passes.

#### 5.1.2 Add full-range discovery helpers

Add the public shared helper:

```bash
# Usage: get_full_task_range_records REPO TASK_ID PARENT_BOOKMARK UPPER_BOUND
# Output, oldest first:
#   <base-id>\t<tip-id>\t<kind>\t<ordering-id>\t<timestamp>
get_full_task_range_records()
```

Use “full” rather than “complete” in the function name to avoid confusion with a task's `DONE`/completed lifecycle state.

Extract small verb-led private helpers below their call sites for:

- building the bounded waypoint revset;
- reading NUL-delimited waypoint records;
- locating records by immutable commit ID using indexed arrays compatible with macOS Bash;
- parsing a root-`TASK.md` symlink transition;
- adding a candidate connected component;
- testing whether components are empty or covered;
- ordering final records through Jujutsu.

Do not use associative arrays, non-portable Bash features, commit descriptions, or type-like global state.

##### Resolve immutable inputs and creation boundary

Resolve the target task bookmark, current parent bookmark, and upper bound to immutable commit IDs before constructing revsets. Derive the target file with `task_file_path` from the configured task prefix.

Within the ancestry of the target and parent heads, identify the unique root commit selected by the target task-file path:

```text
roots(files(root-file:".tt/task/<target-suffix>/TASK.md") & ::(target | parent))
```

Treat this as the task creation boundary. Fail through a clear range-resolution error if it cannot be resolved uniquely. Exclude the boundary itself from every output component.

##### Query waypoints once

Build a bounded history from the creation boundary to the target/parent heads. Within that history select the union of:

- commits modifying the target task file;
- two-parent merge candidates that have a parent modifying root `TASK.md`;
- the root-`TASK.md`-modifying parents of those merge candidates.

Use one `jj log --reversed --no-graph` call for this waypoint union. Its template must emit NUL-delimited records so multiline patches cannot corrupt record framing. Each record must contain:

- immutable commit ID;
- ordered parent commit IDs;
- committer timestamp;
- a boolean indicating whether the target task file changed;
- the Git-format result of `self.diff("root-file:\"TASK.md\"").git()`.

Consume the stream directly with `read -d ''`; never store the NUL-delimited stream in command substitution.

##### Classify check-in topology

For every candidate merge record:

1. Require exactly two ordered parents.
2. Locate the second parent's waypoint record.
3. Require that second parent to have exactly one parent.
4. Parse exactly one removed and one added symlink target from its root `TASK.md` patch, excluding Git patch headers.
5. Compare those targets with the target and current-parent task-file paths.

Classify without descriptions:

- target → parent: add a historical target component from the merge's first parent to the handoff's parent; do not include the handoff or merge wrapper;
- another task → target: add a direct-child component from the merge's first parent to the merge commit, including the delivered child range;
- missing, unchanged, conflicting, unrelated, or otherwise ambiguous transition: ignore it silently.

##### Add path and current components

For each single-parent waypoint that modifies the target task file, add a one-commit component from its parent to itself unless it is the creation boundary. These records capture retained task metadata operations and direct-child create/delete operations. Ignore unclassified multi-parent target-path changes.

Add the current unmerged component from the current parent to the resolved upper bound, preserving implicit trailing and working-copy changes. Omit components whose revsets are empty.

##### Deduplicate and order

Broad historical, direct-child, and current-unmerged components take precedence over one-commit path waypoints. Build one union of broad components and use a batched Jujutsu membership query to remove covered one-commit records. Deduplicate repeated component endpoints and ordering commits.

Use one reversed Jujutsu log over historical ordering commits to obtain graph-aware deterministic order rather than implementing graph traversal in Bash. Retain timestamp and immutable ID as deterministic metadata for otherwise incomparable records. Append the current unmerged component last.

Run `bash -n scripts/cli/lib/common.sh` and focused new helper tests after completing discovery.

#### 5.1.3 Test shared discovery

Extend `scripts/cli/lib/common.test.sh`. Use fresh harness repositories and public helper output rather than testing private parsing functions in isolation. Add scenarios for:

- unique creation boundary and creation exclusion;
- target → parent symlink transition and wrapper exclusion;
- child → target transition and delivered child range inclusion;
- one partial check-in followed by more unmerged work;
- repeated partial check-ins where the receiving checkbox does not change;
- multiple historical components separated by unrelated parent work;
- target task-file operations after check-in;
- direct-child create and delete waypoints;
- unrelated ordinary merges;
- merge candidates whose symlink-changing commit is not their second parent;
- missing, conflicting, and ambiguous symlink transitions;
- broad-component coverage of path waypoints;
- duplicate discovery through shared ancestry;
- implicit trailing work and current component ordering;
- project, missing task, missing parent, and non-unique creation-boundary errors.

Assertions must evaluate emitted revsets against immutable commit IDs, proving both inclusion of expected commits and exclusion of wrappers/intervening commits. Do not assert only textual formatting when graph membership is the behavior under test.

Run:

```bash
scripts/test lib/common --filter 'full.task.range|task.range.context'
```

Adjust the filter to the final test labels while keeping it narrowly scoped.

#### 5.1.4 Integrate `tt revset --all`

Modify `scripts/cli/task/revset`:

- add `--all` parsing and usage text;
- obtain task, parent, and upper bound through `get_task_range_context`;
- retain the current implementation unchanged when `--all` is false;
- call `get_full_task_range_records` when `--all` is true;
- format each record as `(<base-id>..<tip-id>)` and join records with ` | ` for Jujutsu output;
- in `--all --git` mode, resolve each immutable endpoint's Git commit ID and print one `<base>..<tip>` range per line in record order;
- preserve existing errors and stdout/stderr separation.

Extend `scripts/cli/task/revset.test.sh` for default compatibility, one and multiple merged ranges, current unmerged inclusion, unrelated exclusion, union validity, Git range lines, explicit/implicit task behavior, alias behavior, help text, and invalid arguments.

Run `bash -n` on the command and `scripts/test task/revset`.

#### 5.1.5 Integrate `tt diff --all`

Modify `scripts/cli/task/diff`:

- add `--all` parsing and usage text;
- retain the current endpoint diff unchanged when `--all` is false;
- iterate full-range records oldest-first when enabled;
- invoke `jj diff -r '<base-id>..<tip-id>' --git` once per connected component;
- apply `metadata_exclusion_fileset` to every invocation unless `--include-metadata` is set;
- concatenate patches without headings or separators;
- produce no output when every component has no visible file change.

Extend `scripts/cli/task/diff.test.sh` for merged plus unmerged files, multiple historical components, repeated file sections in ordered patch output, unrelated parent exclusion, implicit trailing changes, metadata filtering in every component, explicit task behavior, alias behavior, help, and errors.

Run `bash -n` on the command and `scripts/test task/diff`.

#### 5.1.6 Integrate `tt changelog --all`

Modify `scripts/cli/task/changelog` and, if necessary, the shared `mainline_commit_records` helper:

- add `--all` parsing and usage text;
- preserve the current reference/fork-point path when `--all` is false;
- validate an explicit `--since` revision before full-range collection;
- gather first-parent records independently from each full-range component;
- when `--since` is present, exclude top-level records reachable from that revision;
- deduplicate records by immutable commit ID before rendering;
- reuse existing `record_operation_fields`, checkpoint collection, `render_entries`, recursive child-arm traversal, grouping, metadata lookup, ordering, and depth behavior.

Range discovery remains description-independent. Existing changelog rendering continues parsing descriptions because structured labels define that command's current output semantics.

Extend `scripts/cli/task/changelog.test.sh` for historical and current checkpoints, repeat check-in grouping across components, direct-child tree entries, depth limits, first-occurrence/latest-metadata behavior, `--since` before/between/after components, aliases, help, malformed options, and silent empty output.

Run `bash -n` on the command and `scripts/test task/changelog`.

#### 5.1.7 Update `DESIGN.md`

Document the implemented current state without references to planning history:

- add `--all` to the three command signatures and descriptions;
- define canonical task and current-parent VCS references used for range discovery;
- define target task-file creation boundary and direct path waypoints;
- define handoff symlink transitions and ordered merge parents;
- explain target check-in versus direct-child check-in classification;
- define historical, direct-child, path-operation, and current-unmerged components;
- explain wrapper exclusion, component deduplication, ordering, and discontiguous union formatting;
- explain Git multi-range and ordered diff-stream output;
- explain changelog `--since` filtering;
- state that project ranges, deleted-task recovery, task move history, task rename history, and ambiguous symlink transitions are unsupported.

Follow `.agents/rules/markdown-style.mdc`: describe only current behavior and do not copy implementation bodies verbatim.

#### 5.1.8 Run diagnostics and review

Run syntax checks on every changed shell file:

```bash
bash -n scripts/cli/lib/common.sh
bash -n scripts/cli/task/revset
bash -n scripts/cli/task/diff
bash -n scripts/cli/task/changelog
bash -n scripts/cli/lib/common.test.sh
bash -n scripts/cli/task/revset.test.sh
bash -n scripts/cli/task/diff.test.sh
bash -n scripts/cli/task/changelog.test.sh
```

If `shellcheck` is available, run it on all changed shell files and resolve introduced diagnostics. Then run affected suites together:

```bash
scripts/test lib/common task/revset task/diff task/changelog
```

Run the full suite according to `DEVELOPER.md`:

```bash
scripts/test --parallel
```

Use the `code-review` skill, fix every confirmed issue, and rerun the narrowest affected checks followed by the combined affected suites. If a review fix can influence unrelated commands or shared helpers, rerun the full parallel suite.

Inspect `jj diff`, ensure only intended source/tests/documentation/task metadata are present, then create the single feature checkpoint with a behavior-focused message. Do not complete or check in the top-level task without user approval.
