<#
.SYNOPSIS
  Initialize a new Aspen modeling run (creates runs\<RunId>\ with state.json and
  artifact skeletons copied from templates\).

  ASCII-only by design: this file must parse correctly under Windows PowerShell 5.1
  regardless of the console code page. All Chinese-language content lives in templates\.

.EXAMPLE
  .\scripts\new-run.ps1 -RunId 20260804-etoh-flash -Title "ethanol-water flash" -Level L1
  .\scripts\new-run.ps1 -Title "ethanol-water flash"
#>
param(
  [string]$RunId,
  [Parameter(Mandatory = $true)][string]$Title,
  [ValidateSet('L1', 'L2', 'L3', '')][string]$Level = ''
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$tpl = Join-Path $repo 'templates'

if (-not $RunId) {
  $slug = (($Title -replace '[^\w\-]', '-') -replace '-+', '-').Trim('-').ToLower()
  $RunId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd'), $slug
}

$runDir = Join-Path $repo "runs\$RunId"

if (Test-Path $runDir) {
  Write-Host "Run already exists: $runDir" -ForegroundColor Yellow
  Write-Host "Resume from its state.json; nothing overwritten." -ForegroundColor Yellow
  Get-Content (Join-Path $runDir 'state.json') -Raw -Encoding UTF8
  return
}

New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$apwPath = Join-Path $runDir 'model.apw'

$state = [ordered]@{
  run_id    = $RunId
  title     = $Title
  level     = $Level
  phase     = 'A'
  gate      = 'pending'
  iter      = [ordered]@{ B = 0; C = 0; D = 0 }
  rollback  = 0
  apw_path  = $apwPath
  artifacts = @('00-brief.md')
  blockers  = @()
  pending   = @()
  updated   = (Get-Date -Format 's')
}
$state | ConvertTo-Json -Depth 5 |
  Set-Content -Path (Join-Path $runDir 'state.json') -Encoding UTF8

# Copy artifact skeletons. 00-brief.md gets its header filled in.
foreach ($f in @('00-brief.md', 'A-plan.md', 'HANDOVER.md')) {
  $src = Join-Path $tpl $f
  if (Test-Path $src) {
    Copy-Item $src (Join-Path $runDir $f)
  }
  else {
    Write-Host "WARNING: template missing: $src" -ForegroundColor Yellow
  }
}

# Template line layout: 0 = title, 2 = run-id, 3 = created. Patched by index to stay ASCII-only.
$brief = Join-Path $runDir '00-brief.md'
if (Test-Path $brief) {
  $lines = @(Get-Content $brief -Encoding UTF8)
  if ($lines.Count -ge 4) {
    $lines[0] = '# ' + $Title
    $lines[2] = '- run-id: ' + $RunId
    $lines[3] = '- created: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
    Set-Content -Path $brief -Value $lines -Encoding UTF8
  }
  else {
    Write-Host 'WARNING: templates\00-brief.md layout changed; header not patched.' -ForegroundColor Yellow
  }
}

Write-Host "Created run: $runDir" -ForegroundColor Green
Write-Host "  model path: $apwPath"
Write-Host "  next: fill in 00-brief.md, then dispatch aspen-designer for phase A"
