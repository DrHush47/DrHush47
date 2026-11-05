#requires -Version 5.1
<#
  Interactive edit flow: open src/card.toml, rebuild both SVGs, publish on "y".

  Called by card.cmd, but works standalone:
    .\scripts\edit.ps1
    .\scripts\edit.ps1 -Editor notepad
#>
[CmdletBinding()]
param(
    [string]$Editor = ""
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = Split-Path -Parent $PSScriptRoot
$config = Join-Path $root 'src\card.toml'

if (-not (Test-Path -LiteralPath $config)) {
    Write-Host "Missing $config" -ForegroundColor Red
    exit 1
}

if (-not $Editor) {
    $Editor = if (Get-Command code -ErrorAction SilentlyContinue) { 'code' } else { 'notepad' }
}

$before = Get-Content -LiteralPath $config -Raw -Encoding UTF8

Write-Host "Editing $config ..." -ForegroundColor Cyan
if ($Editor -eq 'notepad') {
    Start-Process notepad -ArgumentList "`"$config`"" -Wait
} else {
    # code --wait blocks until the editor window is closed
    Start-Process $Editor -ArgumentList '--wait', "`"$config`"" -Wait
}

$after = Get-Content -LiteralPath $config -Raw -Encoding UTF8
if ($before -eq $after) {
    Write-Host "No changes. Nothing to do."
    exit 0
}

Push-Location $root
try {
    # Fresh numbers before the preview; failure just keeps the previous stats.
    python scripts\fetch_stats.py
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Stats refresh failed - previewing the previous src\stats.json." -ForegroundColor Yellow
    }
    python scripts\build.py
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed - fix src/card.toml and try again." -ForegroundColor Red
        exit 1
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "Publish to GitHub? [y/N] " -NoNewline -ForegroundColor Yellow
$answer = Read-Host
if ($answer -notmatch '^(y|yes|д|да)$') {
    Write-Host "Saved locally, not published. Run .\scripts\publish.ps1 when ready."
    exit 0
}

& (Join-Path $PSScriptRoot 'publish.ps1') -Message "content: update card text"
