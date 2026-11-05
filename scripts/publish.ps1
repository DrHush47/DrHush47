#requires -Version 5.1
<#
  Validates the SVG cards and publishes them to the profile repo.

  Usage:
    .\scripts\publish.ps1                       # validate, commit, push
    .\scripts\publish.ps1 -DryRun               # validate + show what would change
    .\scripts\publish.ps1 -Message "feat: new bio" -OpenProfile
#>
[CmdletBinding()]
param(
    [string]$Message = "chore: update profile card",
    [switch]$DryRun,
    [switch]$OpenProfile,
    [switch]$NoBuild,
    [switch]$NoFetch
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

try {
    # Sync with GitHub: pull the bot's commits while preserving any uncommitted hand edits.
    if (@(git remote) -contains 'origin') {
        & (Join-Path $PSScriptRoot 'sync.ps1')
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Sync with origin reported issues or remote was unreachable."
        }
    }

    # The SVGs are generated from src/card.toml - never publish a stale card.
    if (-not $NoBuild) {
        if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
            throw "python not found on PATH; install Python 3.11+ or pass -NoBuild"
        }
        # Refresh the numbers first (REST only). A network hiccup must not block
        # a text edit, so a failure only warns and keeps the previous stats.json.
        if (-not $NoFetch) {
            python scripts\fetch_stats.py
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "stats refresh failed - keeping the previous src/stats.json"
            }
        }
        python scripts\build.py
        if ($LASTEXITCODE -ne 0) { throw "scripts/build.py failed" }
    }

    $assets = @('assets/dark_mode.svg', 'assets/light_mode.svg')
    foreach ($asset in $assets) {
        if (-not (Test-Path -LiteralPath $asset)) {
            throw "Missing asset: $asset"
        }

        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load((Resolve-Path -LiteralPath $asset).Path)

        if ($doc.DocumentElement.LocalName -ne 'svg') {
            throw "Root element is not <svg>: $asset"
        }

        # GitHub's HTML sanitizer drops these anyway; fail early instead of
        # silently shipping a broken card.
        if ($doc.SelectNodes("//*[local-name()='script']").Count -gt 0) {
            throw "Found <script> in ${asset}: GitHub strips it, remove it."
        }

        # Namespace-safe: looks at the local name, so xlink:href matches too
        # without having to bind the xlink prefix in XPath.
        foreach ($node in $doc.SelectNodes('//*')) {
            foreach ($attr in $node.Attributes) {
                if ($attr.LocalName -in @('href', 'src')) {
                    if ($attr.Value -match '^(https?:)?//') {
                        throw "External reference in ${asset}: $($attr.Name)=$($attr.Value)"
                    }
                }
            }
        }

        Write-Host ("ok   {0}  ({1:N0} bytes)" -f $asset, (Get-Item -LiteralPath $asset).Length)
    }

    $remotes = @(git remote)
    if ($remotes -notcontains 'origin') {
        throw "No 'origin' remote yet. Run: git remote add origin https://github.com/DrHush47/DrHush47.git"
    }

    git add -A
    $pending = git status --porcelain
    if (-not $pending) {
        Write-Host "Nothing to commit - the card is already up to date."
    }
    elseif ($DryRun) {
        Write-Host "Dry run, would commit:"
        $pending
    }
    else {
        git commit -m $Message
        if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
        $sha = (git rev-parse HEAD).Trim()
        python scripts\build.py --readme-ref $sha
        if (git status --porcelain README.md) {
            git add README.md
            git commit -m "chore: point profile README to $sha"
            if ($LASTEXITCODE -ne 0) { throw "git commit for README failed" }
        }
    }

    if ($DryRun) {
        Write-Host "Dry run: not pushing."
        return
    }

    git push -u origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Push rejected (likely concurrent bot commit on origin). Re-syncing and retrying once..."
        git reset --soft HEAD~1
        & (Join-Path $PSScriptRoot 'sync.ps1')
        if (-not $NoBuild) {
            python scripts\build.py
            if ($LASTEXITCODE -ne 0) { throw "scripts/build.py failed during retry" }
        }
        git add -A
        git commit -m $Message
        if ($LASTEXITCODE -ne 0) { throw "git commit failed during retry" }
        git push -u origin main
        if ($LASTEXITCODE -ne 0) { throw "git push failed after retry" }
    }

    Write-Host "Pushed. https://github.com/DrHush47" -ForegroundColor Green
    Write-Host "Note: GitHub CDN caches profile images for up to 5 minutes. Press Ctrl+F5 in browser." -ForegroundColor Gray
    if ($OpenProfile) { Start-Process 'https://github.com/DrHush47' }
}
finally {
    Pop-Location
}
