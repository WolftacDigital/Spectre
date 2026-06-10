# Installs Spectre from an extracted portable folder (or this folder)
# into %LOCALAPPDATA%\Spectre, creates a Start Menu shortcut, and adds
# the bin directory to the user PATH.
# Usage: powershell -ExecutionPolicy Bypass -File install.ps1
param(
    [string]$Source = $PSScriptRoot,
    [string]$Dest = (Join-Path $env:LOCALAPPDATA 'Spectre')
)

$ErrorActionPreference = 'Stop'
$exe = Join-Path $Source 'bin\spectre.exe'
if (-not (Test-Path $exe)) { throw "bin\spectre.exe not found under $Source" }

# Copy payload (skip if installing in place)
if ((Resolve-Path $Source).Path -ne (Resolve-Path -ErrorAction SilentlyContinue $Dest)?.Path) {
    New-Item -ItemType Directory -Force $Dest | Out-Null
    Copy-Item "$Source\bin" $Dest -Recurse -Force
    Copy-Item "$Source\share" $Dest -Recurse -Force
}

# Start Menu shortcut
$ws = New-Object -ComObject WScript.Shell
$lnkDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$lnk = $ws.CreateShortcut((Join-Path $lnkDir 'Spectre.lnk'))
$lnk.TargetPath = Join-Path $Dest 'bin\spectre.exe'
$lnk.WorkingDirectory = $env:USERPROFILE
$lnk.Description = 'Spectre terminal emulator'
$lnk.Save()

# User PATH
$binDir = Join-Path $Dest 'bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$binDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$binDir", 'User')
    "Added $binDir to user PATH (open a new shell to pick it up)."
}

"Installed Spectre to $Dest"
"Start Menu shortcut created. Run 'spectre' from a new shell, or launch from Start."
