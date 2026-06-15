---
title: "Agentic workflows skill"
status: DONE
created: 2026-06-15T12:33:57Z
updated: 2026-06-15T12:33:58Z
---
.agents/skills/tt/SKILL.md

I'd like to flesh out this skill so that it can be used fully autonomously by agents.

The general workflow described in the skill is valid at a high level. However, I'd like to additionally describe some opinionated workflows for different task types.

Write up the following workflows, expanding/rephrasing for clarity:

# Workflow: Large tasks

Follow this workflow for tasks of sufficient complexity that they can sensibly be broken down into smaller tasks

## Phase 1: Analysis

- analyze the overall 'top-level' task, distilling it into a collection of independent child tasks
- for each child task in turn:
  - write a comprehensive task description to `.agents/plans/<slug>-task-description.md`
  - create a `tt` task as a child of the current task (returns the task ID): `tt task create --slug <slug> --title <title> --propagate < .agents/plans/<slug>-task-description.md`
  - optionally, recursively perform the analysis phase to subdivide the child task into yet smaller child tasks, providing `--parent <task-id>` to the `tt task create` command to register the grandchild task as a child of the child task

# Phase 2: Implementation

- for each atomic 'leaf' task in turn:
  - check out the task in the current worktree: `tt task checkout <task-id>`
  - if the task represents a non-trivial change (i.e. more than a few lines):
    - write an implementation plan to `.agents/plans/<task-id>-implementation-plan.md`
    - add the implementation plan to the task context: `tt task context add --title "Implementation Plan" < .agents/plans/<task-id>-implementation-plan.md`
  - implement the task, making incremental VCS commits as you go
  - once the task has been implemented and tested, create a `tt` checkpoint commit: `tt task checkpoint --message <message>`
  - check in the task, propagating to its siblings: `tt task checkin --complete --propagate`
    - if the task would benefit from 'handoff' notes being added to the parent task, use the `--context -` argument and pipe the implementation notes into stdin to record this in the parent task context
  - if this task is the last remaining task within a recursive group of grandchild tasks, check in the parent task as well
- stop when all the child tasks are complete. Do not check in the 'top-level' task until the user has reviewed and approved the code changes.

# Workflow: Parallel development

Follow this workflow for high-level orchestration of multiple independent workstreams.

This is a variation of the 'large tasks' workflow.

The only difference is that in Phase 2: Implementation, one agent is spawned per child task.

- For each child task of the overall 'top-level' task:
  - check out a worktree for the child task (returns the created worktree path): `tt checkout --worktree <task-id>`
  - spawn an agent with the generated worktree path for the rest of the child task implementation
  - complete the rest of the flow for that task within the agent

Caveats to note with the parallel development workflow:

- It's vital that each agent keeps track of which worktree it's operating in, and stays confined to that. Agents must not switch worktrees. The only mechanism of communication between worktrees is propagating task context handoff notes.
- Conflicts typically arise when the parent task has not been propagated to the child task before checking in the child task, and errors typically arise when different worktrees have stale working copies due to changes being propagated from other worktrees. Use the following command to propagate the parent task before checkin, and to ensure the child task status is propagated to all other worktrees:

  ```
  tt propagate --from $(tt parent) --to $(tt current) && tt checkin --complete --propagate && jj-update-stale-workspaces
  ```

  …where `jj-update-stale-workspaces` is a user-defined shell alias for:

  ```
  jj workspace update-stale && jj workspace list --template "name ++ \"\\n\"" | while read workspace; do echo "Updating workspace: $workspace" && (cd $(jj workspace root --name "$workspace") && jj workspace update-stale); done
  ```
