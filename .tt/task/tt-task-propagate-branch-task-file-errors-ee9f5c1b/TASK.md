---
title: "Report errors whn parsing remote branch task files in `tt task propagate`"
status: TODO
created: 2026-10-20T10:11:13Z
updated: 2026-10-20T10:11:13Z
---
Currently, when `tt task propagate` fails to parse remote branch task files to determine their status, it falls back to assuming `status: DONE`.

Let's instead report the error to stderr as a warning, continue with other branches, and return a non-zero exit code from the overall `propagate` operation.
