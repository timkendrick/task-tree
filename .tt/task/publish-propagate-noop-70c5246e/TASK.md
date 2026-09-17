---
title: "tt task publish --rebase/--merge does nothing"
status: TODO
created: 2026-09-17T14:21:35Z
updated: 2026-09-17T14:21:35Z
---
`tt task publish --rebase` and `--merge` are silent no-ops.

Publish delegates to `tt task propagate --from <target> --to <project>`, but propagate works by enumerating the `subtask:` entries registered in the *from* branch's task file. A delivery branch such as `main` has no task file, so propagate warns

    Warning: main is not a task/project branch; cannot enumerate subtasks

and returns having done nothing. The project branch is never rebased onto (or merged with) the target, so the publish merge that follows can still conflict — which is what surfaced the bug, in a test expecting the propagation to refuse on conflict.

DESIGN.md §6.5 specifies that with `--rebase` or `--merge` the tool first propagates from the target into the project branch and bails on conflict unless `--force`.

The fix needs a decision about the mechanism: propagate's parent/child model is expressed in terms of registered subtasks, which cannot describe "rebase this branch onto an arbitrary revision". Either propagate grows a way to name the branch to move directly, or publish stops going through propagate and moves its own unmerged range onto the target.

Scope: also add the test that uncovered this — a project branch and a target branch that both touch the same file, then `tt task publish --target main --rebase`, asserting the command refuses and leaves the target bookmark where it was.
