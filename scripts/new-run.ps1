# usage:  .\new-run.ps1 <name>
# creates runs\<YYYYMMDD>-<name>\ with sim\ subdir, 00-brief.md from template, journal.md
param(
  [Parameter(Mandatory=$true)][string]$Name
)

$ErrorActionPreference = 'Stop'
$root = 'D:\Projects\aspen-agent'
$runId = (Get-Date -Format 'yyyyMMdd') + '-' + $Name
$runDir = Join-Path $root ('runs\' + $runId)

if (Test-Path $runDir) {
  Write-Error "run already exists: $runDir"
  exit 1
}

New-Item -ItemType Directory -Path $runDir | Out-Null
New-Item -ItemType Directory -Path (Join-Path $runDir 'sim') | Out-Null

$briefTpl = Join-Path $root 'templates\00-brief.md'
$briefDst = Join-Path $runDir '00-brief.md'
Copy-Item $briefTpl $briefDst

$journalDst = Join-Path $runDir 'journal.md'
Set-Content -LiteralPath $journalDst -Encoding UTF8 -Value @(
  '## journal',
  '',
  '| 时间 | 事件 | 角色 | 状态/备注 |',
  '|---|---|---|---|'
)

Write-Host "created: $runDir"
Write-Host '  00-brief.md  <- fill in task requirements'
Write-Host '  journal.md   <- orchestration log (main agent appends)'
Write-Host '  sim\         <- aspen files go here (modeler)'
Write-Host 'next: fill 00-brief.md, then start aspen-designer'
