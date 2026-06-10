# Spectre build notes (this machine)

Local build environment facts for Spectre (fork of InsipidPoint/ghostty-windows).
Recorded 2026-06-09 after the first successful build.

## Toolchain

- Zig **0.15.2** (exact, pinned) at `D:\Wolftac\tools\zig-x86_64-windows-0.15.2\`.
  Not on PATH globally — prepend per session.

## Build command that works here

```powershell
$env:PATH = "D:\Wolftac\tools\zig-x86_64-windows-0.15.2;$env:PATH"
$env:ZIG_GLOBAL_CACHE_DIR = 'D:\Wolftac\tools\zig-global-cache'
cd D:\Wolftac\Spectre
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
```

Output: `zig-out\bin\spectre.exe` (+ `ghostty-vt.dll`). (Windows builds
are branded Spectre as of Phase 2; non-Windows targets keep the
upstream `ghostty` name.)

## Release packaging

```powershell
zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
powershell -ExecutionPolicy Bypass -File dist\windows\package.ps1 -Version 0.1.0
```

Produces `dist-out\spectre-<ver>-x64.zip` (+ `.sha256`) containing
`bin\spectre.exe`, `share\` resources (themes, shell integration), an
`install.ps1` (Start Menu shortcut + user PATH), and a README. Upload
to a GitHub release with `gh release create`. Scoop/winget manifest
drafts live in `dist\windows\scoop\` and `dist\windows\winget\` —
they need the release assets to be publicly downloadable, so they
stay drafts while the repo is private. Binaries are unsigned;
SmartScreen will warn on downloaded copies (documented in the zip's
README).

## Config paths (Spectre)

`%LOCALAPPDATA%\spectre\config` wins when present; the Ghostty paths
(`%LOCALAPPDATA%\ghostty\config.ghostty`, then `…\ghostty\config`)
remain as compatibility fallbacks. New config templates are created in
the Spectre location. Theme names are display names with capitals and
spaces (`theme = Catppuccin Mocha`); list with `spectre +list-themes`.
Custom user themes still live in `%LOCALAPPDATA%\ghostty\themes`
(deliberately unchanged for now).

## Deviations from the upstream README, and why

1. **`-Dtarget=x86_64-windows-gnu` instead of `x86_64-windows`.**
   The plain target resolves to the `msvc` ABI, which requires Visual Studio /
   Windows SDK (`error: WindowsSdkNotFound`). This machine has neither; the
   `gnu` ABI uses Zig's bundled mingw headers/libc and builds clean. If we
   ever need the msvc ABI (e.g. to match upstream releases), install VS Build
   Tools with the VC workload first.

2. **`ZIG_GLOBAL_CACHE_DIR` must be on the same drive as the checkout.**
   With the default cache on `C:` and the repo on `D:`, Zig 0.15.2's build
   runner panics in `Run.zig convertPathArg`
   (`assert(!std.fs.path.isAbsolute(child_cwd_rel))`) — relative paths can't
   cross drive letters on Windows. Keep the cache at
   `D:\Wolftac\tools\zig-global-cache`.

3. **Dependencies must be seeded manually on this network.**
   The local middlebox resets Zig's native TLS connections (`ConnectionResetByPeer`),
   and `curl` needs `--ssl-no-revoke`. All dep tarballs are mirrored in
   `D:\Wolftac\tools\zig-deps\`; seed a fresh cache with:

   ```powershell
   Get-ChildItem D:\Wolftac\tools\zig-deps -File | ForEach-Object { zig fetch $_.FullName }
   ```

   Notes:
   - `wuffs-…tar.gz` from deps.files.ghostty.org is hard-blocked by the
     middlebox; the equivalent content is
     `https://github.com/google/wuffs/archive/refs/tags/v0.4.0-alpha.9.tar.gz`
     (hash verified identical: `N-V-__8AAAzZywE3s51XfsLbP9eyEw57ae9swYB9aGB6fCMs`).
   - `libxml2-2.11.5.tar.gz` fails `zig fetch` (symlinks in tarball need
     Windows Developer Mode). It's a lazy dep of fontconfig (Linux-only path)
     and is **not needed** for the win32 build.

## Test harness

`test\win32\test_harness.ps1` (launch/sendkeys/screenshot/check/close).
When driving it from a non-foreground process, `SetForegroundWindow` is
blocked by focus-stealing protection — pulse the Alt key first
(`keybd_event(0x12, …)`) and verify `GetForegroundWindow()` matches before
sending keys.

## Remotes

- `origin` — https://github.com/WolftacDigital/Spectre (private)
- `insipid` — https://github.com/InsipidPoint/ghostty-windows (upstream fork)
- `ghostty` — https://github.com/ghostty-org/ghostty (true upstream)
