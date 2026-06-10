# Spectre upstream sync (see UPSTREAM.md for the full playbook).
# Report-only by default. ASCII-only, Windows PowerShell 5.1 compatible.
#
#   sync-upstream.ps1          -> fetch + report
#   sync-upstream.ps1 -Merge   -> also merge insipid/main into main
#   sync-upstream.ps1 -Build   -> also rebuild + smoke test
#   sync-upstream.ps1 -Merge -Build  -> full sync
param(
    [switch]$Merge,
    [switch]$Build,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')),
    [string]$ZigDir = 'D:\Wolftac\tools\zig-x86_64-windows-0.15.2',
    [string]$ZigCache = 'D:\Wolftac\tools\zig-global-cache'
)

$ErrorActionPreference = 'Stop'
Set-Location $RepoRoot

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# Refuse to run on a dirty tree - merges and dirty trees do not mix.
if (git status --porcelain) { Fail 'working tree is dirty; commit or stash first.' }
$branch = git branch --show-current
if ($branch -ne 'main') { Fail "on branch '$branch'; sync runs from main." }

Write-Host '== Fetching insipid + ghostty ==' -ForegroundColor Cyan
git fetch insipid 2>&1 | Out-Null
git fetch ghostty 2>&1 | Out-Null

$incoming = [int](git rev-list --count main..insipid/main)
$ours = [int](git rev-list --count insipid/main..main)
$mb = git merge-base insipid/main ghostty/main
$mbDate = [DateTime](git log -1 --format=%cI $mb)
$drift = [int](git rev-list --count "$mb..ghostty/main")
$staleDays = [int]((Get-Date) - $mbDate).TotalDays

Write-Host ''
Write-Host '== Sync report ==' -ForegroundColor Cyan
Write-Host "insipid/main -> main: $incoming new commit(s) to merge"
Write-Host "our divergence ahead of insipid: $ours commit(s)"
Write-Host "insipid's last ghostty merge: $($mbDate.ToString('yyyy-MM-dd')) ($staleDays days ago)"
Write-Host "ghostty/main drift past that merge: $drift commit(s)"
if ($staleDays -gt 60) {
    Write-Host 'WARNING: insipid looks stale (>60 days since last ghostty merge).' -ForegroundColor Yellow
    Write-Host 'See "Staleness escape hatch" in UPSTREAM.md before acting.' -ForegroundColor Yellow
}
if ($incoming -gt 0) {
    Write-Host ''
    Write-Host '-- incoming commits --'
    git log --oneline main..insipid/main
}

if ($Merge) {
    if ($incoming -eq 0) {
        Write-Host ''
        Write-Host 'Nothing to merge: already up to date with insipid/main.' -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host '== Merging insipid/main ==' -ForegroundColor Cyan
        git merge insipid/main --no-edit
        if ($LASTEXITCODE -ne 0) {
            Write-Host ''
            Write-Host 'MERGE CONFLICTS. Resolve per UPSTREAM.md conflict policy:' -ForegroundColor Yellow
            Write-Host '  - outside win32/dist/test dirs: keep upstream, re-apply inventory'
            Write-Host '  - src/apprt/win32: keep upstream logic, re-apply Spectre strings'
            Write-Host '  - dist/windows: ours is authoritative'
            git status --short
            exit 1
        }
        Write-Host 'Merged clean.' -ForegroundColor Green
    }
}

if ($Build) {
    Write-Host ''
    Write-Host '== Build + smoke test ==' -ForegroundColor Cyan
    $env:PATH = "$ZigDir;$env:PATH"
    $env:ZIG_GLOBAL_CACHE_DIR = $ZigCache
    zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
    if ($LASTEXITCODE -ne 0) { Fail 'build failed.' }
    $exe = Join-Path $RepoRoot 'zig-out\bin\spectre.exe'
    if (-not (Test-Path $exe)) { Fail 'spectre.exe missing after build.' }
    $themes = (& $exe +list-themes 2>$null | Measure-Object -Line).Lines
    if ($themes -lt 400) { Fail "smoke test: only $themes themes resolved (expect ~500)." }
    Write-Host "Build OK; smoke test OK ($themes themes resolve)." -ForegroundColor Green
    Write-Host 'Remember: rerun the shell matrix if termio/pty/win32 changed (UPSTREAM.md step 5).'
}

Write-Host ''
Write-Host 'Done. Nothing was pushed - review and push manually.' -ForegroundColor Cyan
