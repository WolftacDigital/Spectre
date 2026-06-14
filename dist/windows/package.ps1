# Packages a Spectre portable release zip from zig-out.
# Run AFTER a ReleaseFast build:
#   zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
# Usage: powershell -ExecutionPolicy Bypass -File package.ps1 [-Version 0.1.0]
param(
    [string]$Version = '0.1.0',
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')),
    [string]$OutDir = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'dist-out')
)

$ErrorActionPreference = 'Stop'
$zigOut = Join-Path $RepoRoot 'zig-out'
$exe = Join-Path $zigOut 'bin\spectre.exe'
if (-not (Test-Path $exe)) { throw "spectre.exe not found at $exe - build first." }

$staging = Join-Path $OutDir "spectre-$Version-x64"
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force "$staging\bin" | Out-Null

# The exe expects resources at ..\share\ghostty relative to bin\ -
# keep that layout in the portable zip. (The 'ghostty' directory name
# is an internal resources-dir convention shared with upstream; do not
# rename it.)
Copy-Item $exe "$staging\bin\"
Copy-Item (Join-Path $zigOut 'share') "$staging\share" -Recurse

# Docs
Copy-Item (Join-Path $RepoRoot 'LICENSE') $staging -ErrorAction SilentlyContinue
Set-Content "$staging\README-SPECTRE.txt" @"
Spectre $Version - a fast, native Windows terminal built on Ghostty's core.

Portable install:
  1. Extract this folder anywhere (e.g. %LOCALAPPDATA%\Spectre).
  2. Run bin\spectre.exe.
  3. Optional: run install.ps1 to create a Start Menu shortcut and add
     spectre to your PATH.

Config: %LOCALAPPDATA%\spectre\config (Ghostty config syntax; an
existing %LOCALAPPDATA%\ghostty\config is honored as a fallback).
Themes: spectre +list-themes

Lineage: fork of InsipidPoint/ghostty-windows, itself a fork of
ghostty-org/ghostty by Mitchell Hashimoto. MIT License.

Note: binaries are unsigned. Windows SmartScreen may warn on first
run of a downloaded copy - use 'More info' -> 'Run anyway', or
Unblock-File the zip before extracting.
"@
Copy-Item (Join-Path $PSScriptRoot 'install.ps1') $staging

# Brand assets installed by install.ps1: fonts, theme, default config.
$distRoot = Join-Path $RepoRoot 'dist'
if (Test-Path (Join-Path $distRoot 'fonts')) {
    Copy-Item (Join-Path $distRoot 'fonts') $staging -Recurse -Force
}
if (Test-Path (Join-Path $distRoot 'themes')) {
    Copy-Item (Join-Path $distRoot 'themes') $staging -Recurse -Force
}
if (Test-Path (Join-Path $distRoot 'spectre-default-config')) {
    Copy-Item (Join-Path $distRoot 'spectre-default-config') $staging -Force
}

$zip = Join-Path $OutDir "spectre-$Version-x64.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path "$staging\*" -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
Set-Content "$zip.sha256" "$hash  spectre-$Version-x64.zip"
"Packaged: $zip"
"SHA256:   $hash"
