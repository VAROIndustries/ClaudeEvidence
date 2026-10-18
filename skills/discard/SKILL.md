---
name: discard
description: Discard staged evidence captures that were not attached (one by id, or all).
argument-hint: "<staged id | all>"
disable-model-invocation: true
---

Script: `${CLAUDE_PLUGIN_ROOT}/scripts/evidence.ps1`. Run it as `pwsh -NoProfile -STA -File "<script>" <command> ...`.

Staged captures right now:

!`pwsh -NoProfile -STA -File "${CLAUDE_PLUGIN_ROOT}/scripts/evidence.ps1" list`

Requested: `$ARGUMENTS`

- If it's `all`: show the count, ask once to confirm, then run `discard -All`.
- If it's an id from the list: run `discard -Id <id>`.
- If it's empty: ask which to discard, or all.

Report the `COUNT` discarded. Attached evidence in projects is never touched by this command.
