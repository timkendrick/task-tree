---
title: "Retain temporary file when editor exits with non-zero status"
status: TODO
created: 2026-04-24T07:44:02Z
updated: 2026-04-24T07:44:03Z
---
Currently, in the `prompt_raw` function in scripts/cli/lib/common.sh, if the editor exits with a non-zero status it prints the temporary file containing editor contents as output and deletes the temporary file via a `trap`.

It would be better if in an error scenario the script does not delete the temporary file, but prints the path to the temporary file for the user to recover if needed.

In a success scenario, the script should delete the temporary file as currently.
