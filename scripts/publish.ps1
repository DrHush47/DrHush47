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
    # The daily workflow commits "chore: refresh stats" on its own, so a plain
    # push would be rejected as non-fast-forward. Sync first, while the working
    # tree is still clean, then rebuild on top of the bot's commit.
    if (@(git remote) -contains 'origin') {
        if (git status --porcelain) {
            Write-Warning "Uncommitted changes present - skipping the sync with origin."
        }
        else {
            git fetch origin --quiet 2>$null
            if ($LASTEXITCODE -eq 0 -and (git rev-parse --verify --quiet origin/main)) {
                git merge --ff-only origin/main --quiet 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Local main diverged from origin/main - fix the branch before publishing."
                }
            }
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
    }

    if ($DryRun) {
        Write-Host "Dry run: not pushing."
        return
    }

    git push -u origin main
    if ($LASTEXITCODE -ne 0) { throw "git push failed" }

    Write-Host "Pushed. https://github.com/DrHush47"
    if ($OpenProfile) { Start-Process 'https://github.com/DrHush47' }
}
finally {
    Pop-Location
}
