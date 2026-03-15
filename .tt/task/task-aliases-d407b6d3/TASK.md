---
title: "Add task aliases"
status: DONE
created: 2026-03-15T09:29:31Z
updated: 2026-03-15T09:29:31Z
---
Implement top-level task aliases as described in the design document

We need to add a selection of known aliases to the `tt` main dispatcher function. More aliases will be added as the tool develops, so let's think about how we can simply and elegantly define the availabe aliases as an extensible list that we can easily add to later on.

For now, we can assume that all the alias configurations will be (alias, command, subcommand) triples.
