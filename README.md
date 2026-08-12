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
├─ 3 Steps ─────────── 6 automated · 3 hand-held, each previewable
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
| 3 | Quit World of Warcraft before copying | manual | Ticks itself off when no WoW process is running — WoW rewrites `WTF` on exit and would undo the copy |
| 4 | Copy your addons | auto | `Interface\AddOns` → PTR, optionally clearing PTR-only addons first |
| 5 | Carry over `Config.wtf` | auto | Merges live settings into the PTR's file, keeping PTR realm/account keys |
| 6 | Copy account-wide addon settings | auto | `WTF\Account\<ACCOUNT>\SavedVariables`, `bindings-cache.wtf`, macros, `config-cache.wtf` |
| 7 | Copy per-character settings | auto | Per character: `SavedVariables`, `AddOns.txt`, `layout-local.txt`, `config-cache.wtf`, keybinds, macros |
| 8 | Allow out-of-date addons | auto | Sets `checkAddonVersion "0"` so live-built addons load on a higher interface version |
| 9 | Launch the PTR and check the UI | manual | Closing check, with a pointer back to Restore if something looks wrong |

Those come straight from a written guide, transcribed in [`docs/GUIDE.md`](docs/GUIDE.md)
along with the four places this tool deliberately does something different (and why).

Every automated step is **previewable** — press *Preview changes* for the exact file
list with nothing written — and **individually tickable**, so you can copy addons
without touching settings, or the reverse.

The copying is plain PowerShell (`Copy-Item`) against your folders. No server, no
browser, no network access at any point.

## Safety

- Nothing is written until you press **Apply** and confirm. The confirmation says how
  many files will be removed, and warns if WoW is still running.
- Every run writes a backup to `_ptrsetup_backups\<timestamp>-<step>\` inside the PTR
  folder. **Restore is a real undo**: replaced and deleted files go back, *and* files
  the run added are removed, so the PTR client returns to exactly its prior state (an
  integration test asserts this hash-for-hash).
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
tools/New-MockWowFolder.ps1   builds a fake install to test against
tests/                        111 tests, no game install and no Pester required
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

## Trying it safely: the mock install

Before pointing it at your real game folder, build a fake one:

```powershell
.\tools\New-MockWowFolder.ps1 -Launch
```

That creates `PtrUiSetup-Mock\World of Warcraft` on your desktop with a live client
(5 addons, 3 characters, full settings) and a PTR client (launched once, one copied
character on "Classic PTR Realm 1", one stale PTR-only addon), then opens the window
pointed at it. Every file is stamped `LIVE` or `PTR`, so after applying you can open
anything on the PTR side and see whether it really came across.

Worth trying there: Preview (nothing should change), Apply (4 addons copied, the stale
one removed), check `WTF\Config.wtf` still says `logon-ptr`, Restore (everything goes
back), Apply again (every step reports "already up to date"). Delete the folder when
you are done — nothing else on your machine is touched.

## Development

```powershell
./tests/Invoke-Tests.ps1                       # all 111
./tests/Invoke-Tests.ps1 -Filter Steps.Tests   # one file
```

**Unit tests** (`Detect`, `ConfigWtf`, `FileOps`, `Steps`, `Ui`) cover one function at a
time against small fixtures. **Integration tests** (`Integration.Tests.ps1`) build the
real mock install from `tools/New-MockWowFolder.ps1` and walk the guide end to end,
asserting on what lands on disk — one test per instruction in the guide, plus undo,
idempotency, options, and awkward cases (PTR never launched, renamed account folder,
no character copied yet).

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

v0.3 — 111 passing tests, including an end-to-end pass over a realistic mock install.

The window itself **has not been opened on a real Windows machine**: WPF cannot run
where this was built. `tests/Ui.Tests.ps1` closes part of that gap without WPF (it
cross-checks every control the script uses against the XAML, and parses both files),
but rendering, layout and click behaviour need a human on Windows. Expect first-run
rough edges in the window; the file operations underneath are the well-tested part —
start with the mock install above.

See [`docs/GUIDE.md`](docs/GUIDE.md) for the source guide and the deliberate
deviations from it, [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for how it fits
together, and [`docs/PUBLISHING.md`](docs/PUBLISHING.md) for getting this onto GitHub.

MIT licensed.
