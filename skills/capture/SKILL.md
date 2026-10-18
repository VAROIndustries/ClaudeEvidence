---
name: capture
description: Capture a screenshot as evidence for an implementation step. Stages the Windows clipboard image immediately, or a given image file, then previews, confirms and attaches it. Use when the user says to capture, save or attach a screenshot or evidence.
argument-hint: "[image file path] | [step] [description]"
---

The clipboard was already read, once, before you saw this, by this command:

!`pwsh -NoProfile -STA -File "${CLAUDE_PLUGIN_ROOT}/scripts/evidence.ps1" stage`

Script: `${CLAUDE_PLUGIN_ROOT}/scripts/evidence.ps1`. Always run it as `pwsh -NoProfile -STA -File "<script>" <command> ...` from the project root. Quote every argument.

User's arguments: `$ARGUMENTS`

## 1. Decide the source

**The arguments are a path to an existing image file** (possibly quoted, possibly containing spaces): the user wants that file, not the clipboard.
- If the clipboard stage above succeeded, discard it with `discard -Id <that ID>` and mention that you did.
- Then run `stage -File "<path>"` and use its result below.

**Otherwise** use the clipboard result above. Any arguments are the step and description, e.g. `C2-05 API keys page` means step `C2-05`, description `API keys page`. Carry them into the attach step.

## 2. Check the result

- If the stage output does not contain `STATUS: STAGED`, tell the user the `MESSAGE` line verbatim and **stop**. Do not retry, do not read the clipboard yourself, and never fall back to an older staged capture.
- Otherwise note `ID`, `STAGED`, `SHA256`, `SIZE`. From here on, work only with that staged file and ID. **Never read the clipboard again.**

## 3. Preview

Open the staged file for the user: `Start-Process -FilePath '<STAGED>'`. Single-quote the path.

Do **not** Read or view the image yourself unless the user asks. Screenshots may be sensitive, and viewing one sends it to the model.

Then AskUserQuestion: "Is this the right screenshot? (<SIZE>, staged <ID>)" with options:
- **Yes, attach it**
- **No, discard it**: run `discard -Id <ID>`, confirm it's gone, stop.
- **Keep it staged for later**: tell them `/evidence:attach <ID>` picks it up later, stop.

## 4. Attach

Follow `${CLAUDE_PLUGIN_ROOT}/skills/attach/SKILL.md` from step 2, using this ID and any step and description from the arguments. The user has already confirmed the image.
