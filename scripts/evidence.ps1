# Evidence Capture: stage a screenshot immutably, attach it to a project step, keep a hash-checked trail.
# Usage: pwsh -NoProfile -STA -File evidence.ps1 <stage|list|attach|discard|check> [options]
# Every result starts with "STATUS: <word>" followed by "KEY: value" lines. Non-zero exit on failure.
[CmdletBinding()]
param(
  [Parameter(Position = 0, Mandatory)][ValidateSet('stage', 'list', 'attach', 'discard', 'check')][string]$Command,
  [string]$File, [string]$Id, [string]$Step, [string]$Description,
  [ValidateSet('pass', 'fail')][string]$Verification, [string]$Doc,
  [switch]$Confirmed, [switch]$Overwrite, [switch]$All,
  [string]$Project = (Get-Location).Path
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
# ponytail: one fixed staging dir outside every repo, so staged captures can never be committed
$Staging = if ($env:EVIDENCE_STAGING) { $env:EVIDENCE_STAGING } else { Join-Path $HOME '.claude\evidence\staging' }
$Project = [IO.Path]::GetFullPath($Project).TrimEnd('\')
$File = "$File".Trim().Trim('"', "'")  # a path pasted after /evidence:capture often keeps its quotes
$ImageExts = '.png', '.jpg', '.jpeg', '.gif', '.bmp'

function Out-Status([string]$Status, [Collections.IDictionary]$Fields = @{}, [int]$Code = 0) {
  "STATUS: $Status"
  foreach ($k in $Fields.Keys) { "${k}: $($Fields[$k])" }
  exit $Code
}
function Fail([string]$Status, [string]$Message, [int]$Code) { Out-Status $Status ([ordered]@{ MESSAGE = $Message }) $Code }
function Sha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() }
function Unlock([string]$Path) { if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).IsReadOnly = $false } }

# "WxH", or $null if the file is not a readable image. Reads the header only, so huge images are cheap.
function Get-ImageSize([string]$Path) {
  $fs = $null; $img = $null
  try { $fs = [IO.File]::OpenRead($Path); $img = [Drawing.Image]::FromStream($fs, $false, $false); "$($img.Width)x$($img.Height)" }
  catch { $null }
  finally { if ($img) { $img.Dispose() }; if ($fs) { $fs.Dispose() } }
}

# Writes the clipboard image to $Dest. Returns $null on success, else why there was no image.
# The clipboard is read exactly once, here; nothing else in this script touches it.
function Save-Clipboard([string]$Dest) {
  if ($env:EVIDENCE_TEST_CLIPBOARD) {  # ponytail: test seam - an image path, or EMPTY
    if ($env:EVIDENCE_TEST_CLIPBOARD -eq 'EMPTY') { return 'The clipboard is empty.' }
    Copy-Item -LiteralPath $env:EVIDENCE_TEST_CLIPBOARD $Dest; return $null
  }
  Add-Type -AssemblyName System.Windows.Forms
  if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { return 'Clipboard access needs an STA thread: run pwsh with -STA.' }
  # GetDataObject is a live view, not a snapshot: whichever format is read first is the capture.
  $data = [Windows.Forms.Clipboard]::GetDataObject()
  if (-not $data) { return 'The clipboard is empty.' }
  $png = $data.GetData('PNG')  # lossless stream some apps (browsers, Snipping Tool) provide
  if ($png -is [IO.MemoryStream]) { [IO.File]::WriteAllBytes($Dest, $png.ToArray()); return $null }
  $img = $data.GetData([Windows.Forms.DataFormats]::Bitmap, $true)
  if ($img -is [Drawing.Image]) {
    try { $img.Save($Dest, [Drawing.Imaging.ImageFormat]::Png) } finally { $img.Dispose() }
    return $null
  }
  if ($data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { return 'The clipboard holds copied files, not an image. Pass the file path instead.' }
  'The clipboard has no image.'
}

function Get-Staged([string]$StageId) {
  if ($StageId -notmatch '^\d{8}-\d{6}-\d{3}-[0-9a-f]{4}$') { Fail NOT_FOUND "Not a staged capture id: '$StageId'." 4 }
  $json = Join-Path $Staging "$StageId.json"
  if (-not (Test-Path -LiteralPath $json)) { Fail NOT_FOUND "No staged capture '$StageId' (discarded or already attached)." 4 }
  Get-Content -Raw -LiteralPath $json | ConvertFrom-Json -DateKind String
}

# Project-relative config path -> absolute path, refusing anything that escapes the project.
function Resolve-Inside([string]$Rel) {
  $full = [IO.Path]::GetFullPath($Rel, $Project)
  if (-not $full.StartsWith("$Project\", [StringComparison]::OrdinalIgnoreCase)) { Fail BAD_CONFIG "'$Rel' is outside the project." 9 }
  $full
}

function Get-Config {
  $path = Join-Path $Project '.claude\evidence.json'
  $cfg = @{}
  if (Test-Path -LiteralPath $path) {
    try { $cfg = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable } catch { Fail BAD_CONFIG ".claude/evidence.json is not valid JSON." 9 }
  }
  $dir = $cfg.evidenceDir
  if (-not $dir) {  # follow an existing convention before inventing one
    $dir = @('docs/images', 'docs/img', 'docs/screenshots', 'images') | Where-Object { Test-Path -LiteralPath (Join-Path $Project $_) -PathType Container } | Select-Object -First 1
    if (-not $dir) { $dir = 'docs/images' }
  }
  $records = if ($cfg.records) { $cfg.records } else { [IO.Path]::Combine([IO.Path]::GetDirectoryName($dir), 'evidence.jsonl') }
  @{ evidenceDir = $dir; records = $records }
}

function Rel([string]$From, [string]$To) { [IO.Path]::GetRelativePath($From, $To).Replace('\', '/') }

switch ($Command) {
  'stage' {
    New-Item -ItemType Directory -Force $Staging | Out-Null
    $stageId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('n').Substring(0, 4)
    $capturedAt = [DateTimeOffset]::Now
    if ($File) {
      if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Fail NOT_FOUND "No file at '$File'." 4 }
      $ext = [IO.Path]::GetExtension($File).ToLower()
      if ($ext -notin $ImageExts -or -not (Get-ImageSize $File)) { Fail NOT_IMAGE "'$File' is not a PNG, JPG, GIF or BMP image." 5 }
      $staged = Join-Path $Staging "$stageId$ext"
      Copy-Item -LiteralPath $File $staged
      $source = 'file'; $original = Split-Path -Leaf $File
    } else {
      $staged = Join-Path $Staging "$stageId.png"
      $why = Save-Clipboard $staged
      if ($why) { Fail NO_IMAGE "$why Copy a screenshot (Win+Shift+S) and run capture again. Nothing was staged." 2 }
      $source = 'clipboard'; $original = $null
    }
    $size = Get-ImageSize $staged
    if (-not $size) { Remove-Item -LiteralPath $staged; Fail NOT_IMAGE 'The captured data is not a readable image. Nothing was staged.' 5 }
    $sha = Sha $staged
    (Get-Item -LiteralPath $staged).IsReadOnly = $true
    [ordered]@{
      id = $stageId; file = Split-Path -Leaf $staged; sha256 = $sha; size = $size; bytes = (Get-Item -LiteralPath $staged).Length
      source = $source; original = $original; captured_at = $capturedAt.ToString('o'); timezone = [TimeZoneInfo]::Local.Id
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Staging "$stageId.json")
    Out-Status STAGED ([ordered]@{ ID = $stageId; STAGED = $staged; SHA256 = $sha; SIZE = $size; SOURCE = $source; CAPTURED_AT = $capturedAt.ToString('o') })
  }

  'list' {
    $items = @(if (Test-Path -LiteralPath $Staging) { Get-ChildItem -LiteralPath $Staging -Filter *.json | Sort-Object Name })
    foreach ($j in $items) { $m = Get-Content -Raw -LiteralPath $j.FullName | ConvertFrom-Json -DateKind String; "$($m.id)  $($m.captured_at)  $($m.source)  $($m.size)  $(Join-Path $Staging $m.file)" }
    Out-Status OK ([ordered]@{ COUNT = $items.Count; STAGING = $Staging })
  }

  'attach' {
    if (-not $Id -or -not $Step -or -not $Description) { Fail USAGE 'attach needs -Id, -Step and -Description.' 64 }
    $meta = Get-Staged $Id
    if (-not $Confirmed) { Fail NOT_CONFIRMED 'Preview the staged image and confirm it is the right one, then pass -Confirmed.' 6 }
    if ($Step -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Fail BAD_STEP "Step '$Step' may only use letters, digits, '.', '_' and '-'." 64 }
    $staged = Join-Path $Staging $meta.file
    if (-not (Test-Path -LiteralPath $staged) -or (Sha $staged) -ne $meta.sha256) { Fail STAGED_CHANGED 'The staged file no longer matches its recorded hash. Discard it and capture again.' 7 }

    $cfg = Get-Config
    $dir = Resolve-Inside $cfg.evidenceDir
    $records = Resolve-Inside $cfg.records
    $slug = ($Description.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    $ext = [IO.Path]::GetExtension($meta.file)
    $dest = Join-Path $dir ($(if ($slug) { "$Step-$slug" } else { $Step }) + $ext)
    $rel = Rel $Project $dest

    New-Item -ItemType Directory -Force $dir | Out-Null
    $replaced = $null
    if (Test-Path -LiteralPath $dest) {
      if (-not $Overwrite) { Out-Status EXISTS ([ordered]@{ PATH = $rel; MESSAGE = 'Evidence already exists there. Nothing was changed; the staged copy is kept. Re-run with -Overwrite only if the user approves replacing it.' }) 3 }
      $replaced = Sha $dest
      Unlock $dest
    }
    try { [IO.File]::Copy($staged, $dest, [bool]$Overwrite) }  # no-overwrite copy fails atomically if the name was just taken
    catch [IO.IOException] { Out-Status EXISTS ([ordered]@{ PATH = $rel; MESSAGE = 'Evidence already exists there. Nothing was changed.' }) 3 }
    Unlock $dest
    if ((Sha $dest) -ne $meta.sha256) { Fail COPY_FAILED "The copy at $rel does not match the staged hash." 7 }

    $record = [ordered]@{
      captured_at = $meta.captured_at; timezone = $meta.timezone; attached_at = [DateTimeOffset]::Now.ToString('o')
      source = $meta.source; original = $meta.original; path = $rel; sha256 = $meta.sha256; size = $meta.size; bytes = $meta.bytes
      step = $Step; description = $Description
      confirmed = $true                                           # the user confirmed this is the right image
      verification = $(if ($Verification) { $Verification } else { $null })  # separate: did the underlying config check out
    }
    if ($replaced) { $record.replaced_sha256 = $replaced }
    New-Item -ItemType Directory -Force (Split-Path -Parent $records) | Out-Null
    [IO.File]::AppendAllText($records, ($record | ConvertTo-Json -Compress) + "`n")

    Unlock $staged
    Remove-Item -LiteralPath $staged, (Join-Path $Staging "$Id.json")
    $linkBase = if ($Doc) { Split-Path -Parent ([IO.Path]::GetFullPath($Doc, $Project)) } else { $Project }
    $alt = "${Step}: $Description" -replace '([\[\]])', '\$1'
    Out-Status ATTACHED ([ordered]@{
        PATH = $rel; SHA256 = $meta.sha256; RECORD = Rel $Project $records
        LINK = "![$alt]($((Rel $linkBase $dest).Replace(' ', '%20')))"; CAPTION = "*${Step}: $($Description -replace '\*', '\*')*"
      })
  }

  'discard' {
    if ($All) { $ids = @(if (Test-Path -LiteralPath $Staging) { Get-ChildItem -LiteralPath $Staging -Filter *.json | ForEach-Object BaseName }) }
    elseif ($Id) { $null = Get-Staged $Id; $ids = @($Id) }
    else { Fail USAGE 'discard needs -Id <id> or -All.' 64 }
    foreach ($i in $ids) {
      Get-ChildItem -LiteralPath $Staging -File | Where-Object { $_.BaseName -eq $i } | ForEach-Object { $_.IsReadOnly = $false; Remove-Item -LiteralPath $_.FullName }
    }
    Out-Status DISCARDED ([ordered]@{ COUNT = $ids.Count })
  }

  'check' {
    $records = Resolve-Inside (Get-Config).records
    if (-not (Test-Path -LiteralPath $records)) { Fail NO_RECORDS "No evidence records at $(Rel $Project $records)." 4 }
    $latest = [ordered]@{}  # a later record for the same path (an approved overwrite) supersedes earlier ones
    foreach ($line in Get-Content -LiteralPath $records) {
      if ($line.Trim()) { $e = $line | ConvertFrom-Json -DateKind String; $latest[$e.path] = $e }
    }
    $bad = 0
    foreach ($e in $latest.Values) {
      $full = Resolve-Inside $e.path
      if (-not (Test-Path -LiteralPath $full)) { "MISSING  $($e.path)"; $bad++ }
      elseif ((Sha $full) -ne $e.sha256) { "MISMATCH $($e.path)"; $bad++ }
      else { "OK       $($e.path)" }
    }
    Out-Status $(if ($bad) { 'FAILED' } else { 'OK' }) ([ordered]@{ CHECKED = $latest.Count; PROBLEMS = $bad }) $(if ($bad) { 8 } else { 0 })
  }
}
