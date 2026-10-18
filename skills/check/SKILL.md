---
name: check
description: Verify this project's evidence trail - every recorded screenshot still exists and matches its recorded SHA-256.
---

!`pwsh -NoProfile -STA -File "${CLAUDE_PLUGIN_ROOT}/scripts/evidence.ps1" check`

Summarise this result. For each `MISSING` or `MISMATCH` line, name the file and say that it no longer matches the evidence record. Do not modify any files to "fix" a mismatch. A changed image means its evidence needs recapturing, and that is the user's call.
