---
title: "Implementation Plan"
created: 2026-04-07T10:17:23Z
updated: 2026-04-07T10:17:23Z
---
# Plan: Add `tt history unlock` CLI Command

## Overview

Add a `tt history unlock [--force] [--repo PATH]` command that resolves a broken history state left by a crashed mid-transaction `tt` process. Unlike `tt history undo --force` (which reverts the jj repo to the pre-transaction state), `unlock --force` simply marks the in-progress transaction as complete by writing `<before-op-id>:<current-op-id>` (using the current jj operation ID as the after-op-id), leaving the jj repository state untouched.

---

## Background / Research Findings

### Transaction format (`scripts/cli/lib/common.sh`)

`.tt/history` contains one line per completed transaction:
```
<before-op-id>:<after-op-id>
```

An **in-progress** (stale) transaction has an empty `after-op-id`:
```
<before-op-id>:
```

### Existing stale-lock detection (`tt_begin_transaction` in `common.sh`)

When a new transaction is started and the last line of `.tt/history` has an empty after-op-id, the command aborts with:

```
Error: Another tt command is in progress (incomplete transaction).
  If this is stale (e.g. a crashed process), run: tt history undo --force
```

This message needs to be updated to mention `tt history unlock --force` as well.

### `tt history undo --force` with in-progress transactions

When `undo --force` encounters an in-progress entry, it:
1. Reverts the jj repo to `<before-op-id>` via `jj op restore`
2. Removes the in-progress line from history

`unlock --force` is **different**: it does NOT revert the jj repo — it simply "completes" the transaction entry by writing `<before-op-id>:<before-op-id>`. This is appropriate when the process crashed but the repo is actually in an acceptable state (or in the identical state it was before the command ran) and the user just wants to unblock future `tt` commands.

### Dispatch mechanism (`scripts/cli/tt`)

The `tt` dispatcher resolves commands by walking `scripts/cli/<command>/<subcommand>/<...>/<executable>`. Adding `scripts/cli/history/unlock` (an executable bash script) is sufficient for `tt history unlock` to work. No changes to the dispatcher are needed.

### Tests

Tests live alongside commands in `scripts/cli/` as `*.test.sh` files. The test harness is at `scripts/harness/harness.sh`. Tests follow the pattern in `scripts/cli/history/undo.test.sh`.

There is no existing harness helper to inject an in-progress transaction, so tests will set it up manually (append `<before-op-id>:` to `.tt/history` directly).

---

## Decision Log

| Decision | Choice | Rationale |
|---|---|---|
| Overlap with `undo --force` | Keep both; no cross-mention in undo's help text | They serve different purposes: undo reverts, unlock just unblocks |
| No in-progress transaction | Silent exit 0 | Clean, scriptable |
| Empty history file | Silent exit 0 | Indistinguishable from "no in-progress transaction" |
| Missing history file | Exit 1 with error message | File should always exist if the workspace was properly initialized |
| Stale message update | Mention both `undo --force` AND `unlock --force` | Users need to know both options exist |

---

## User Q&A Transcript

**Q1: How should `tt history unlock` relate to `tt history undo` for in-progress transactions?**  
Selected: Keep both: `undo --force` continues to revert, `unlock --force` just clears the lock. **Don't mention `unlock` in `undo`'s help text.**

**Q2: When `tt history unlock` is called with no in-progress transaction, what should happen?**  
Selected: Be completely **silent** and exit 0.

**Q3: What should `tt history unlock` do when `.tt/history` is empty or missing?**  
Custom: If empty → **silently exit 0**. If missing → **exit with an error message**.

**Q4: Should the stale message in `tt_begin_transaction` be changed?**  
Selected: Mention both — add a second line: `  Or to keep the current state and just unlock: tt history unlock --force`

---

## Files to Create / Modify

| File | Action | Description |
|---|---|---|
| `scripts/cli/history/unlock` | **Create** | New command executable |
| `scripts/cli/history/unlock.test.sh` | **Create** | Test suite for the new command |
| `scripts/cli/lib/common.sh` | **Modify** | Add `get_jj_op_id` helper; update `tt_begin_transaction` stale message; replace inline jj op retrieval with helper |
| `scripts/cli/history/undo` | **Modify** | Replace 3 inline jj op retrievals with `get_jj_op_id` helper |
| `DESIGN.md` | **Modify** | Document new command in §5.2 History and §6.12.3 |

---

## Detailed Implementation

### 1. `scripts/cli/history/unlock`

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

# tt history unlock — clear a stale in-progress transaction from .tt/history
#                     WITHOUT reverting the jj repository state.
#
# Usage:
#   tt history unlock [--force] [--repo PATH]
#
# Options:
#   --force   Required if the history is mid-transaction. Without it, exits 1.
#   --repo    Repository root (overrides TT_REPO; default: walk up from CWD to find .jj).
#
# If there is no in-progress transaction, exits silently with code 0 (no-op).
# If the history file does not exist, exits 1 with an error message.
# If the history file is empty, exits silently with code 0 (no-op).
#
# When --force is given and there is an in-progress transaction, the last history
# line is completed by writing the current jj operation ID as the after-op-id, producing:
#   <before-op-id>:<current-op-id>
# This leaves the jj repository state unchanged.

readonly SCRIPT_NAME="${0##*/}"

usage() {
  cat <<EOF
Usage: tt history unlock [--force] [--repo PATH]

Clear a stale in-progress transaction from .tt/history without reverting
the jj repository. Use this when a tt process crashed mid-transaction and
the repository is already in an acceptable state.

If there is no in-progress transaction, this command exits 0 silently (no-op).

To revert the repository to the state before the crashed command instead,
use: tt history undo --force

Options:
  --force   Required to clear an in-progress transaction. Without it,
            exits 1 if the history is mid-transaction.
  --repo    Repository root (overrides TT_REPO; default: walk up from CWD to find .jj).

Examples:
  tt history unlock           # check for stale lock (no-op if clean)
  tt history unlock --force   # clear stale in-progress transaction

EOF
}

main() {
  local force=false
  local repo=''

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)
        force=true
        shift
        ;;
      --repo)
        [[ $# -lt 2 ]] && { usage >&2; exit 1; }
        repo="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        usage >&2; exit 1
        ;;
      *)
        usage >&2; exit 1
        ;;
    esac
  done

  repo="$(resolve_repo "$repo")"

  local history_file="$repo/.tt/history"

  # History file must exist (workspace must be initialized)
  if [[ ! -f "$history_file" ]]; then
    log "Error: History file not found: $history_file"
    log "  Has the workspace been initialized? Run: tt workspace init"
    exit 1
  fi

  # Empty history → nothing to unlock
  if [[ ! -s "$history_file" ]]; then
    exit 0
  fi

  # Read last line
  local last_line
  last_line="$(tail -n 1 "$history_file")"
  if [[ -z "$last_line" ]]; then
    exit 0
  fi

  local before_op after_op
  before_op="${last_line%%:*}"
  after_op="${last_line#*:}"

  # No in-progress transaction → silent no-op
  if [[ -n "$after_op" ]]; then
    exit 0
  fi

  # In-progress transaction detected
  if [[ "$force" != true ]]; then
    log "Error: In-progress transaction detected."
    log "  before-op: ${before_op:0:12}..."
    log "  This may indicate a crashed or killed tt process."
    log "  Use --force to clear the lock (keeps current jj state)."
    log "  Use 'tt history undo --force' to revert to the pre-transaction state."
    exit 1
  fi

  # --force: complete the transaction entry by writing the current jj op as after-op
  local current_op
  current_op="$(get_jj_op_id "$repo")" || {
    log "Error: Could not read current jj operation ID."
    exit 1
  }

  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "$ s|^${before_op}:\$|${before_op}:${current_op}|" "$history_file"
  else
    sed -i "$ s|^${before_op}:\$|${before_op}:${current_op}|" "$history_file"
  fi

  log "Unlocked: in-progress transaction cleared (history marked complete)."
  log "  jj repository state is unchanged."
  log "  Transaction entry: ${before_op:0:12}:${current_op:0:12}..."
}

main "$@"
```

**Must be marked executable:** `chmod +x scripts/cli/history/unlock`

---

### 2. `scripts/cli/history/unlock.test.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../harness/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../harness/harness.sh"


# Helper: inject a stale (in-progress) transaction entry into .tt/history
inject_pending_transaction() {
  local before_op
  before_op="$(get_jj_op_id "$REPO")"
  printf '%s:\n' "$before_op" >> "$REPO/.tt/history"
  printf '%s' "$before_op"
}


test_history_unlock__no_transaction_is_silent_noop() {
  setup_workspace "unlock-noop"
  create_project "proj" "Project" >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt history unlock 2>&1) || exit_code=$?
  assert_success "unlock succeeds" "$exit_code"
  assert_output_empty "unlock is silent" "$output"
  assert_no_pending_transaction "no pending transaction after unlock"
}


test_history_unlock__no_transaction_with_force_is_silent_noop() {
  setup_workspace "unlock-noop-force"
  create_project "proj" "Project" >/dev/null 2>&1

  output="" exit_code=0
  output=$(run_tt history unlock --force 2>&1) || exit_code=$?
  assert_success "unlock --force succeeds" "$exit_code"
  assert_output_empty "unlock --force is silent when no lock" "$output"
}


test_history_unlock__empty_history_is_silent_noop() {
  setup_workspace "unlock-empty"
  # No commands run: history file is empty

  output="" exit_code=0
  output=$(run_tt history unlock 2>&1) || exit_code=$?
  assert_success "unlock exits 0 on empty history" "$exit_code"
  assert_output_empty "unlock is silent on empty history" "$output"
}


test_history_unlock__missing_history_exits_error() {
  setup_workspace "unlock-missing"
  rm -f "$REPO/.tt/history"

  output="" exit_code=0
  output=$(run_tt history unlock 2>&1) || exit_code=$?
  assert_failure "unlock exits 1 on missing history" "$exit_code"
  assert_contains "error message mentions history file" "$output" "History file not found"
}


test_history_unlock__in_progress_without_force_exits_error() {
  setup_workspace "unlock-no-force"
  create_project "proj" "Project" >/dev/null 2>&1
  inject_pending_transaction >/dev/null

  output="" exit_code=0
  output=$(run_tt history unlock 2>&1) || exit_code=$?
  assert_failure "unlock exits 1 without --force" "$exit_code"
  assert_contains "error mentions --force" "$output" "--force"
  assert_contains "error mentions undo" "$output" "tt history undo --force"
}


test_history_unlock__force_clears_pending_transaction() {
  setup_workspace "unlock-force"
  create_project "proj" "Project" >/dev/null 2>&1
  inject_pending_transaction >/dev/null

  output="" exit_code=0
  output=$(run_tt history unlock --force 2>&1) || exit_code=$?
  assert_success "unlock --force succeeds" "$exit_code"
  assert_no_pending_transaction "no pending transaction after unlock --force"
}


test_history_unlock__force_sets_after_to_current_op() {
  setup_workspace "unlock-entry"
  create_project "proj" "Project" >/dev/null 2>&1
  local before_op
  before_op="$(inject_pending_transaction)"

  # Capture the current jj op ID (which unlock --force will use as after-op)
  local current_op
  current_op="$(get_jj_op_id "$REPO")"

  run_tt history unlock --force >/dev/null 2>&1

  # Read the last history line and verify before preserved, after == current jj op
  get_history_lines
  local last_line="${HISTORY_LINES[${#HISTORY_LINES[@]}-1]}"
  local entry_before entry_after
  entry_before="$(history_before_op "$last_line")"
  entry_after="$(history_after_op "$last_line")"
  assert_eq "before-op preserved" "$entry_before" "$before_op"
  assert_eq "after-op equals current jj op" "$entry_after" "$current_op"
}


test_history_unlock__force_unblocks_subsequent_commands() {
  setup_workspace "unlock-unblock"
  inject_pending_transaction >/dev/null

  run_tt history unlock --force >/dev/null 2>&1

  # A subsequent tt command should be able to start a new transaction
  output="" exit_code=0
  output=$(run_tt task create --slug "new" --title "New Task" <<< "" 2>&1) || exit_code=$?
  assert_success "subsequent command succeeds after unlock" "$exit_code"
}


test_history_unlock__jj_state_unchanged_after_force() {
  setup_workspace "unlock-jj-unchanged"
  local before_jj_op
  before_jj_op="$(get_jj_op_id "$REPO")"

  create_project "proj" "Project" >/dev/null 2>&1

  local after_create_op
  after_create_op="$(get_jj_op_id "$REPO")"

  inject_pending_transaction >/dev/null

  run_tt history unlock --force >/dev/null 2>&1

  local current_op
  current_op="$(get_jj_op_id "$REPO")"
  assert_eq "jj state unchanged after unlock" "$current_op" "$after_create_op"
}


test_history_unlock__help() {
  setup_workspace "unlock-help"
  output="" exit_code=0
  output=$(run_tt history unlock --help 2>&1) || exit_code=$?
  assert_success "exit code" "$exit_code"
  assert_usage_command_name "command name" "$output" "tt history unlock"
  assert_required_usage_argument "argument: --force" "$output" "--force"
  assert_required_usage_argument "argument: --repo" "$output" "--repo"
}


run_tests "tt history unlock"
```

---

### 3. `scripts/cli/lib/common.sh` — add `get_jj_op_id` helper and update call sites

#### 3a. Add `get_jj_op_id` helper

Add this function to `common.sh` in the VCS file-read helpers section (near `jj_show_at_revision` and `jj_show_at_op`), before the transaction management section:

```bash
# Usage: get_jj_op_id REPO
# Prints the current jj operation ID to stdout.
# Returns 1 if the operation ID cannot be read.
get_jj_op_id() {
  local repo="$1"
  jj -R "$repo" op log --no-graph -T id -n 1 2>/dev/null
}
```

#### 3b. Replace call sites in `common.sh`

In `tt_begin_transaction` (replaces `jj -R "$repo" op log --no-graph -T id -n 1 2>/dev/null`):
```bash
  before_op="$(get_jj_op_id "$repo")" || {
```

In `tt_commit_transaction` (replaces `jj -R "$repo" op log --no-graph -T id -n 1 2>/dev/null`):
```bash
  after_op="$(get_jj_op_id "$repo")" || {
```

#### 3c. Replace call sites in `scripts/cli/history/undo`

Three inline calls replaced with `get_jj_op_id "$repo"`:
- Line ~126 (op ID mismatch check): `current_op="$(get_jj_op_id "$repo")" || {`
- Line ~156 (pre-undo safety trap): `pre_undo_op="$(get_jj_op_id "$repo")" || pre_undo_op=""`
- Line ~182 (patch previous entry): `new_current_op="$(get_jj_op_id "$repo")" || true`

#### 3d. Update stale-lock message in `tt_begin_transaction`

In `tt_begin_transaction`, change:

```bash
      if [[ -z "$last_after" ]]; then
        log "Error: Another tt command is in progress (incomplete transaction)."
        log "  If this is stale (e.g. a crashed process), run: tt history undo --force"
        exit 1
      fi
```

To:

```bash
      if [[ -z "$last_after" ]]; then
        log "Error: Another tt command is in progress (incomplete transaction)."
        log "  To revert a crashed process, run: tt history undo --force"
        log "  Or to keep the current state: tt history unlock --force"
        exit 1
      fi
```

---

### 5. `DESIGN.md` — Documentation updates

#### 5a. §5.2 History — add `unlock` entry after the `undo` entry

After the `tt history undo` block (line ~215), add:

```markdown
- **`tt history unlock [--force] [--repo PATH]`** — Clear a stale in-progress transaction from `.tt/history` without reverting the jj repository state. Use this when a `tt` process crashed mid-transaction and the jj repository is already in an acceptable state.

  - If there is no in-progress transaction: exits 0 silently (no-op).
  - If the history file is empty: exits 0 silently (no-op).
  - If the history file does not exist: exits 1 with an error message.
  - If there is an in-progress transaction and `--force` is not given: exits 1 with a message.
  - With `--force`: completes the transaction entry by writing `<before-op-id>:<current-op-id>` (where `<current-op-id>` is the current jj operation ID) — this marks the history as clean without changing the jj repository state.

  **Contrast with `tt history undo --force`:** `undo --force` reverts the jj repository to the state before the crashed command ran. Use `unlock --force` when you want to keep the current jj state and just unblock future `tt` commands.

  See §6.12 for the full transaction history mechanism.
```

#### 5b. §6.12 "Stale transactions" paragraph — mention `unlock`

Update the "Running `tt history undo --force` reverts..." sentence and the error message block:

```
Error: Another tt command is in progress (incomplete transaction).
  To revert a crashed process, run: tt history undo --force
  Or to keep the current state: tt history unlock --force
```

Add after the existing "Running `tt history undo --force` reverts..." sentence:

```
Alternatively, `tt history unlock --force` clears the lock without reverting the repository state — use this when the jj repository is already in an acceptable state and you simply want to unblock future `tt` commands.
```

#### 5c. §6.12.3 — add a `tt history unlock` subsection after the `undo` section

Add a new `#### 6.12.4 \`tt history unlock\` command` section:

```markdown
#### 6.12.4 `tt history unlock` command

`tt history unlock [--force] [--repo PATH]` clears a stale in-progress transaction from `.tt/history` without reverting the jj repository state.

**Behavior:**

1. If the history file does not exist: exit 1 with an error message.
2. If the history file is empty or the last entry has a non-empty `<after-op-id>`: exit 0 silently (no-op).
3. If the last entry has an empty `<after-op-id>` (in-progress) and `--force` is not given: exit 1 with a message directing the user to use `--force` or `tt history undo --force`.
4. With `--force` and an in-progress entry: capture the current jj operation ID and replace the last line `<before-op-id>:` with `<before-op-id>:<current-op-id>`. The jj repository state is **not** modified.

**Result:** The transaction entry's `<after-op-id>` reflects the actual current jj operation, accurately representing the state of the repository at the time the lock was cleared. Future `tt_begin_transaction` calls will no longer see an in-progress entry and will start normally.

**`tt history unlock` is not itself transactional:** The unlock command does not write a new transaction entry to `.tt/history`. It only modifies the existing in-progress entry.
```

---

## Task List

- [ ] Create VCS commit before starting (jj new)
- [ ] Add `get_jj_op_id REPO` helper to `scripts/cli/lib/common.sh`
- [ ] Replace 2 inline jj op retrievals in `common.sh` (`tt_begin_transaction`, `tt_commit_transaction`) with `get_jj_op_id`
- [ ] Replace 3 inline jj op retrievals in `scripts/cli/history/undo` with `get_jj_op_id`
- [ ] Update stale-lock message in `tt_begin_transaction` (add `unlock --force` line)
- [ ] Create `scripts/cli/history/unlock` (executable bash script) — uses `get_jj_op_id`
- [ ] Mark it executable: `chmod +x scripts/cli/history/unlock`
- [ ] Create `scripts/cli/history/unlock.test.sh`
- [ ] Update `DESIGN.md`: §5.2 add unlock entry
- [ ] Update `DESIGN.md`: §6.12 stale transactions paragraph
- [ ] Update `DESIGN.md`: add §6.12.4 unlock command documentation
- [ ] Run tests: `scripts/test history/unlock`
- [ ] Run undo tests to confirm no regression: `scripts/test history/undo`
- [ ] Fix any test failures
- [ ] Commit all changes
