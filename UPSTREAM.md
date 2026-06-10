# Upstream sync playbook

Spectre sits at the bottom of a three-repo chain:

```
ghostty-org/ghostty  (true upstream: terminal core, themes, config)
        |  merged periodically by
InsipidPoint/ghostty-windows  (win32 apprt; remote: insipid)
        |  merged periodically by
WolftacDigital/Spectre  (this repo; remote: origin)
```

## The one rule

**Track `insipid/main`, not `ghostty/main`.** InsipidPoint absorbs the
ghostty merge pain (their fork exists to do exactly that). We merge
their result. Merging `ghostty/main` directly inflates our diff against
insipid and makes every future sync worse — only consider it under the
staleness escape hatch below.

## Cadence

Run `scripts\sync-upstream.ps1` (report-only by default) **monthly**, or
sooner when insipid ships a release we want. The script reports what's
new on both remotes and how stale insipid is relative to ghostty.

## Sync procedure

1. `powershell -ExecutionPolicy Bypass -File scripts\sync-upstream.ps1`
   — review the report.
2. If insipid has new commits: rerun with `-Merge`. The script merges
   `insipid/main` into `main` (merge commit, no rebase — our history
   stays linear-per-branch and pushed commits are never rewritten).
3. Resolve conflicts per the **conflict policy** below.
4. Rerun with `-Build` (or let `-Merge` chain into it) to rebuild and
   smoke-test.
5. Re-run the shell matrix if anything under `src/termio`, `src/pty*`,
   or `src/apprt/win32` changed: pwsh, cmd, Git Bash (quoted
   `C:\Program Files` path!), WSL2.
6. Push, then cut a release if user-visible behavior changed
   (`dist\windows\package.ps1`, bump version in `dist\windows\spectre.rc`).

## Conflict policy

- Outside `src/apprt/win32/`, `dist/windows/`, `test/win32/`: **keep
  upstream** (same rule insipid documents in their README), then
  re-apply our deliberate diffs if touched (inventory below).
- Inside `src/apprt/win32/`: keep upstream logic, re-apply Spectre
  identity strings ("Spectre" titles/captions/tips, WolftacDigital
  update URLs). The win32 `.win32` switch arms in core files must be
  preserved.
- `dist/windows/`: ours is authoritative (spectre.rc/ico/manifest +
  packaging scripts). Upstream changes to ghostty.rc should be
  mirrored into spectre.rc by hand.

## Deliberate divergence inventory

Keep this list current — it is the checklist for re-applying our diff
after a messy merge:

| Area | What | Where |
|---|---|---|
| Command quoting | `ArgIteratorGeneral` split + test (upstream PR #8; drop ours when merged) | `src/termio/Exec.zig` |
| Exe name | `spectre` on Windows | `src/build/GhosttyExe.zig` |
| Resources | spectre.rc/ico/manifest, `VS_VERSION_INFO` define (upstream PR #9) | `dist/windows/` |
| Identity strings | Spectre titles/captions/tips, update URLs → WolftacDigital/Spectre | `src/apprt/win32/{App,Window,Surface}.zig` |
| Config paths | `%LOCALAPPDATA%\spectre\config` first, ghostty fallback, template to spectre dir | `src/config/file_load.zig`, `src/config/Config.zig` |
| Packaging | package/install scripts, scoop/winget drafts | `dist/windows/` |
| Docs | BUILD-NOTES-SPECTRE.md, UPSTREAM.md | repo root |

NOT diverged on purpose: internal window class names (`GhosttyWindow`
etc.), `share/ghostty` resources dir name, `TERM_PROGRAM=ghostty`,
user themes dir (`ghostty/themes`) — all kept for compatibility and
merge cheapness. Do not "fix" these.

## Upstreaming discipline

Any fix that isn't Spectre-identity-specific goes to insipid as a PR
from the public fork `WolftacDigital/ghostty-windows` (branch per fix,
strip private issue references). Precedents: PR #8 (command quoting),
PR #9 (version resource ID). When an upstreamed fix lands in insipid,
the next merge dedupes it automatically (identical content merges
clean); if it conflicts trivially, take upstream's copy.

## Staleness escape hatch

The script warns when insipid's last ghostty merge is >60 days old.
If insipid looks abandoned AND we need something from ghostty/main:
first open an issue asking insipid about sync plans; only then
consider merging `ghostty/main` directly, knowing the win32 apprt
conflicts become ours forever after. As of 2026-06-09 insipid last
merged ghostty on 2026-05-16 (211 commits behind) — healthy.
