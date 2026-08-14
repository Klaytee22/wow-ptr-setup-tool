# WoW PTR UI Setup

Copy your live World of Warcraft UI — addons, addon profiles, keybinds, macros and
frame layout — onto the PTR client, without hand-copying folders and hoping you got
the right one.

Double-click, get a window. It walks the whole setup top to bottom: anything it can do
itself, it does; anything only you can do (installing the PTR client, running a
character copy) it explains, then watches your folders and ticks itself off once it can
see the step is done.

```
┌─ 1 Game folder ────── where WoW is, then live client  →  PTR client
├─ 2 Account & chars ── account folder pair + per-character mapping
├─ 3 Steps ─────────── 5 automated · 4 hand-held, each previewable
└─ 4 Options & safety ─ what to include, and a one-click undo of any step
```

## Running it

Download or clone the repo, then **double-click one of these**:

| Double-click | What happens |
|---|---|
| **`Try-It-Safely.cmd`** | Builds a fake game folder on your desktop and opens the window on it. **Start here** — it cannot touch your real install. |
| **`Start-PtrUiSetup.cmd`** | The window, against your actual game folder. |
| `Run-Tests.cmd` | Runs the test suite. |

Nothing to install. It runs on the Windows PowerShell that ships with Windows, and the
launchers pass `-ExecutionPolicy Bypass` for that one process, so no machine-wide
setting changes.

> **Windows will not run a `.ps1` by double-clicking it** — Explorer opens it in
> Notepad, and so does Command Prompt. That is what the `.cmd` files are for. If you
> would rather use a terminal, it has to be **PowerShell**, not Command Prompt:
>
> ```powershell
> .\PtrUiSetup.ps1                                  # the window
> .\PtrUiSetup.ps1 -Path 'D:\Games\World of Warcraft'  # skip straight to a folder
> .\PtrUiSetup.ps1 -ListSteps                       # print the steps, no window
> ```

[`docs/FIRST-RUN.md`](docs/FIRST-RUN.md) walks the fake install through end to end,
with the exact numbers you should see at each stage.

You should not need a command line at all. The window has a folder box with **Browse**
and **Detect** next to it, and remembers the folder you settle on, so the second launch
opens on it.

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
| 6 | Copy account-wide addon settings | auto | `WTF\Account\<ACCOUNT>\SavedVariables`, `bindings-cache.wtf`, macros, `config-cache.wtf`, and each addon's profile pointed at the PTR character |
| 7 | Copy per-character settings | auto | Per character: `SavedVariables`, `AddOns.txt`, `layout-local.txt`, `config-cache.wtf`, keybinds, macros |
| 8 | Allow out-of-date addons | auto | Sets `checkAddonVersion "0"` so live-built addons load on a higher interface version |
| 9 | Launch the PTR and check the UI | manual | Closing check, with a pointer back to Restore if something looks wrong |

Those come straight from a written guide, transcribed in [`docs/GUIDE.md`](docs/GUIDE.md)
along with the six places this tool deliberately does something different (and why).

Every automated step is **previewable** — press *Preview changes* for the exact file
list with nothing written — and **individually tickable**, so you can copy addons
without touching settings, or the reverse.

The copying is plain PowerShell (`Copy-Item`) against your folders. No server, no
browser, no network access at any point.

## Will my action bars look the same?

Three separate things, from three different places.

**The abilities sitting in each bar slot are server-side.** WoW keeps them on the
character, not in any file on your disk, so they came across with Blizzard's character
copy before this tool ran. Nothing here touches them.

**Where the bars are — Bartender, ElvUI, Dominos** — is a profile in
`WTF\Account\<ACCOUNT>\SavedVariables\<Addon>.lua`, which step 6 copies.

**Which profile loads** is the part that used to need doing by hand. Those addons pick
one out of a table keyed by `"Character - Realm"`, and the PTR realm has a different
name, so the copied file has your profile in it but no key that matches — the addon
falls back to its default and the bars come up bare. The **Point addon profiles at
your PTR character** option (on by default) adds that one key, so the profile its live
counterpart used is the one that loads. This is what the source guide means by *"Log
in and go to each addon and copy the profile from your Live Character's profile"*;
[`docs/GUIDE.md`](docs/GUIDE.md) has the detail.

If an addon still comes up on defaults, it keeps its settings under a scheme this
cannot read. Pick the profile once in its options and it sticks.

**Want a safety net for the bar slots themselves?** Nothing outside the game can read
or write them, so an external tool cannot snapshot them and screenshots are the manual
option. The better one is an in-game addon — [ActionBarSaver] is the long-standing
choice: `/abs save live` on your live character before you copy, and after this tool
has run, `/abs restore live` on the PTR. Its saved data is account-wide
SavedVariables, so step 6 carries it across for you. On retail, save and restore on the
same specialisation — action bars are per-spec there.

[ActionBarSaver]: https://www.curseforge.com/wow/addons/action-bar-saver

## Finding your install

The window opens with a folder box, so there is nothing to configure and no flag to
pass:

- **It watches.** Launching the PTR, copying a character, installing an addon or
  quitting the game are all noticed within a few seconds — *Rescan now* is there for
  when you want everything re-read from scratch, not for ordinary use. The check is
  about twenty directory timestamps and one process lookup, a few times a minute.
- **It remembers.** The folder you settle on is saved to
  `%LOCALAPPDATA%\PtrUiSetup\settings.json`, so the next launch opens on it.
- **Otherwise it detects.** Blizzard records the install path in the registry, which is
  one read and exact. Failing that it checks the handful of folders Battle.net installs
  to, on local fixed disks only — a disconnected network drive would otherwise stall
  the check for seconds at a time. Nothing searches your filesystem; that costs minutes
  to find a folder you already know.
- **Otherwise it shows the usual location** — `C:\Program Files (x86)\World of Warcraft`
  — for you to correct.

**Browse** picks a folder, **Detect** re-runs the search, and typing a path and pressing
Enter works too. Either the folder your install is in or a client folder inside it is
fine, since people paste whichever one Explorer happens to be showing.

Every client folder in there is offered: `_retail_`, `_classic_`, `_classic_era_`,
`_anniversary_`, `_ptr_`, `_ptr2_`, the betas, and any Blizzard adds later. A folder the
tool has never heard of is still recognised by the `.flavor.info` file every client
carries, so a version shipped after this was written turns up in the dropdowns on its
own, without waiting on an update here.

## Safety

- Nothing is written until you press **Apply** and confirm. The confirmation says how
  many files will be removed, and warns if WoW is still running.
- Every step that writes anything backs it up first, to
  `_ptrsetup_backups\<timestamp>-<step>\` inside the PTR folder. **Restore is a real
  undo**: replaced and deleted files go back, *and* files the step added are removed,
  so the PTR client returns to exactly its prior state (an integration test asserts
  this hash-for-hash). One entry per step, so undoing a whole Apply means restoring
  each of its entries.
- Running it twice is a no-op. A file already on the PTR and identical to the live one
  is left alone, so a second Apply reports every step finished rather than re-copying
  and re-backing-up the lot.
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
Try-It-Safely.cmd             double-click: fake install, then the window
Start-PtrUiSetup.cmd          double-click: the window, on your real folder
Run-Tests.cmd                 double-click: the test suite
PtrUiSetup.ps1                the window: renders state, calls the module
ui/MainWindow.xaml            the window's layout
Modules/PtrUiSetup/
  Detect.ps1                  find installs, accounts, realms, characters
  FileOps.ps1                 plan → preview → apply, with backup and restore
  ConfigWtf.ps1               parse/merge/render Config.wtf
  Steps.ps1                   the guide, expressed as data
  Session.ps1                 first-guess selection and keeping it consistent
  Settings.ps1                remembers the folder you picked
tools/New-MockWowFolder.ps1   builds a fake install to test against
tests/                        201 tests, no game install and no Pester required
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

Before pointing it at your real game folder, build a fake one — **double-click
`Try-It-Safely.cmd`**, or from a PowerShell prompt:

```powershell
.\tools\New-MockWowFolder.ps1 -Launch
```

That creates `PtrUiSetup-Mock\World of Warcraft` on your desktop with a live client
(5 addons, 3 characters, full settings) and a PTR client (launched once, one copied
character on "Classic PTR Realm 1", one stale PTR-only addon), then opens the window
pointed at it. Every file is stamped `LIVE` or `PTR`, so after applying you can open
anything on the PTR side and see whether it really came across.

Worth trying there: Preview (nothing should change), Apply (5 addons copied, the stale
one removed), check `WTF\Config.wtf` still says `logon-ptr`, Restore, Apply again (every
step reports "already up to date"). Delete the folder when you are done — nothing else
on your machine is touched.

[`docs/FIRST-RUN.md`](docs/FIRST-RUN.md) is the same walkthrough in full, with the exact
file counts and byte totals the window should be showing at each stage, so anything
different is a finding rather than a guess.

A backup is per step, not per Apply: an Apply that ran four steps leaves four backup
entries, and Restore undoes the one you pick. Rolling a whole run back means restoring
each of its entries.

## Development

```powershell
./tools/Invoke-Gate.ps1                        # everything that has to pass
./tests/Invoke-Tests.ps1                       # all 201
./tests/Invoke-Tests.ps1 -Filter Steps.Tests   # one file
```

`Invoke-Gate.ps1` is the one to run before pushing: it parses every file, checks the
encoding, runs the suite, and runs PSScriptAnalyzer if it is installed. CI runs the same
script on PowerShell 7 and on Windows PowerShell 5.1.

**Unit tests** (`Detect`, `ConfigWtf`, `Encoding`, `FileOps`, `Settings`, `Steps`, `Syntax`,
`Ui`) cover one function at a time against small fixtures. **Integration tests** (`Integration.Tests.ps1`) build the
real mock install from `tools/New-MockWowFolder.ps1` and walk the guide end to end,
asserting on what lands on disk — one test per instruction in the guide, plus undo,
idempotency, options, and awkward cases (PTR never launched, renamed account folder,
no character copied yet). **Coverage tests** (`Coverage.Tests.ps1`) check this tool
against [WoW-PTR-Config-Copier](https://github.com/Azevedoc/WoW-PTR-Config-Copier),
which automates the same guide: every file its script copies has to be a file some step
here plans to write.

Tests build fake `World of Warcraft` trees in temp folders, so the suite runs on
machines that have never seen the game — including CI, which runs it on PowerShell 7
(Windows + Linux) and on Windows PowerShell 5.1, since the launcher uses 5.1.

There is no Pester dependency: `tests/TestRunner.ps1` is a ~100-line `Describe`/`It`
harness, so the suite runs anywhere PowerShell does with nothing to install.

`PTRSETUP_EXTRA_ROOTS` adds folders to detection and `PTRSETUP_SETTINGS` moves the
settings file, both of which the tests use to stay off the real machine:

```powershell
$env:PTRSETUP_EXTRA_ROOTS = 'C:\temp\fake\World of Warcraft'
.\PtrUiSetup.ps1
```

## Status

v0.3 — 201 passing tests, including an end-to-end pass over a realistic mock install.

The window itself **has still not been opened on a real Windows machine**: WPF cannot run
where this was built. `tests/Ui.Tests.ps1` closes part of that gap without WPF — it
parses both files, cross-checks every control the script uses against the XAML, and
asserts the properties whose absence only shows up on screen (multi-line text boxes,
no bare strings in a list that displays a property, every click handler wrapped so a
failure cannot close the window). It also lifts the folder-box functions out of the
script by AST and runs them against a stub, so what the status line says and which
folders get remembered are covered without WPF. Rendering, layout and click behaviour
still need a human on Windows. Expect first-run rough edges in the window; the file operations
underneath are the well-tested part — start with the mock install above.

Known and unverified on Windows: the dark theme leaves the ComboBox dropdown popups on
the system's light background, which is why their items are explicitly dark rather than
inheriting the window's light text. Worth a look on a real screen —
[`docs/FIRST-RUN.md`](docs/FIRST-RUN.md) ends with the short list of things only a human
at a screen can settle.

## Docs

- [`docs/FIRST-RUN.md`](docs/FIRST-RUN.md) — try it against a fake install, step by
  step, with the numbers to expect
- [`docs/GUIDE.md`](docs/GUIDE.md) — the source guide, the instruction-to-step table,
  the five deliberate deviations, and a coverage comparison against the other tool that
  automates the same guide
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how it fits together and why
- [`docs/PUBLISHING.md`](docs/PUBLISHING.md) — getting this onto GitHub

MIT licensed.
