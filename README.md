# WoW PTR UI Setup

Copy your live World of Warcraft UI — addons, addon profiles, keybinds, macros and
frame layout — onto the PTR client, without hand-copying folders and hoping you got
the right one.

Double-click, get a window. It walks the whole setup top to bottom: anything it can do
itself, it does; anything only you can do (installing the PTR client, running a
character copy) it explains, then watches your folders and ticks itself off once it can
see the step is done.

```
┌─ 1 Clients ────────── live client  →  PTR client
├─ 2 Account & chars ── account folder pair + per-character mapping
├─ 3 Steps ─────────── 6 automated · 2 hand-held, each previewable
└─ 4 Options & safety ─ what to include, and one-click restore of any run
```

## Running it

Download or clone the repo, then **double-click `Start-PtrUiSetup.cmd`**.

Nothing to install. It runs on the Windows PowerShell that ships with Windows, and the
launcher passes `-ExecutionPolicy Bypass` for that one process, so no machine-wide
setting changes.

From a prompt, if you prefer:

```powershell
.\PtrUiSetup.ps1                                  # the window
.\PtrUiSetup.ps1 -Path 'D:\Games\World of Warcraft'  # extra folder to scan
.\PtrUiSetup.ps1 -ListSteps                       # print the steps, no window
```

**Windows only** — WPF is. The module underneath is cross-platform and works from a
console on macOS or Linux (see *Scripting it* below).

## What it does

| # | Step | Mode | What happens |
|---|------|------|--------------|
| 1 | Install and launch the PTR client once | manual | Waits until the PTR folder has a `WTF` tree — nothing can be copied before that |
| 2 | Copy your character to the PTR | manual | Blizzard's character copy; the tool detects the result |
| 3 | Copy your addons | auto | `Interface\AddOns` → PTR |
| 4 | Carry over `Config.wtf` | auto | Merges live settings into the PTR's file, keeping PTR realm/account keys |
| 5 | Copy account-wide addon settings | auto | `WTF\Account\<ACCOUNT>\SavedVariables` (+ macros, keybinds) |
| 6 | Copy per-character settings | auto | Per character: `SavedVariables`, `AddOns.txt`, `layout-local.txt`, macros, keybinds |
| 7 | Allow out-of-date addons | auto | Sets `checkAddonVersion "0"` so live-built addons load on a higher interface version |
| 8 | Launch the PTR and check the UI | manual | Closing check, with a pointer back to Restore if something looks wrong |

Every automated step is **previewable** — press *Preview changes* for the exact file
list with nothing written — and **individually tickable**, so you can copy addons
without touching settings, or the reverse.

The copying is plain PowerShell (`Copy-Item`) against your folders. No server, no
browser, no network access at any point.

## Safety

- Nothing is written until you press **Apply** and confirm.
- Every file that gets overwritten is copied into `_ptrsetup_backups\<timestamp>-<step>\`
  inside the PTR folder first, with a manifest. **Restore** puts a whole run back.
- Writes are constrained to the selected PTR folder — a planned write landing anywhere
  else aborts the run instead of touching it.
- The tool never writes to your live client. It only reads from it (there is a test
  that asserts exactly this).
- `Config.wtf` is merged, not copied: `realmList`, `portal`, `accountName` and friends
  keep the PTR's own values, so the PTR client keeps pointing at PTR realms.

Quit WoW before applying — it rewrites `WTF` when it exits and will happily undo the
copy.

## Layout

```
Start-PtrUiSetup.cmd          double-click launcher
PtrUiSetup.ps1                the window: renders state, calls the module
ui/MainWindow.xaml            the window's layout
Modules/PtrUiSetup/
  Detect.ps1                  find installs, accounts, realms, characters
  FileOps.ps1                 plan → preview → apply, with backup and restore
  ConfigWtf.ps1               parse/merge/render Config.wtf
  Steps.ps1                   the guide, expressed as data
  Session.ps1                 first-guess selection and keeping it consistent
tests/                        78 tests, no game install and no Pester required
```

Adding a step means adding one `New-PtrSetupStep` entry in `Steps.ps1`. The window, the
preview, the backups and the summary pick it up with no other changes.

## Scripting it

The module has no dependency on the window:

```powershell
Import-Module ./Modules/PtrUiSetup
$context = Initialize-PtrSetupContext
Invoke-PtrSetup -Context $context -StepId copy_addons, copy_config_wtf -PreviewOnly
Invoke-PtrSetup -Context $context -StepId copy_addons
Get-PtrSetupBackup -InstallPath $context.Target.Path
```

## Development

```powershell
./tests/Invoke-Tests.ps1                 # all 78
./tests/Invoke-Tests.ps1 -Filter Steps.Tests
```

Tests build fake `World of Warcraft` trees in temp folders, so the suite runs on
machines that have never seen the game — including CI, which runs it on PowerShell 7
(Windows + Linux) and on Windows PowerShell 5.1, since the launcher uses 5.1.

There is no Pester dependency: `tests/TestRunner.ps1` is a ~100-line `Describe`/`It`
harness, so the suite runs anywhere PowerShell does with nothing to install.

To drive the window against a fake install instead of your real one:

```powershell
$env:PTRSETUP_EXTRA_ROOTS = 'C:\temp\fake\World of Warcraft'
.\PtrUiSetup.ps1
```

## Status

v0.2 — the module is covered by 78 passing tests. The window itself has been checked
for parse and name correctness by the suite (`tests/Ui.Tests.ps1` cross-checks every
control against the XAML) but **has not yet been opened on a real Windows machine**,
and nothing has been run against a real PTR install. Expect first-run rough edges in
the window; the file operations underneath are the well-tested part.

See [`docs/GUIDE.md`](docs/GUIDE.md) for where each step came from and what is still
open.

MIT licensed.
