---
title: "Standardize commit messages across all commands"
status: DONE
created: 2026-04-07T09:56:38Z
updated: 2026-04-23T07:14:54Z
context: context/implementation-plan-84f963b2
---
Currently, various commands produce a variety of ad-hoc semi-structured commit messages. 

Let's standardize these to a consistent format.

The desired form has a machine-readable metadata section in square braces, followed by an optional human-readable contextual description as free text. 

e.g.:

```
[tt:workspace:init] Create workspace
[tt:task:project/my-project-ab123456:create] My project description
[tt:task:task/foo-bar-123456ab:create] My task description
[tt:task:task/foo-bar-123456ab:edit] My updated task description
[tt:task:task/foo-bar-123456ab:context:add] Implementation plan
[tt:task:task/foo-bar-123456ab:checkpoint] Began implementing feature
[tt:task:task/foo-bar-123456ab:checkpoint] Partway there
[tt:task:task/foo-bar-123456ab:handoff] My updated task description
[tt:task:task/foo-bar-123456ab:checkin] My updated task description
[tt:task:task/foo-bar-123456ab:delete] My updated task description
```

The metadata section is somewhat similar to a REST resource URL, and identifies the operation that triggered the commit. Note that `tt task checkin` operations will produce two commits: one `handoff` commit (on the child branch) and one `checkin` commit (on the parent branch) - both of these take the identifier of the task that is being checked in. Similarly, `create` commits take the identifier of the task being created.

Note that the contextual description generally relates to the task being operated on, and is meant to be an informal means of identifying tasks / context entries via their title. Checkpoint commits take the user-provided checkpoint message as their description (and can have multiple lines separated with a blank line); all other descriptions are a single line.

Some commands (currently just `workspace init`) will have a static description, as there is no relevant context at this point. All other commands have an entirely contextual description taken from the metadata of the task or context file that is being modified by the command.

For 'mutating' operations (e.g. editing / renaming / moving a task), the updated metadata (not the outdated metadata) should be used to populate the commit message.

Before proceeding, analyze all `jj` commit messages generated across all commands, showing me how the commit message currently looks and how it will look in the new world.
