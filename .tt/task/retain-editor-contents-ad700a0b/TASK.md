---
title: "Retain prompt editor contents on transaction failure"
status: TODO
created: 2026-09-08T09:01:23Z
updated: 2026-09-08T09:01:23Z
---
Currently, the `prompt` and `prompt_raw` common helpers invoke external editors to allow the user to enter arbitrary input.

The resulting file is discarded by the prompt helper functions as soon as its contents has been read.

This can prove frustrating if the overall command is aborted or rolled back, causing the user to lose work.

Let's avoid frustration by integrating the prompt helpers with the transaction system, whereby the temporary prompt editor contents files are retained until the transaction has been completed successfully.

If the transaction fails the temporary files are retained and user is shown via stderr the paths to any temporary prompt editor files created during this transaction (no need to identify the paths, the user can easily identify which file is which from the content).

If the transaction succeeds the temporary files should be deleted on completion of the transaction (swallowing any errors if the `rm` operation itself fails, these are just temporary files).

Some commands may already partially implement this behavior by manually dumping an output file containing specific content on error; if that is the case the custom handler should be removed in favor of this generic transaction-driven editor retention mechanism; any non-prompt user input can be discarded.

This is an implementation detail and doesn't need any additional documentation updates
