---
title: "Fix broken pipe error in `tt sync` output"
status: IN-PROGRESS
created: 2026-10-02T11:19:28Z
updated: 2026-10-02T11:19:28Z
---
`tt sync` output consistently shows the following errors when attempting to log the added files:

```
$ tt sync
+ jj -R /Users/tkendrick/Sites/grfn/project/griffin-b908105a rebase -s zouoqswwwxsmknzxwxzytkoptsrmkrvv -d b640a6b69bec89545175a63bcd46997d0d503f62
Rebased 1 commits to destination
Working copy  (@) now at: zouoqsww 15f7b9e9 (empty) (no description set)
Parent commit (@-)      : yqzrooov b640a6b6 project/griffin-b908105a* | (empty) [tt:task:task/eu-gas-default-latest-pre-3am-f70893ee:checkin] Change EU Gas Default schedule hack to use latest pre-3AM run
Added 0 files, modified 19 files, removed 0 files
Synced /Users/tkendrick/Sites/grfn/project/griffin-b908105a (project/griffin-b908105a)
  3f73a7a78caf → b640a6b69bec
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh: line 1115: printf: write error: Broken pipe
  - .tt/task/eu-gas-default-latest-pre-3am-f70893ee/TASK.md
  - .tt/task/griffin-b908105a/TASK.md
  - packages/ui/src/apis/dataHubConfig/dataHubConfigApi.ts
  - packages/ui/src/editors/dataHub.mock.ts
  - packages/ui/src/editors/InputFormFieldBalanceReportsEditor/InputFormFieldBalanceReportsEditor.stories.tsx
  - packages/ui/src/editors/InputFormFieldBalanceReportsEditor/InputFormFieldBalanceReportsEditor.test.tsx
  - packages/ui/src/editors/InputFormFieldDataHubMultiWorkspaceHistorySchedulesEditor/InputFormFieldDataHubMultiWorkspaceHistorySchedulesEditor.test.tsx
  - packages/ui/src/editors/InputFormFieldDataHubWorkspaceHistorySchedulesEditor/InputFormFieldDataHubWorkspaceHistorySchedulesEditor.stories.tsx
  - packages/ui/src/editors/InputFormFieldDataHubWorkspaceHistorySchedulesEditor/InputFormFieldDataHubWorkspaceHistorySchedulesEditor.test.tsx
  - packages/ui/src/editors/InputFormFieldGluelakeRunScheduleEditor/InputFormFieldGluelakeRunScheduleEditor.stories.tsx
  - packages/ui/src/editors/InputFormFieldGluelakeRunScheduleEditor/InputFormFieldGluelakeRunScheduleEditor.test.tsx
  - packages/ui/src/editors/InputFormFieldPulseDataDomainEditor/InputFormFieldPulseDataDomainEditor.stories.tsx
  - packages/ui/src/editors/InputFormFieldPulseDataDomainEditor/InputFormFieldPulseDataDomainEditor.test.tsx
  - packages/ui/src/editors/InputFormFieldRunSetSelectorEditor/InputFormFieldRunSetSelectorEditor.stories.tsx
  - packages/ui/src/editors/InputFormFieldWorkspaceRunScheduleEditor/InputFormFieldWorkspaceRunScheduleEditor.test.tsx
  - packages/ui/src/editors/WorkspaceRunSetTable/WorkspaceRunSetTable.test.tsx
  - packages/ui/src/editors/WorkspaceRunSetTable/WorkspaceRunSetTable.tsx
  ~ packages/ui/src/slices/settings/settings.reducer.test.ts
  ~ packages/ui/src/slices/settings/settings.reducer.ts
  - TASK.md
  0 added, 2 modified, 18 removed
```

the line in question (/Users/tkendrick/Sites/task-tree/task-tree/scripts/cli/lib/worktree.sh:1115) is:

```shell
    if printf '%s\n' "$new_files" | grep -qFx -e "$path"; then
```
