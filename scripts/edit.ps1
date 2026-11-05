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
try { [Console]::InputEncoding = [Text.Encoding]::UTF8 } catch { }
$root = Split-Path -Parent $PSScriptRoot
$config = Join-Path $root 'src\card.toml'

if (-not (Test-Path -LiteralPath $config)) {
    Write-Host "Missing $config" -ForegroundColor Red
    exit 1
}

# Pull latest version from GitHub so we are always editing the freshest card
Push-Location $root
try {
    Write-Host "Синхронизация с GitHub..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'sync.ps1')
}
catch {
    Write-Warning "Initial sync warning: $_"
}
finally {
    Pop-Location
}

if (-not $Editor) {
    $Editor = if (Get-Command code -ErrorAction SilentlyContinue) { 'code' } else { 'notepad' }
}

$before = Get-Content -LiteralPath $config -Raw -Encoding UTF8

Write-Host ""
Write-Host "Открытие $config в $Editor..." -ForegroundColor Cyan
if ($Editor -eq 'notepad') {
    Write-Host ">>> ВНИМАНИЕ: сохраните файл (Ctrl+S) в Блокноте перед его закрытием! <<<" -ForegroundColor Yellow
}
Write-Host ""

if ($Editor -eq 'notepad') {
    Start-Process notepad -ArgumentList "`"$config`"" -Wait
} else {
    # code --wait blocks until the editor window is closed
    Start-Process $Editor -ArgumentList '--wait', "`"$config`"" -Wait
}

$after = Get-Content -LiteralPath $config -Raw -Encoding UTF8

# Проверяем изменения:
# 1) Изменился ли файл во время текущей сессии ($before -ne $after)
# 2) Либо в файле уже есть незакоммиченные правки относительно git HEAD
$hasSessionEdits = ($before -ne $after)
$hasGitEdits = $false
Push-Location $root
try {
    $diff = git diff HEAD -- src/card.toml
    if ($diff) { $hasGitEdits = $true }
}
finally {
    Pop-Location
}

if (-not $hasSessionEdits -and -not $hasGitEdits) {
    Write-Host ""
    Write-Host "В файле src/card.toml изменений не обнаружено." -ForegroundColor Yellow
    Write-Host "Пересобрать карточку и обновить статистику всё равно? [y/N] " -NoNewline -ForegroundColor Yellow
    $force = Read-Host
    if ($force -notmatch '^(y|yes|д|да)$') {
        Write-Host "Выход без изменений." -ForegroundColor Gray
        exit 0
    }
}
elseif ($hasSessionEdits) {
    Write-Host "Изменения в src/card.toml сохранены." -ForegroundColor Green
}
elseif ($hasGitEdits) {
    Write-Host "Обнаружены незакоммиченные изменения в src/card.toml." -ForegroundColor Green
}

Push-Location $root
try {
    Write-Host ""
    Write-Host "Обновление статистики и сборка SVG..." -ForegroundColor Cyan
    # Fresh numbers before the preview; failure just keeps the previous stats.
    python scripts\fetch_stats.py
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[Инфо] Статистика оставлена без изменений (лимит запросов GitHub). Текст карточки собирается штатно." -ForegroundColor Yellow
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
Write-Host "Опубликовать на GitHub? [y/N] " -NoNewline -ForegroundColor Yellow
$answer = Read-Host
if ($answer -notmatch '^(y|yes|д|да)$') {
    Write-Host "Сохранено локально, не опубликовано. Для публикации запустите scripts\publish.ps1"
    exit 0
}

& (Join-Path $PSScriptRoot 'publish.ps1') -Message "content: update card text" -NoFetch