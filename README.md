# Evidence Capture for Claude Code

A Claude Code plugin for documenting client implementation work with screenshots. You get the screenshot you meant, filed under the right step, with a link you can paste and a trail you can check later.

- **The clipboard is read once, at the moment you run the command.** The image goes straight into an immutable staged copy before Claude does anything else. If the clipboard changes after that, the capture is unaffected.
- **You confirm before anything is filed.** The staged image opens in your image viewer, and nothing is attached until you say it's the right one.
- **Files are named by step.** For example `docs/images/C2-05-api-keys-page.png`. Existing evidence is never overwritten without your explicit yes.
- **It gives you a Markdown link and caption.** Claude can also insert them into a document section, after showing you the diff.
- **It keeps a hash-checked evidence trail.** One JSON line per screenshot records:
  - the capture time and timezone
  - the source (clipboard or file)
  - the path
  - the SHA-256 hash
  - the step and description
  - the confirmation and verification status

  `/evidence:check` re-hashes every file against its record.
- **Everything stays local.** There's no upload, no OCR, no NoteSmith or KnotDo sync and no full-screen capture. Claude doesn't look at your screenshots unless you ask it to.

## Install

Requirements:
- Windows
- PowerShell 7.5 or later (`pwsh`)
- Claude Code with plugin support

Clone the repo:

```
git clone https://github.com/VAROIndustries/ClaudeEvidence C:\Projects\ClaudeEvidence
```

Load it in every session by adding it to `CLAUDE_CODE_PLUGIN_DIRS` in the `env` block of `~/.claude/settings.json`. Separate entries with `;`:

```json
{ "env": { "CLAUDE_CODE_PLUGIN_DIRS": "C:\\Projects\\ClaudeMods;C:\\Projects\\ClaudeEvidence" } }
```

Restart Claude Code, or run `/reload-plugins`. To try it for a single session instead:

```
claude --plugin-dir C:\Projects\ClaudeEvidence
```

## Usage

Run these from the project you're documenting.

| Command | What it does |
| --- | --- |
| `/evidence:capture` | Stages the clipboard image, opens it for you to confirm, then asks for the step, description and verification result and attaches it |
| `/evidence:capture C2-05 API keys page` | Same, with the step and description pre-filled |
| `/evidence:capture "C:\path with spaces\shot.png"` | Stages an existing image file instead of the clipboard |
| `/evidence:attach [id]` | Attaches a capture you kept staged earlier |
| `/evidence:discard <id \| all>` | Deletes staged captures you no longer want |
| `/evidence:check` | Confirms every recorded screenshot still exists and matches its hash |

A typical loop looks like this:
1. Press Win+Shift+S and snip the setting.
2. Run `/evidence:capture C2-05 API keys page` and check the image that opens.
3. Answer **Yes**, then say whether you verified the configuration (pass, fail or not checked).
4. Optionally name a document and section, e.g. `docs/runbook.md`, "Step C2-05". Claude shows the diff and inserts the link after you approve it.

If the clipboard has no image, capture says so and stops. It never reuses an earlier capture.

**Confirmed is not verified.** `confirmed: true` only means you agreed it was the right screenshot. `verification` (`pass`, `fail` or `null`) is a separate answer about whether the system is actually configured correctly. A screenshot alone proves neither.

## Configuration

Configuration is optional and lives per project in `<project>/.claude/evidence.json`:

```json
{ "evidenceDir": "docs/images", "records": "docs/evidence.jsonl" }
```

Without that file:
- `evidenceDir` is the first of `docs/images`, `docs/img`, `docs/screenshots` or `images` that already exists, falling back to `docs/images`.
- `records` is `evidence.jsonl` in the folder that contains the evidence folder.

Both paths are relative to the project and must stay inside it. Configuration and records are separate files.

Links are written relative to the document they're inserted into, with spaces encoded as `%20`. With no document, they're relative to the project.

### Record format

Each line of the records file is one JSON object:

```json
{"captured_at":"2026-10-18T10:52:03.1234567-05:00","timezone":"Central Standard Time","attached_at":"…","source":"clipboard","original":null,"path":"docs/images/C2-05-api-keys-page.png","sha256":"…","size":"1920x1080","bytes":184233,"step":"C2-05","description":"API keys page","confirmed":true,"verification":"pass"}
```

If you approve an overwrite, the new line also records `replaced_sha256`, and `/evidence:check` uses the latest line for each path.

### Staging

Staged captures live in `%USERPROFILE%\.claude\evidence\staging`, which sits outside every repo, so they can never be committed. Each one is a read-only image plus a small JSON file holding its hash and capture time.

A staged copy is deleted when it's attached. You can also delete staged copies with `/evidence:discard`.

Before attaching, the plugin re-checks the staged image against its hash, and it re-hashes the project copy after copying it.

## Script

The plugin is one PowerShell script that the skills call. You can also run it directly:

```
pwsh -NoProfile -STA -File scripts/evidence.ps1 stage [-File <image>]
pwsh -NoProfile -STA -File scripts/evidence.ps1 attach -Id <id> -Step C2-05 -Description "API keys page" -Confirmed [-Verification pass|fail] [-Doc docs/runbook.md] [-Overwrite]
pwsh -NoProfile -STA -File scripts/evidence.ps1 list | discard -Id <id> | discard -All | check
```

Every result starts with `STATUS: <WORD>`, followed by `KEY: value` lines. Any failure exits non-zero:

| Status | Exit code |
| --- | --- |
| `NO_IMAGE` | 2 |
| `EXISTS` | 3 |
| `NOT_FOUND` | 4 |
| `NOT_IMAGE` | 5 |
| `NOT_CONFIRMED` | 6 |
| `STAGED_CHANGED` | 7 |
| `FAILED` (check) | 8 |
| `BAD_CONFIG` | 9 |

## Tests

```
pwsh -NoProfile -File tests/test.ps1
```

The tests mock the clipboard with the `EVIDENCE_TEST_CLIPBOARD` environment variable, set to an image path or `EMPTY`. They cover:
- an empty clipboard
- the clipboard changing after staging
- filename collisions and approved overwrites
- cancelling and discarding
- paths with spaces
- project-relative and document-relative links
- record integrity and tamper detection
- refusing an evidence folder outside the project
- refusing non-image files
- an 8000×5000 image

## Limitations

- **Windows only.** The clipboard is read through Windows Forms. Supported formats are PNG, JPG, GIF and BMP. Clipboard images are saved as PNG; files keep their original bytes.
- **No built-in image preview in Claude Code.** The preview opens in your default image viewer, and confirmation happens in chat.
- **One clipboard image per capture.** Copied files (from Explorer) aren't picked up from the clipboard; pass the path instead.
- **The hash shows the file hasn't changed since capture.** It doesn't show what the screenshot depicts, or that the system was configured correctly.
- **Not included yet:** OCR, automated redaction, region or window capture, and NoteSmith or KnotDo integration. For now, ask Claude to file the evidence links through those tools' existing connectors when you want that.

## License

MIT
