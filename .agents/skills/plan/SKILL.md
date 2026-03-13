---
name: plan
description: Produces comprehensive self-contained implementation plans. Always use before implementing any non-trivial changes.
---
# Plan

Produce a comprehensive plan that can be executed in isolation from any chat context by a junior developer with no knowledge of the project.

The plan is intended to be analyzed in isolation from any chat context and should therefore be standalone and exhaustive. Do not assume any user knowledge, judgement, or decision-making ability, and do not assume any familiarity with the existing codebase.

The plan should not contain any hand-waved sections left to the reader's interpretation; it should explicitly lay out all relevant details and design decisions such that there is no ambiguity in how to execute the plan.

## Instructions

1. **Create the plan** – Produce a comprehensive plan **including code snippets of all relevant parts**.
2. **Save** – Save the plan to `.agents/plans`. The saved plan must be standalone and exhaustive:
   - The plan as presented to the user
   - All relevant context and research findings from the conversation so far
   - All paths and identifiers for relevant source code and documentation
   - Other useful context uncovered during research
   - A transcript of any questions and responses presented to the user
   - A decision log containing key decisions
   - A task list containing GFM checkboxes for each discrete step of the implementation, which can be checked off as the steps are completed during implementation
3. **Present** – Show the user a summary of the key details, and the path to the saved plan, and **await user feedback**.
4. **Iterate** – If the user provides feedback (either by updating the plan file or by providing additional input), update the plan file to address it and await confirmation. Repeat until the user is happy.

Do not proceed to implementation unless explicitly instructed by the user.
