# Default-terminal handoff (issue #6) — design & plan

Goal: let Spectre be the Windows "default terminal application", so console
programs launched outside any terminal (double-clicked `.bat`, `cmd` from
Run, a compiler spawning a child console, etc.) open inside Spectre instead
of conhost.

Status: **foundation in progress.** The COM contract, type definitions, and
class-factory scaffolding are being built and are verifiable by compilation
and in-process activation. **Becoming the system default terminal and the
live PTY hand-off are gated behind explicit user sign-off** — that path
rewrites a per-user registry setting that affects *every* console launch on
the machine, so it must not be enabled or tested casually.

## How Windows default-terminal handoff works

Windows 11 (and Win10 1903+ with the new console) supports delegating
console startup to a third-party "delegation terminal" via out-of-process
COM:

1. A program starts a console app. The OS console subsystem (`conhost`,
   the "inbox" host) is launched to bootstrap it.
2. conhost reads `HKCU\Console\%%Startup` for `DelegationConsole` and
   `DelegationTerminal` CLSIDs. If they point at a registered terminal,
   conhost spins up a headless ConPTY and hands the pipes to that terminal
   over COM instead of drawing the classic console window.
3. conhost `CoCreateInstance`s the `DelegationTerminal` CLSID and calls
   `ITerminalHandoff(2/3)::EstablishPtyHandoff`, passing the PTY pipe
   handles + the client process. The terminal builds a surface around those
   pipes — it does **not** spawn its own ConPTY for this surface.

The `DelegationConsole` CLSID points at a console handoff object
(`IConsoleHandoff`) used for the older attach path; Windows Terminal ships
both. For a first cut we target the terminal handoff (the modern path).

## The COM contract (from microsoft/terminal `ITerminalHandoff.idl`)

```c
typedef struct _TERMINAL_STARTUP_INFO {
    BSTR  pszTitle;
    BSTR  pszIconPath;
    LONG  iconIndex;
    DWORD dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
    DWORD dwFillAttribute, dwFlags;
    WORD  wShowWindow;
} TERMINAL_STARTUP_INFO;
```

| Interface | IID | EstablishPtyHandoff params |
|---|---|---|
| `ITerminalHandoff`  | `59D55CCE-FC8A-48B4-ACE8-0A9286C6557F` | `in, out, signal, ref, server, client` (all `[in]` handles) |
| `ITerminalHandoff2` | `AA6B364F-4A50-4176-9002-0AE755E7B5EF` | …above… `+ TERMINAL_STARTUP_INFO startupInfo` |
| `ITerminalHandoff3` | `6F23DA90-15C5-4203-9DB0-64E73F1B1B00` | `out HANDLE* in, out HANDLE* out, in signal, ref, server, client, const TERMINAL_STARTUP_INFO*` |

Handle roles: `in`/`out` are the PTY data pipes (terminal reads `out`,
writes `in`); `signal` is the ConPTY signal pipe (resize etc.); `ref` keeps
the pseudoconsole alive; `server` is the conhost process; `client` is the
actual console application process to watch for exit.

We target **ITerminalHandoff2** first (handles delivered to us, plus
startup info for title/size) — simplest correct modern interface. v3 (we
create the pipes) is a later refinement.

## Registry surface

Per-user (`HKCU`), all reversible:

- `HKCU\Software\Classes\CLSID\{SPECTRE-CLSID}\LocalServer32` → `"…\spectre.exe" --defterm-server`
- `HKCU\Software\Classes\AppID\{SPECTRE-CLSID}` (AppID for the LocalServer)
- `HKCU\Console\%%Startup`:
  - `DelegationConsole` = `{SPECTRE-CONSOLE-CLSID}` (or `{0…0}` = system default)
  - `DelegationTerminal` = `{SPECTRE-CLSID}`

Spectre uses its own freshly-generated CLSIDs (never Windows Terminal's).
Uninstall restores both `Delegation*` values to the all-zero GUID (the
"let Windows decide" sentinel).

## Implementation phases

- **P1 — COM types + scaffolding (this session, compile-verified):**
  `src/apprt/win32/defterm/com.zig` — GUIDs, `TERMINAL_STARTUP_INFO`,
  `IUnknown`/`IClassFactory`/`ITerminalHandoff2` vtable layouts, a class
  factory and a handoff object whose `EstablishPtyHandoff` currently just
  validates + logs. No registry writes, no auto-registration.
- **P2 — Out-of-proc server mode:** `spectre --defterm-server` runs the
  message loop with `CoRegisterClassObject` for our factory so conhost can
  activate us. In-process self-test: `CoCreateInstance` our CLSID and call
  `EstablishPtyHandoff` with dummy pipes; assert it's received. (Safe — no
  system default change.)
- **P3 — PTY-backed surface:** a surface that wraps externally-provided
  in/out/signal pipes instead of calling `CreatePseudoConsole`
  (`src/pty.zig` + `Surface.init` get an "attach" path). Watch `client`
  for exit.
- **P4 — Registration UX (gated):** `spectre +install-defterm` /
  `+uninstall-defterm` write/restore the registry keys. **Only run with
  explicit user confirmation**; document the one-command rollback.
- **P5 — Verify end-to-end (gated):** with user go-ahead, set Spectre as
  default, launch `cmd`/a `.bat`/`Run→cmd`, confirm it opens in Spectre,
  resize/exit work; then restore the default.

## Risks / guardrails

- **System-wide blast radius:** a broken handoff can make *every* console
  launch fail or hang. Mitigation: never auto-register; ship rollback;
  keep classic conhost reachable; test in a VM/secondary account first if
  possible.
- **Elevated apps don't hand off** to a non-elevated terminal (by design).
- **COM lifetime/threading:** EstablishPtyHandoff arrives on a COM thread;
  marshal the pipes to the app/UI thread before building the surface.
- **Upstreamability:** most of this (the PTY-attach surface path) is a
  general win32 capability and should be offered to InsipidPoint.
