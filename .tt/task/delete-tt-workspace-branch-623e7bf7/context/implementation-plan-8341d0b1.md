---
title: "Implementation Plan"
created: 2026-04-06T16:49:22Z
updated: 2026-04-06T16:49:22Z
---
# Implementation Plan: Delete `tt workspace branch` command

**Task**: Delete the `tt workspace branch` command which provides no value (simply echoes back the provided task-id after validation)

**Status**: Ready for implementation

---

## Phase 1: Research Summary

### Command Overview
The `tt workspace branch <task-id>` command:
- Takes a task or project ID as input
- Validates the ID format
- Verifies the bookmark exists in the repository
- Outputs the task ID to stdout

This is essentially a validation wrapper with no functional value beyond `tt task current`.

### Components to Delete
1. **Command implementation**: `scripts/cli/workspace/branch` (executable bash script)
2. **Test file**: `scripts/cli/workspace/branch.test.sh` (4 test cases)
3. **Alias mapping**: In `scripts/cli/tt` dispatcher
4. **Documentation**: In `DESIGN.md` (section 5.3 + aliases table)

### File Locations
- Command: `/scripts/cli/workspace/branch`
- Tests: `/scripts/cli/workspace/branch.test.sh`
- Dispatcher: `/scripts/cli/tt`
- Design doc: `/DESIGN.md`

---

## Phase 1: User Questions & Responses

### Question 1: Scope
**Q**: What should be the scope of the deletion?
**A**: Delete all components (command, tests, alias, documentation)

### Question 2: Documentation Handling
**Q**: How to handle DESIGN.md references?
**A**: Remove both the command description (section 5.3) and the alias table entry

### Question 3: Test Coverage
**Q**: How to handle the test file?
**A**: Delete the entire test file

### Question 4: VCS Strategy
**Q**: Single commit or multiple commits?
**A**: Single commit removing all components at once

---

## Phase 2: Implementation Plan

### Step 1: Delete Command File
**File**: `scripts/cli/workspace/branch`
**Action**: Remove the file (bash will handle via `rm` during commit)
**Impact**: Command will no longer be available via `tt workspace branch`

### Step 2: Delete Test File
**File**: `scripts/cli/workspace/branch.test.sh`
**Action**: Remove the file
**Impact**: Tests for the command will no longer run

### Step 3: Update Dispatcher Alias
**File**: `scripts/cli/tt`
**Current state**: Contains line `branch) set -- workspace branch "${@:2}" ;;` in the alias resolution section
**Changes needed**:
1. Remove the alias case statement for `branch`
2. Remove `${SCRIPT_NAME} branch → tt workspace branch` from the usage help

### Step 4: Update DESIGN.md
**File**: `/DESIGN.md`

**Location 1**: Section 5.3 (Workspace commands)
- Find and remove the `tt workspace branch` command documentation block:
  ```
  - **`tt workspace branch <task-id> [--repo PATH]`** — Output the branch name...
  ```

**Location 2**: Aliases table (around line 182)
- Find and remove the alias entry:
  ```
  | `tt branch` | `tt workspace branch` |
  ```

### Step 5: Commit
**Commit message**: "Delete `tt workspace branch` command"
**Commit description**: "The `tt workspace branch <task-id>` command effectively echoes back the provided task ID (after validation), providing no real value beyond `tt task current`. Remove the command, tests, alias, and documentation."

---

## Phase 3: Verification Steps

After implementation:
1. ✅ Verify command file is deleted
2. ✅ Verify test file is deleted
3. ✅ Verify alias is removed from dispatcher
4. ✅ Verify DESIGN.md no longer references the command
5. ✅ Run diagnostic checks (no syntax errors)
6. ✅ Review changes in git/jj log

---

## Implementation Checklist

- [ ] Delete `scripts/cli/workspace/branch`
- [ ] Delete `scripts/cli/workspace/branch.test.sh`
- [ ] Remove alias from `scripts/cli/tt`
- [ ] Remove command docs from `DESIGN.md` section 5.3
- [ ] Remove alias entry from `DESIGN.md` aliases table
- [ ] Create commit with message "Delete `tt workspace branch` command"
- [ ] Run diagnostics/verification
- [ ] Summarize changes for user review
