---
title: "Change prompt editor line stripping syntax"
status: TODO
created: 2026-09-08T09:13:04Z
updated: 2026-09-08T09:13:05Z
---
In the `prompt_raw` helper, any empty leading/trailing lines or `#`-prefixed lines are stripped from the output.

Various commands use these lines to provide a prompt 'hint' to the user so that they aren't just dumped 'blind' into an editor without any context (similar to standard git / jj command behavior).

The line-stripping can have unintended results however, as sometimes the user might want to introduce multiple leading/trailing newlines, or a `#`-prefixed markdown section header.

The one exception is the unix convention of stripping a single trailing newline from the overall document to indicate the end of the document.

Let's examine the line-stripping mechanism so that we can provide the user with a prompt 'hint' without producing unexpected results.

One option would be to denote hint lines by prefixing them with a known ASCII control character, although it remains to be seen if this would cause problems for standard visual editors (`vim`, `nano`, etc) - let's explore alternatives.

Update DESIGN.md 'interactive message editing' section accordingly.
