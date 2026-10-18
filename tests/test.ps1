# Self-check for scripts/evidence.ps1. Run: pwsh -NoProfile -File tests/test.ps1
# The clipboard is mocked with EVIDENCE_TEST_CLIPBOARD (path to an image, or EMPTY).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$script = Join-Path $PSScriptRoot '..\scripts\evidence.ps1' | Resolve-Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) "evidence test $([guid]::NewGuid().ToString('n').Substring(0,6))"
$proj = Join-Path $tmp 'Client Project'          # spaces on purpose
$env:EVIDENCE_STAGING = Join-Path $tmp 'staging dir'
New-Item -ItemType Directory -Force (Join-Path $proj 'docs\images') | Out-Null
$fails = 0

function Check($name, [bool]$ok) { if ($ok) { "ok   $name" } else { "FAIL $name"; $script:fails++ } }
function Ev { $out = & pwsh -NoProfile -STA -File $script @args 2>&1 | Out-String; @{ out = $out; code = $LASTEXITCODE } }
function Field($r, $k) { if ($r.out -match "(?m)^$k`: (.+?)\r?$") { $Matches[1] } }
function Png($path, $w, $h, $color) {
  $b = New-Object Drawing.Bitmap $w, $h, ([Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $g = [Drawing.Graphics]::FromImage($b); $g.Clear($color); $g.Dispose()
  $b.Save($path, [Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
}
function Sha($p) { (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }

$a = Join-Path $tmp 'shot a.png'; Png $a 64 48 ([Drawing.Color]::Red)
$b = Join-Path $tmp 'shot b.png'; Png $b 64 48 ([Drawing.Color]::Blue)
Push-Location $proj
try {
  # 1. empty clipboard fails clearly and stages nothing
  $env:EVIDENCE_TEST_CLIPBOARD = 'EMPTY'
  $r = Ev stage
  Check 'empty clipboard -> NO_IMAGE, non-zero exit' ($r.code -ne 0 -and $r.out -match 'STATUS: NO_IMAGE')
  Check 'empty clipboard stages nothing' (-not (Test-Path $env:EVIDENCE_STAGING) -or -not (Get-ChildItem $env:EVIDENCE_STAGING -Filter *.json))

  # 2. stage from clipboard, then clipboard changes; attach must use the staged copy
  $env:EVIDENCE_TEST_CLIPBOARD = $a
  $r = Ev stage
  $id = Field $r 'ID'; $staged = Field $r 'STAGED'; $capAt = Field $r 'CAPTURED_AT'
  Check 'stage -> STAGED' ($r.code -eq 0 -and $r.out -match 'STATUS: STAGED' -and $id)
  Check 'staged copy hash = clipboard image' ((Sha $staged) -eq (Sha $a) -and (Field $r 'SHA256') -eq (Sha $a))
  Check 'staged copy is read-only' ((Get-Item -LiteralPath $staged).IsReadOnly)
  Check 'stage reports dimensions' ((Field $r 'SIZE') -eq '64x48')
  $env:EVIDENCE_TEST_CLIPBOARD = $b
  $r = Ev attach -Id $id -Step 'C2-05' -Description 'API keys page' -Verification pass -Confirmed
  $dest = Join-Path $proj 'docs\images\C2-05-api-keys-page.png'
  Check 'attach -> ATTACHED' ($r.code -eq 0 -and $r.out -match 'STATUS: ATTACHED')
  Check 'attached file is the staged image, not the new clipboard' ((Test-Path -LiteralPath $dest) -and (Sha $dest) -eq (Sha $a))
  Check 'project-relative link' ((Field $r 'LINK') -eq '![C2-05: API keys page](docs/images/C2-05-api-keys-page.png)')
  Check 'staged copy removed after attach' (-not (Test-Path -LiteralPath $staged))

  # 3. record integrity
  $rec = Get-Content (Join-Path $proj 'docs\evidence.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
  $e = @($rec)[-1]
  Check 'one record' (@($rec).Count -eq 1)
  Check 'record fields' ($e.path -eq 'docs/images/C2-05-api-keys-page.png' -and $e.sha256 -eq (Sha $a) -and $e.step -eq 'C2-05' -and $e.description -eq 'API keys page' -and $e.source -eq 'clipboard' -and $e.confirmed -eq $true -and $e.verification -eq 'pass')
  # raw text: ConvertFrom-Json would turn the timestamp into a DateTime and drop the offset
  Check 'captured_at has timezone offset' ([bool]((Get-Content (Join-Path $proj 'docs\evidence.jsonl')) -match '"captured_at":"[^"]+T\d\d:\d\d:\d\d[^"]*([+-]\d\d:\d\d|Z)"') -and $e.timezone)
  Check 'captured_at is the staging time, verbatim' ([bool]((Get-Content (Join-Path $proj 'docs\evidence.jsonl')) -match [regex]::Escape("`"captured_at`":`"$capAt`"")))
  $r = Ev check
  Check 'check passes on intact evidence' ($r.code -eq 0 -and $r.out -match 'OK +docs/images/C2-05-api-keys-page.png')
  Set-ItemProperty -LiteralPath $dest -Name IsReadOnly -Value $false
  [IO.File]::AppendAllText($dest, 'tamper')
  $r = Ev check
  Check 'check flags tampered file' ($r.code -ne 0 -and $r.out -match 'MISMATCH')

  # 4. collision: refuses without -Overwrite, staged copy kept; allowed with it
  $env:EVIDENCE_TEST_CLIPBOARD = $b
  $id2 = Field (Ev stage) 'ID'
  $r = Ev attach -Id $id2 -Step 'C2-05' -Description 'API keys page' -Confirmed
  Check 'collision -> EXISTS, non-zero' ($r.code -ne 0 -and $r.out -match 'STATUS: EXISTS')
  Check 'collision leaves existing file alone' ((Get-Content -Raw -LiteralPath $dest) -match 'tamper')
  Check 'collision keeps staged copy' ((Ev list).out -match $id2)
  $r = Ev attach -Id $id2 -Step 'C2-05' -Description 'API keys page' -Confirmed -Overwrite
  Check 'overwrite with explicit flag' ($r.code -eq 0 -and (Sha $dest) -eq (Sha $b))
  Check 'overwrite records replaced hash' ([bool]((Get-Content (Join-Path $proj 'docs\evidence.jsonl'))[-1] | ConvertFrom-Json).replaced_sha256)

  # 5. attach refuses without confirmation
  $id3 = Field (Ev stage) 'ID'
  $r = Ev attach -Id $id3 -Step 'C2-06' -Description 'x'
  Check 'attach without -Confirmed refuses' ($r.code -ne 0 -and -not (Test-Path (Join-Path $proj 'docs\images\C2-06-x.png')))

  # 6. cancellation: discard removes the staged copy; attach afterwards fails, project untouched
  $r = Ev discard -Id $id3
  Check 'discard -> DISCARDED' ($r.code -eq 0 -and $r.out -match 'STATUS: DISCARDED')
  $r = Ev attach -Id $id3 -Step 'C2-06' -Description 'x' -Confirmed
  Check 'attach after discard fails' ($r.code -ne 0 -and $r.out -match 'STATUS: NOT_FOUND')
  Check 'no image written after cancel' (-not (Test-Path (Join-Path $proj 'docs\images\C2-06-x.png')))
  Check 'stage never reuses an older capture' ((Ev stage).out -notmatch [regex]::Escape($id3))
  $r = Ev discard -All
  Check 'discard -All empties staging' ($r.code -eq 0 -and -not (Get-ChildItem $env:EVIDENCE_STAGING -File))

  # 7. existing file source with spaces + doc-relative link + config
  New-Item -ItemType Directory -Force (Join-Path $proj '.claude') | Out-Null
  '{ "evidenceDir": "docs/shots and things", "records": "docs/trail.jsonl" }' | Set-Content (Join-Path $proj '.claude\evidence.json')
  $r = Ev stage -File $a
  Check 'stage from file' ($r.code -eq 0 -and $r.out -match 'SOURCE: file')
  $r = Ev attach -Id (Field $r 'ID') -Step 'C3-01' -Description 'Tenant settings' -Doc 'docs/runbook/C3 deploy.md' -Confirmed
  Check 'config evidenceDir with spaces' (Test-Path -LiteralPath (Join-Path $proj 'docs\shots and things\C3-01-tenant-settings.png'))
  Check 'doc-relative link, spaces encoded' ((Field $r 'LINK') -eq '![C3-01: Tenant settings](../shots%20and%20things/C3-01-tenant-settings.png)')
  Check 'config records path' ((Test-Path (Join-Path $proj 'docs\trail.jsonl')) -and ((Get-Content (Join-Path $proj 'docs\trail.jsonl')) | ConvertFrom-Json).source -eq 'file')
  Check 'unconfirmed verification is null' (((Get-Content (Join-Path $proj 'docs\trail.jsonl')) | ConvertFrom-Json).verification -eq $null)

  # 8. bad input
  '{ "evidenceDir": "../outside" }' | Set-Content (Join-Path $proj '.claude\evidence.json')
  $id4 = Field (Ev stage -File $a) 'ID'
  $r = Ev attach -Id $id4 -Step 'C4-01' -Description 'x' -Confirmed
  Check 'evidenceDir outside project refused' ($r.code -ne 0 -and -not (Test-Path (Join-Path $tmp 'outside')))
  Remove-Item (Join-Path $proj '.claude\evidence.json')
  $r = Ev attach -Id $id4 -Step '../evil' -Description 'x' -Confirmed
  Check 'step with path chars refused' ($r.code -ne 0)
  $txt = Join-Path $tmp 'not an image.png'; 'hello' | Set-Content $txt
  $r = Ev stage -File $txt
  Check 'non-image file refused' ($r.code -ne 0 -and $r.out -match 'STATUS: NOT_IMAGE')

  # 9. large dimensions
  $big = Join-Path $tmp 'big shot.png'; Png $big 8000 5000 ([Drawing.Color]::White)
  $env:EVIDENCE_TEST_CLIPBOARD = $big
  $r = Ev stage
  Check 'large image staged intact' ($r.code -eq 0 -and (Field $r 'SIZE') -eq '8000x5000' -and (Field $r 'SHA256') -eq (Sha $big))
} finally {
  Pop-Location
  Remove-Item Env:EVIDENCE_TEST_CLIPBOARD, Env:EVIDENCE_STAGING -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $tmp -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
  Remove-Item -LiteralPath $tmp -Recurse -Force
}
if ($fails) { "$fails failed"; exit 1 } else { 'all passed' }
