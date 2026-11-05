#requires -Version 5.1
<#
  OPTIONAL: renders a base card from the local photo through the public
  gh-ascii deployment (POST /<handle> with a multipart image).

  WARNING: the public generator builds a different right-hand panel
  (Uptime / Languages / GitHub Stats / Last 12 Months). The Name / Bio /
  Contact panel used in assets/ is custom and cannot be produced by the API.
  Output goes to build/ and never overwrites assets/ - treat it as a starting
  point, not as the published card.

  Usage:
    .\scripts\fetch-base.ps1
    .\scripts\fetch-base.ps1 -Theme light -Cols 88
    .\scripts\fetch-base.ps1 -Image C:\path\to\photo.jpg -OutFile build\test.svg
#>
[CmdletBinding()]
param(
    [string]$Image,
    [ValidateSet('dark', 'light')]
    [string]$Theme = 'dark',
    [int]$Cols = 0,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $root 'card.config.json') -Encoding UTF8 | ConvertFrom-Json

if (-not $Image) { $Image = Join-Path $root $config.sourceImage }
if (-not (Test-Path -LiteralPath $Image)) {
    throw "Source image not found: $Image (it is gitignored on purpose, keep it locally)"
}
if ($Cols -le 0) { $Cols = [int]$config.generator.params.cols }
if (-not $OutFile) { $OutFile = Join-Path $root "build\base-$Theme.svg" }

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null

$url = '{0}/{1}' -f $config.generator.url, $config.handle
Write-Host "POST $url  (theme=$Theme cols=$Cols)"
& curl.exe -fsS -X POST $url -F "image=@$Image" -F "theme=$Theme" -F "cols=$Cols" -o $OutFile
if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }

Write-Host ("Wrote {0} ({1:N0} bytes)" -f $OutFile, (Get-Item -LiteralPath $OutFile).Length)
Write-Host "Open scripts/preview.html?file=..\build\$(Split-Path -Leaf $OutFile) to look at it."
