---
title: "Show hint comment in `tt task checkin` prompt editor"
status: IN-PROGRESS
created: 2026-06-15T13:08:32Z
updated: 2026-06-15T13:08:33Z
---
scripts/cli/task/checkin
scripts/cli/lib/common.sh

When in a tty, `tt task checkin` prompts the user to enter optional task handoff context via `prompt_raw`, which includes the whole editor contents verbatim

To make this more self-explanatory, let's instead use the comment-stripping `prompt` function and provide the following default editor contents:

```

# Task: <task-id>
# Optional handoff context
```

see a similar example in scripts/cli/task/checkpoint:116~126
