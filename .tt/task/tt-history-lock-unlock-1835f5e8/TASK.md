---
title: "Add `tt history lock` / `tt history unlock --key` CLI commands"
status: TODO
created: 2026-11-14T10:01:52Z
updated: 2026-11-14T10:01:52Z
---
Mutating commands currently create a transaction for the whole command allowing atomic history rollback if the command fails.

Let's expose this functionality for user-facing commands via a `tt history lock` command that returns a transaction key and adding an equivalent `--key` argument to the existing `tt history unlock` command.

Alias the commands as `lock` and `unlock`.

This will start a standard transaction, allowing the user to commit the transaction at will using the existing locking and unlocking mechanism.

When providing the key argument to the unlock command, the transaction will be committed only if the key matches the current active transaction ID. Otherwise the user sees an error.
