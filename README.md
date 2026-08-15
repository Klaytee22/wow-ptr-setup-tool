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
├─ 3 Steps ─────────── 6 automated · 5 hand-held, each previewable
└─ 4 Options & safety ─ four switches, and a one-click undo of any step
```

## Running it

**Download:** [the latest release](https://github.com/Klaytee22/wow-ptr-setup-tool/releases/latest)
→ *Source code (zip)*. Or the green **Code** button → *Download ZIP*.

> **Right-click the downloaded `.zip` → Properties → tick *Unblock* → OK, and only then
> extract it.** Windows marks everything that comes off the internet, and an extracted
> `.cmd` carrying that mark gets a *"Windows protected your PC"* box instead of running.
> Unblocking the zip first clears it for every file inside; doing it afterwards means
> doing it file by file. If you have already extracted and hit the box, *More info →
> Run anyway* works too.

Extract it somewhere ordinary — Documents or Desktop, not inside the zip preview and
not in `Program Files`. Then **double-click one of these**:

| Double-click | What happens |
|---|---|
| **`Start-PtrUiSetup.cmd`** | The window. This is the one you want. |
| `Run-Tests.cmd` | Runs the test suite — needs no game folder, and answers "is it me or the tool?" |

Nothing to install. It runs on the Windows PowerShell that ships with Windows, and the
launchers pass `-ExecutionPolicy Bypass` for that one process, so no machine-wide
setting changes. Keep the folder as it comes — `Start-PtrUiSetup.cmd` looks for
`PtrUiSetup.ps1`, `ui\` and `Modules\` next to itself.

> **Windows will not run a `.ps1` by double-clicking it** — Explorer opens it in
> Notepad, and so does Command Prompt. That is what the `.cmd` files are for. If you
> would rather use a terminal, it has to be **PowerShell**, not Command Prompt:
>
> ```powershell
> .\PtrUiSetup.ps1                                  # the window
> .\PtrUiSetup.ps1 -Path 'D:\Games\World of Warcraft'  # skip straight to a folder
> .\PtrUiSetup.ps1 -ListSteps                       # print the steps, no window
> ```

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
| 4 | Break ties between macros on your LIVE client | auto, **opt-in** | The only step that writes outside the PTR folder. Never ticked for you. Tells you how many macro names collide, and gives the duplicates an invisible suffix so an action bar saver can tell them apart |
| 5 | Save your action bars on the live client | manual | Install an action bar saver and `/abs save`, before anything is copied — the bars are server-side and this is the only way to carry them |
| 6 | Copy your addons | auto | `Interface\AddOns` → PTR, optionally clearing PTR-only addons first, patching a stale Ace3 on the way |
| 7 | Carry over `Config.wtf` | auto | Merges live settings into the PTR's file, keeping PTR realm/account keys |
| 8 | Copy account-wide addon settings | auto | `WTF\Account\<ACCOUNT>\SavedVariables`, `bindings-cache.wtf`, macros, `config-cache.wtf`, and each addon's profile pointed at the PTR character |
| 9 | Copy per-character settings | auto | Per character: `SavedVariables`, `AddOns.txt`, `layout-local.txt`, `config-cache.wtf`, keybinds, macros |
| 10 | Allow out-of-date addons | auto | Sets `checkAddonVersion "0"` so live-built addons load on a higher interface version |
| 11 | Launch the PTR and check the UI | manual | Closing check — enable anything unticked, `/abs restore`, and a pointer back to Restore if something looks wrong |

Those come straight from a written guide, transcribed in [`docs/GUIDE.md`](docs/GUIDE.md)
along with the eight places this tool deliberately does something different (and why).

Every automated step is **individually tickable**, so you can copy addons without
touching settings, or the reverse — and every one of them shows the exact files it would
write before you press anything. Open the *Show the N file(s)* list on a card and that is
the plan, file by file.

The copying is plain PowerShell (`Copy-Item`) against your folders. No server, no
browser, no network access at any point.

## Will my action bars look the same?

Three separate things, from three different places.

**The abilities sitting in each bar slot are server-side.** WoW keeps them on the
character, not in any file on your disk — which is why an addon has to read them
through the game API to back them up at all. So this tool cannot move them, cannot
break them, and does not try.

**Blizzard's character copy does not appear to bring them either.** On the run this was
tested against — an Anniversary live client onto its PTR — everything else arrived and
the bars came up empty. Treat that as one observation rather than a rule, but plan for
it: the recipe below is quick and costs nothing if the bars turn out fine.

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

If an addon still comes up on defaults, pick the profile once in its own options — in
Bartender that is **Profiles → Copy From → your live character** — and it sticks. That
means the profile came across and only the selection missed, which is worth reporting:
it is a bug in this tool, not something you should have to do.

### Getting the bar slots across anyway

Nothing outside the game can read or write those slots, so this has to be done by an
in-game addon, and the addon's own saved data is then just another file this tool
copies — both account-level and character-level `SavedVariables` are covered, so
whichever scope the addon uses comes across.

**Take a build that matches your client**, which the addon installers get right on their
own. The one that goes wrong is picking an abandoned addon: the long-recommended
[Action Bar Saver] was last updated in 2010 and does not load on a modern client at all,
so its `/abs` command does not exist and it looks as though nothing was installed. Two
that are maintained:

- [ActionBarSaver: Reloaded] — a rewrite of the original. It files sets by **class**,
  not by character, so the copied character having a different name or realm makes no
  difference to it: land the file on the PTR and `/abs list` shows your sets. Its own
  data is account-level, so the addon settings step carries it.
- [TBCA Action Bars Saver] — ten bars, and it copes with spells that are missing on the
  destination.

The order that works, without copying your character again:

1. **On live:** install it, log in on the character whose bars you want, and save a
   profile with whatever command the addon uses.
2. **Log out.** WoW writes `SavedVariables` on exit, so the file does not exist until
   you do. Skipping this is the most common way to get an empty result.
3. **Run this tool** — the addon and its saved data go over with everything else.
4. **On the PTR:** log in and restore the profile.

Do step 1 *before* the copy next time and the bars are right on the first login.

**If the addon's command does nothing on the PTR** — as though it were never installed —
then it did not load, which is a different problem from the profile being missing. Check
in this order:

1. **Did you install it on live after the last time you ran this tool?** Step 4 copies
   the addon folder as it stood when it ran. Install something on live afterwards and it
   is simply not on the PTR yet. Re-run the tool; the window notices the live `AddOns`
   folder changing on its own, so the addon step will already be offering to copy again.
   This is far and away the most common cause.

   While you are at it: **log into the live client once after installing an addon,
   before running this tool.** `AddOns.txt` is a snapshot of which addons were ticked
   the last time that character logged in, and step 7 copies it. Take the snapshot
   before the addon existed and the copied character has no entry for it.
2. **Is the folder there?** Look for `Interface\AddOns\<Addon>\` inside the PTR client
   folder. Nothing there means point 1.
3. **Is it ticked?** At character select, open **AddOns**. A copied addon that is listed
   but unticked just needs enabling.
4. **Does the build match the client?** An addon built for retail will not load on an
   Anniversary client however out-of-date loading is set.
5. **Is out-of-date loading on?** Confirm `SET checkAddonVersion "0"` is in the PTR's
   `WTF\Config.wtf` — step 8 sets it, and without it everything built for live reads as
   out of date.

### Two macros with the same name

Anything that identifies a macro by name needs those names to be distinct.
ActionBarSaver says so outright, and a restore otherwise fails with a page of *unable to
restore item to slot*.

The usual way to end up there is not a bug: Classic prints a macro's name on its action
button, so wanting clean bars leads to naming every macro the same single space. Thirty
macros called `" "` is thirty conflicts. But two both called `weps` break it just as
thoroughly, and that is the actual problem — duplication, not blankness.

There is an option, **Break ties between macros that share a name**, which fixes the
PTR's copy on the way over. The first macro of each duplicated name keeps it; the rest
get a suffix built from spaces and no-break spaces, so `weps` still reads as `weps` on
the bar while being unique to anything looking it up. A macro whose name is already its
own is never touched.

**On its own that is not enough for an action bar saver**, and it is worth being clear
why. The addon records, for each slot, the name of the macro in it — and it does that
*on your live client*, where the names still collide. A profile saved from thirty
identically-named macros is already ambiguous; making the PTR's names unique afterwards
cannot recover which slot wanted which macro.

So the names have to be fixed on the **live** client, before the profile is saved.

There is a step for it in the window — **Break ties between macros on your LIVE client**.
It is the only thing in the whole tool that writes outside the PTR folder, so it behaves
differently from everything else:

- **It is never ticked for you.** Every other automated step is on by default; this one
  you have to choose.
- The Apply confirmation names it and names the folder it will write to.
- It is previewable like anything else.
- It touches nothing but `macros-cache.txt`, and within that nothing but the names.
- It is the one step that does **not** leave a backup. It writes once and then reports
  itself done, so a backup would be a folder created inside your real game install and
  never used again. That does mean no undo from the window: if you want one,
  `tools\Rename-DuplicateMacros.ps1` does the same job and keeps the original beside the
  file as `macros-cache.txt.before-rename`.

**The order matters:**

1. Quit WoW — it rewrites `macros-cache.txt` on exit and would undo this.
2. Tick that step, Apply.
3. Log in on live and save your action bar profile. *Now*, not before — a profile saved
   earlier was written from the old names.
4. Run the rest of the tool, then restore the profile on the PTR.

There is the same thing as a script, if you would rather do it outside the window:

```powershell
.\tools\Rename-DuplicateMacros.ps1 -Path 'C:\...\WTF\Account\<ACCOUNT>\macros-cache.txt'
```

It reports what it would do and writes nothing until you add `-Apply`, keeping the
original as `macros-cache.txt.before-rename`. Do the character-level file too, with
`-Scope Character`.

### An addon that loads on live and errors on the PTR

If the error names `Libs/AceDB-3.0/AceDB-3.0.lua` and says **"attempt to concatenate
local 'regionKey' (a nil value)"**, that is a stale copy of the Ace3 libraries, not
anything this tool did. AceDB builds its scope keys from a five-entry region table:

```lua
local regionTable = { "US", "KR", "EU", "TW", "CN" }
local regionKey = regionTable[GetCurrentRegion()]
```

PTR realms report a region id that is not in it, so `regionKey` is `nil` and the next
line — a concatenation — throws. The addon's `OnInitialize` dies with it, so its slash
commands are never registered and it looks as though it is not installed at all.

It is worse than one addon. Ace3 libraries are shared through LibStub, and the
highest-versioned copy across *all* your addons is the one everything uses — so a single
addon carrying a stale AceDB breaks every Ace3 addon on the PTR at once, which can look
like copied settings having gone wrong. The traceback names which addon's copy is in
play.

**This tool fixes it for you**, and the option — *Fix the PTR copy of Ace3 so addons
using it can start* — is on by default. It gives the lookup a fallback:

```lua
local regionKey = regionTable[GetCurrentRegion()] or "US"
```

Three things bound what that does. It writes **only to the PTR**; your live client is
read and never touched, which is the invariant the whole tool rests on and which an
integration test asserts. It touches **only files named `AceDB-3.0.lua`**, and only that
one assignment — everything else in the file, down to the line endings, is byte for byte
the live copy. And a library that already has a fallback is left alone, so a current
Ace3 passes through untouched and a second Apply still reports itself done.

It is a workaround, not a fix. The real answer is updating the addon that carries the
stale copy, or dropping a current Ace3 `Libs\AceDB-3.0` into any one addon so it wins
the LibStub version race. Untick the option if you would rather do that yourself.

Errors from the addon while *saving* on live are a different matter and usually harmless:
macros are the part these addons handle least well, since a macro that does not exist on
the destination cannot be placed. Bars restore; a few macro slots may not.

On retail, save and restore on the same specialisation — action bars are per-spec there.
Screenshots remain the no-addon option, and are worth taking before a first attempt.

[Action Bar Saver]: https://www.curseforge.com/wow/addons/action-bar-saver
[ActionBarSaver: Reloaded]: https://www.curseforge.com/wow/addons/actionbarsaver-reloaded
[TBCA Action Bars Saver]: https://www.curseforge.com/wow/addons/tbca-action-bars-saver-copy-save-restore

## What about Blizzard's "Copy Account Data" button?

It does not overlap with this tool much, and if it fails for you it costs you very
little. Blizzard's servers cannot read your hard drive, so whatever that button moves
is server-side account data. Everything below lives in files on your PC and is out of
its reach entirely:

- the addon folders themselves, `Interface\AddOns`
- every addon's settings — Bartender, WeakAuras, Details, Plater and the rest, in
  `SavedVariables`
- which profile each character loads (see the section above)
- `AddOns.txt`, the enabled list, and `layout-local.txt`, the frame positions
- `Config.wtf` — resolution, graphics, weather, volume

The genuine overlap is **macros and keybinds**, which are plausibly server-side as
well. This tool copies them from files regardless — `bindings-cache.wtf` and
`macros-cache.txt` at both account and character level — so a button that does not
work changes nothing as long as *Include macros and keybinds* stays ticked. If the
button does work for you, untick it and let Blizzard do that half.

Either way the step cards settle it without writing anything: press the button, then open
the file list on *Copy account-wide addon settings*. Files that already match are marked
as such, so what is left is exactly what Blizzard did not bring across.

If keybinds arrive correctly and then revert after you log in and out, that is not this
tool — WoW rewrites `WTF` on exit, and a client with server-side settings sync enabled
can push its own copy down over the file. Look for a sync or cloud settings option in
the game's own settings, then re-run the step.

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
- **Delete all** next to Restore removes the backup folders once they have piled up —
  `_ptrsetup_backups` and nothing else. It does not touch a single file this tool copied,
  and it is not an undo: it throws away the copies kept *for* undoing, so anything you
  have not restored yet stays exactly as it is on the PTR.
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
Start-PtrUiSetup.cmd          double-click: the window
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

## Trying it against a fake install

If you would rather not point it at your real game folder first, build a fake one. From
a **PowerShell** prompt in the repo folder:

```powershell
.\tools\New-MockWowFolder.ps1 -Launch
```

That creates `PtrUiSetup-Mock\World of Warcraft` on your desktop with a live client
(5 addons, 3 characters, full settings) and a PTR client (launched once, one copied
character on "Classic PTR Realm 1", one stale PTR-only addon), then opens the window
pointed at it. Every file is stamped `LIVE` or `PTR`, so after applying you can open
anything on the PTR side and see whether it really came across.

Worth trying there: open a step's file list (nothing is written by looking), Apply
(5 addons copied, the stale one removed), check `WTF\Config.wtf` still says `logon-ptr`, Restore, Apply again (every
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

v1.1 — 318 passing tests, gated by `tools/Invoke-Gate.ps1`, which is also what CI runs.

**Verified on a real Windows install** (Anniversary live → its PTR): detection, the
client and account dropdowns, the step list, Apply, `Config.wtf` merged with the
PTR realm intact, Restore, and addons plus their settings arriving in a working state.

**Built but not yet confirmed in game.** These were written against a real file or a real
error message and are covered by tests, but nobody has watched the client accept them:

- the invisible macro-name suffixes surviving a logout — the client keeps the single
  space these macros already carry, which is what the scheme is built on, but the longer
  ones have not been round-tripped
- the profile key read out of the PTR's own file rather than guessed at
- the AceDB region fallback
- the crash log at `%TEMP%\ptrsetup-error.log`, and the launcher pausing on failure

Each is backed up before it writes and undoable from the Restore dropdown — bar the live
macro rename, which says so on its own card. Do one Apply, look at the result in game,
and come back if something is off.

**Only settleable by a human at a screen:** rendering, layout, contrast, and how any of
this behaves on an install much larger than the ones it has seen. Read the file list on a
step card before you Apply — it is the plan, exactly.

## Docs

- [`docs/FIRST-RUN.md`](docs/FIRST-RUN.md) — try it against a fake install, step by
  step, with the numbers to expect
- [`docs/GUIDE.md`](docs/GUIDE.md) — the source guide, the instruction-to-step table,
  the five deliberate deviations, and a coverage comparison against the other tool that
  automates the same guide
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how it fits together and why
- [`docs/PUBLISHING.md`](docs/PUBLISHING.md) — getting this onto GitHub

MIT licensed.
