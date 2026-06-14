# Spectre daily-driver checklist

You're on **v0.2.0**, installed at `%LOCALAPPDATA%\Spectre` (Start Menu +
PATH). This is the guide for living with it for a week and knowing what to
report back.

## Turn on the new stuff

Edit `%LOCALAPPDATA%\spectre\config`:

```ini
command = pwsh
theme = Catppuccin Mocha
# Session restore: bring back your windows/tabs (+ each tab's directory)
window-save-state = always
```

Restart Spectre. From now on, when you quit and relaunch, your tabs come
back where you left them — each in the directory it was in.

## Daily exercise — use it for real

Use Spectre as your primary terminal. Specifically lean on:

- [ ] **PowerShell 7** for everyday work (your main shell)
- [ ] **Git Bash** — `command = C:\PROGRA~1\Git\bin\bash.exe -i -l` (or run
      `bash` from pwsh). Watch cursor/resize behavior.
- [ ] **WSL2** — `wsl` from a tab; check clipboard, resize, cwd
- [ ] **Claude Code** and **Hermes gateway logs** — long-running, lots of
      output and color
- [ ] **Tabs + splits** — `Ctrl+Shift+T` new tab, `Ctrl+Shift+|`/`-` splits,
      drag to reorder, resize the window with splits open
- [ ] **Quick terminal** — the global-hotkey dropdown
- [ ] **Session restore** — set up a few tabs in different project dirs,
      quit, relaunch, confirm they return correctly

## Known v0.2.0 limitations (don't report these — already tracked)

- Session restore rebuilds **tabs**, but a tab that had **split panes**
  comes back as a single pane (splits are saved; full restore is issue #7
  v2).
- Closing **multiple windows one-by-one** (vs. one Quit) restores only the
  last-closed window.
- The **inspector** debug overlay is unimplemented (issue #4).
- Binaries are **unsigned** — SmartScreen warns on a *downloaded* copy
  (your local install is fine).

## What's worth reporting

Anything that breaks your flow:
- Rendering glitches, wrong colors, cursor artifacts, flicker on resize
- Input latency or dropped keystrokes
- A shell that misbehaves (especially MSYS/Git Bash quirks)
- Crashes — grab the window and, if reproducible, note the steps
- cwd not tracked after `cd` in some shell (only pwsh integration is
  verified; bash/zsh/fish use OSC 7 too but I haven't exercised every one)
- Anything you reach for that isn't there

File these as issues on `WolftacDigital/Spectre` (or just tell the agent and
it'll file them). Each becomes the next work item — the roadmap should be
driven by what actually annoys you in real use, not speculation.

## Updating

When a new version ships: `scoop update spectre` (once the manifest bucket
is wired) or re-run `install.ps1` from the new release zip. The in-app
update check points at the GitHub releases and will toast when a newer tag
is published.

## Rolling back

The previous release zips are on GitHub Releases; extract and run
`install.ps1` from the version you want. Your config and session files in
`%LOCALAPPDATA%\spectre\` are untouched by reinstalls.
