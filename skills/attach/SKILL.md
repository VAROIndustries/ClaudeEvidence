---
name: attach
description: Attach an already-staged evidence capture to a project step, write the evidence record, and optionally insert the Markdown image link into a document section.
argument-hint: "[staged id]"
---

Script: `${CLAUDE_PLUGIN_ROOT}/scripts/evidence.ps1`. Always run it as `pwsh -NoProfile -STA -File "<script>" <command> ...` from the project root. Quote every argument; paths and descriptions may contain spaces.

Staged captures right now:

!`pwsh -NoProfile -STA -File "${CLAUDE_PLUGIN_ROOT}/scripts/evidence.ps1" list`

## 1. Pick and confirm the capture (skip if coming from /evidence:capture)

Requested id: `$ARGUMENTS`. If it's empty, ask which of the listed captures to use. If none are listed, say so and stop; `/evidence:capture` makes one.

Open it for the user with `Start-Process -FilePath '<path from list>'`. Do not view it yourself unless asked. Then ask "Is this the right screenshot?". If not, offer `discard -Id <id>` and stop.

## 2. Gather details

Ask for anything not already given:
- **Step**, e.g. `C2-05`. Letters, digits, `.`, `_` and `-` only.
- **Short description**, e.g. `API keys page`. It becomes the filename slug and the caption.
- **Verification result**: `pass`, `fail`, or not checked. Ask this as its own question and say plainly: *confirming the screenshot shows what you meant is not the same as verifying the system is configured correctly.* Only record pass or fail if the user states it.
- **Document to insert into (optional)**: a project-relative path and a section heading.

## 3. Attach

```
attach -Id <id> -Step "<step>" -Description "<description>" -Confirmed [-Verification pass|fail] [-Doc "<doc path>"]
```

- `-Confirmed` means the user confirmed the image in the preview. Never pass it otherwise.
- `STATUS: EXISTS` means a file with that name already exists. Nothing was changed. Show the user the `PATH` and ask whether to replace it or choose a different description. Re-run with `-Overwrite` **only** on an explicit yes for that specific file.
- On any other non-`ATTACHED` status, report `MESSAGE` and stop.

## 4. Insert into the document (only if a document was given)

Build the snippet from the `LINK` line, then the `CAPTION` line underneath, then a blank line.

Show the user the proposed change as a unified diff: a few lines of context around the insertion point at the end of the chosen section. Then ask before editing. Apply it with the Edit tool only after a yes. If the doc or section doesn't exist, say so and print the snippet instead.

## 5. Report

Report the `PATH`, the `RECORD` file, the first 12 characters of `SHA256`, and the Markdown snippet. If no verification result was recorded, say the screenshot is attached as **confirmed, not verified**.
