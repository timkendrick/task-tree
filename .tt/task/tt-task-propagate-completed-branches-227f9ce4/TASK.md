---
title: "Prevent continuation of completed branches in `tt task propagate`"
status: DONE
created: 2026-04-15T08:30:16Z
updated: 2026-04-15T09:00:53Z
---
Currently, `tt task propagate` additionally rebases all 'checked-in' branches, ensuring that their head is a descendant of the parent task.

This is typically desirable for branches that are still IN-PROGRESS, but undesirable for branches that are DONE, as it 'reanimates' historical branches that are no longer relevant.

The `propagate` command currently checks the subtask's commit ancestry to determine whether there are commits that need to be rebased, which presumably causes any bookmarks that point to stub 'empty' commits branching off the parent task to be rebased.

A naive approach would be to use the subtask's `status:` frontmatter as a heuristic to determine whether to skip rebasing these branches.

Perhaps a better approach would be to modify the `checkin` command such that when a completed branch is checked in, the bookmark should point directly to the 'complete' commit in the parent task's ancestry, *not* a new empty commit that branches off this.

Confirm the current scenario by writing the following `checkin` tests:

- checking in an incomplete branch should leave the task bookmark pointing to an empty commit whose parent is the the complete commit (this test might already exist and should already pass)
- checking in a complete branch (or passing the `--complete` flag when checking in an incomplete branch) should leave the task bookmark pointing to the complete commit itself (this test should fail initially)
- passing the `--propagate` flag when checking in a complete branch (or passing the `--complete` flag when checking in an incomplete branch) should ensure the task bookmark still points to the complete commit (this test should fail initially)

Once the scenario is confirmed, implement a fix and confirm that these tests pass.

No need to run any other tests, this is sufficient to confirm the issue has been fixed.
