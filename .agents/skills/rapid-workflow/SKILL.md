---
name: rapid-workflow
description: Interactive workflow for planning and implementing changes. Always use before planning or implementing any non-trivial changes.
---
# RAPID Workflow

## Phase 1: Implementation

1. **Research** – Based on the user's initial prompt, research relevant context within the codebase.
2. **Ask** – Ask the user a long series of increasingly-specific questions using your `ask` tool to determine all implementation details.
3. **Plan** – Use your `plan` skill to produce a comprehensive plan for the changes. Include all relevant research findings and any other potentially useful context that was uncovered during the research phase, as well as a transcript of the user's questionnaire and responses. Await user feedback on the plan, iterating the plan until the user has explicitly confirmed that they are happy to move on to implementation.
4. **Implement** – Implement the changes as instructed in the plan. Make sure to commit and check diagnostics before moving on. After completing each step of the implementation, update the task list in the plan file to reflect progress, and additionally update the relevant section of the plan to reflect reality, making sure to detail any any deviations from the plan, and any additional implementation details or relevant context not already outlined in the plan.
5. **Diagnostics** – Use diagnostics tools to ensure that the changes have not introduced any new errors or warnings. Run lint/test commands and *make sure they pass* before considering the change implemented.

At this point in the workflow, commit all changes in version control and pause, presenting the user with a comprehensive summary of all changes that have been implemented (see Phase 2).

## Phase 2: Review

Always give the user an opportunity to reflect on the implementation and offer feedback before proceeding.

- **Summarize** – Present the user with a comprehensive summary of all changes, including code snippets of important parts of the implementation. Make sure to specifically highlight all changes that have deviated from the original plan.
- **Suggest** – Identify refactoring opportunities, paying particular attention to keeping the implementation DRY and not duplicating existing code. Suggest these to the user as potential next steps.
- **Solicit feedback** – Ask the user how to proceed. They might ask you to return to implementation to refine details, or they might instruct you to proceed to documentation. 

## Phase 3: Document

Once the changes have been reviewed by the user, make sure to document the new state of the codebase and update any pre-existing documentation which is now out of date as a result of the changes.

This documentation will be used as a technical guide for future tasks, and represents the canonical view of the project: Don't document what has changed, instead document what the new state is (e.g. how a feature is implemented) and any findings which proved useful over the course of the session (e.g. how to debug a certain class of errors).

Make sure to review existing documentation for inaccuracies that have been introduced as a result of the changes.
