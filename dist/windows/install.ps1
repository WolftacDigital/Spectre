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

# Copy payload (skip if installing in place). Windows PowerShell 5.1
# compatible - no null-conditional operator.
$resolvedDest = if (Test-Path $Dest) { (Resolve-Path $Dest).Path } else { $null }
if ((Resolve-Path $Source).Path -ne $resolvedDest) {
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

# --- Brand fonts (IBM Plex Mono + Chakra Petch), user-level, no admin ---
$fontSrc = Join-Path $Source 'fonts'
if (Test-Path $fontSrc) {
    $fontDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts'
    New-Item -ItemType Directory -Force $fontDir | Out-Null
    $regKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts'
    Add-Type -Namespace W -Name F -MemberDefinition '[DllImport("gdi32.dll")] public static extern int AddFontResourceW([MarshalAs(UnmanagedType.LPWStr)] string p);'
    $names = @{
        'IBMPlexMono-Regular.ttf'  = 'IBM Plex Mono (TrueType)'
        'IBMPlexMono-Medium.ttf'   = 'IBM Plex Mono Medium (TrueType)'
        'IBMPlexMono-SemiBold.ttf' = 'IBM Plex Mono SemiBold (TrueType)'
        'ChakraPetch-Regular.ttf'  = 'Chakra Petch (TrueType)'
        'ChakraPetch-Medium.ttf'   = 'Chakra Petch Medium (TrueType)'
        'ChakraPetch-SemiBold.ttf' = 'Chakra Petch SemiBold (TrueType)'
    }
    foreach ($f in $names.Keys) {
        $ttf = Join-Path $fontSrc $f
        if (Test-Path $ttf) {
            $dst = Join-Path $fontDir $f
            Copy-Item $ttf $dst -Force
            [void][W.F]::AddFontResourceW($dst)
            New-ItemProperty -Path $regKey -Name $names[$f] -Value $dst -PropertyType String -Force | Out-Null
        }
    }
    "Installed brand fonts (IBM Plex Mono, Chakra Petch)."
}

# --- Wolftac theme (so `theme = Wolftac` works) ---
$themeSrc = Join-Path $Source 'themes\Wolftac'
if (Test-Path $themeSrc) {
    $themeDst = Join-Path $env:LOCALAPPDATA 'ghostty\themes'
    New-Item -ItemType Directory -Force $themeDst | Out-Null
    Copy-Item $themeSrc $themeDst -Force
}

# --- Default brand config on first install (never overwrite an existing one) ---
$cfgDir = Join-Path $env:LOCALAPPDATA 'spectre'
$cfg = Join-Path $cfgDir 'config'
$cfgSrc = Join-Path $Source 'spectre-default-config'
if ((Test-Path $cfgSrc) -and -not (Test-Path $cfg)) {
    New-Item -ItemType Directory -Force $cfgDir | Out-Null
    Copy-Item $cfgSrc $cfg -Force
    "Wrote default Wolftac config to $cfg"
}

"Installed Spectre to $Dest"
"Start Menu shortcut created. Run 'spectre' from a new shell, or launch from Start."
