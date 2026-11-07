---
title: "Implement `tt task log` CLI command"
status: IN-PROGRESS
created: 2026-11-07T11:21:56Z
updated: 2026-11-07T11:21:56Z
---
Let's add a `tt task log` CLI command that shows the commit graph of the current repository.

This will be very similar to the output of `jj log`, only at a 'higher level', with the `[tt:…]` prefixed commits shown as minimal 'branch event' glyphs, additionally showing the child name for fork commits (and potentially the parent name for checkin commits? not sure), leaving the focus on the raw `jj` commits.

A teriminal with 'nerd fonts' enabled should see proper icons for the branch event glyphs.
