---
name: code-review
description: Analyze implementation details and identify potential issues. Always use before completing any non-trivial implementation task.
---

# Overview

Your task is to review the implemented code and flag potential quality, maintainability, and security issues.

Your task is NOT to fix the issues, merely to identify them and then discuss with the user once all issues have been identified.

# Instructions

## Step 1: Gather context

If the user has not specified which code to review, ask the user which code they want you to review. Do not assume you know which code is under discussion without being told.

If the user has provided a plan or specification, make sure to read the plan before proceeding with the review. Once you have read the plan, ask the user a short series of clarifying questions to spell out all details and ensure a common understanding of the desired behavior.

If the user has not provided a plan, ask the user a long series of increasingly specific questions to build an understanding of the changes and the high-level goal.

This step will help you identify whether the implementation details align with the intended functionality, so more detail is better.

## Step 2: Analyze the approach

Build a full understanding of the change before diving into small details. Consider the following questions:

- Does the code achieve the high-level goal?
- Have any relevant high-level tests been written to ensure the code achieves these goals?
- Is there a simpler way to implement the same functionality?
- Is there a more elegant way to implement the same functionality?
- Is the code modular, reusable and maintainable, or is it tightly coupled and specific to a single use case?
- Are there any edge cases that have not been handled?

It's important to remember that the goal of the code is not just to implement this feature, but to do so in a way that lays the groundwork for future features. A change that achieves the immediate goal but makes the codebase more difficult to work with in the future may not be a good change.

If there are significant issues with the overall approach, you must stop here and discuss these high-level issues with the user. If the overall approach looks good, move on to the next step.

## Step 3: Identify code issues

Analyze the code in detail and identify all potential issues introduced by the change. Consider the following guidelines:

- Be militant about DRY. If you see similar code repeated in more than one place, consider whether it can be abstracted into a reusable function or component.
- This includes repetition of prior code: new additions should not duplicate existing code. If existing code has been duplicated, the common logic needs to be extracted out into a shared utility function or component and update the prior call site.
- Be suspicious of defensive coding. Rigid types should be used to ensure correctness rather than adding extra checks in the code.
- Look at each line of code that has been added. Does this line of code need to exist? Is it purely there to maintain backwards compatibility? If so, it should be flagged for potential removal.
- Have the changes resulted in dead code, including unused parameters or variables? If so, this code should be flagged for removal.
- Pay particular attention to all comments introduced by the change. Are there any comments that indicate a workaround or hack? If so, this is a red flag that the code may need to be refactored.
- Are there comments that relate to the *process* of the change (e.g. `// Updated condition to handle edge case`) rather than the code itself? If so, these comments should be flagged for removal as they do not add value to future readers.

To identify an potential issue, add a `FIXME` comment above the relevant line of code, along with a brief description of the issue and freeform points for discussion. For example:

```typescript
// FIXME: This function does not handle the edge case where sourceWidth is zero, which would lead to an infinite size ratio
// Question: is this possible in practice?
// If so, we should add a check to prevent this.
// If not, we should add a comment explaining why this is not possible
function getFullScreenSizeRatio(sourceWidth: number, targetWidth: number): number {
  return targetWidth / sourceWidth;
}
```

Do this for each issue you encounter, no matter how small, then move on. Do not stop after finding the first issue, as there may well be multiple issues in the code.

Sometimes, you may encounter a line of code that you are unsure about. In this case, it's better to flag it with a `FIXME` and a note about your uncertainty, rather than giving it the benefit of the doubt and potentially missing a nuanced issue.

## Step 4: Discuss the issues with the user

Once all the code has been analyzed, use your `plan` skill to create a new plan containing a thorough analysis of the full list of identified issues.

Add a section to the plan for each FIXME in turn, provide a brief description and the relevant background context and code snippet, providing multiple-choice suggestions where releveant to determine based on the user's feedback whether it is a valid concern and how it should be addressed.

Present a summary of the plan to the user and await their feedback.

Once all unanswered questions have been addressed, rewrite the plan into a clear action plan for how to address each FIXME, including any necessary refactoring or additional testing.

Do not make any code changes until explicitly instructed by the user.
