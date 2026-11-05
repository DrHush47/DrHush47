#requires -Version 5.1
<#
  Moves the local repo onto the latest origin/main while keeping hand edits.

  Why: the "refresh card" workflow commits regenerated files after every push
  and once a day. Merging those files is where conflicts came from, so they
  are never merged here:

    1. git fetch origin
    2. every hand edit since the common base (committed-but-unpushed AND
       uncommitted, generated files excluded) is saved as a patch
       (a copy is kept in .git/sync-backups/);
    3. git reset --hard origin/main;
    4. the patch is re-applied on top.

  Generated files (SVGs, stats.json) end up exactly as on GitHub; the caller
  rebuilds them from the synced sources. The bot only writes generated files,
  so step 4 cannot conflict with it. It can only conflict if the same source
  lines were also changed elsewhere (e.g. card.toml edited on github.com).

  Exit codes: 0 synced, 1 error (repo left untouched or patch kept),
              2 origin unreachable (nothing changed).

  Usage:  .\scripts\sync.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$generated = @('assets/dark_mode.svg', 'assets/light_mode.svg', 'src/stats.json', 'README.md')

function Fail([string]$msg) {
    Write-Host $msg -ForegroundColor Red
    exit 1
}

Push-Location $root
try {
    if (@(git remote) -notcontains 'origin') {
        Fail "No 'origin' remote. Run: git remote add origin https://github.com/DrHush47/DrHush47.git"
    }

    $gitDir = (git rev-parse --git-dir)
    foreach ($marker in 'rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD') {
        if (Test-Path -LiteralPath (Join-Path $gitDir $marker)) {
            Fail "A git $marker is in progress. Finish or abort it first (git rebase --abort / git merge --abort)."
        }
    }

    $branch = (git symbolic-ref --quiet --short HEAD)
    if ($branch -ne 'main') {
        Fail "Expected to be on branch 'main', found '$branch'. Run: git checkout main"
    }

    git fetch origin --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not reach GitHub (git fetch failed) - nothing synced." -ForegroundColor Yellow
        exit 2
    }

    $upstream = 'origin/main'
    $head = (git rev-parse HEAD)
    $remote = (git rev-parse $upstream)
    $base = (git merge-base HEAD $upstream)
    if ($LASTEXITCODE -ne 0 -or -not $base) { Fail "No common history between main and $upstream." }

    # Hand edits = working tree vs the common base, minus generated files.
    # --output writes raw bytes (PowerShell's '>' would re-encode to UTF-16).
    $exclude = $generated | ForEach-Object { ":(exclude)$_" }
    $backupDir = Join-Path $gitDir 'sync-backups'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $patch = Join-Path $backupDir ("{0:yyyyMMdd-HHmmss}.patch" -f (Get-Date))
    git diff --binary --full-index "--output=$patch" $base -- . @exclude
    if ($LASTEXITCODE -ne 0) { Fail "git diff failed; nothing changed." }
    $hasEdits = (Get-Item -LiteralPath $patch).Length -gt 0

    if ($head -eq $remote) {
        if ($hasEdits) {
            Remove-Item -LiteralPath $patch -ErrorAction SilentlyContinue
        }
        Write-Host "Up to date with $upstream."
        exit 0
    }

    git reset --hard --quiet $upstream
    if ($LASTEXITCODE -ne 0) { Fail "git reset failed. Your edits are saved in $patch" }

    if ($hasEdits) {
        git apply --3way --whitespace=nowarn $patch
        if ($LASTEXITCODE -ne 0) {
            Fail ("Your edits clash with a change made on GitHub to the same lines.`n" +
                  "Conflict markers are in the files listed above; full copy of your edits: $patch")
        }
        # --3way stages what it applies; keep the index clean like a normal edit.
        git reset --quiet
        Remove-Item -LiteralPath $patch -ErrorAction SilentlyContinue
    }

    Write-Host ("Synced with {0} ({1})." -f $upstream, (git log -1 --format='%h %s' $upstream))
    exit 0
}
finally {
    Pop-Location
}
