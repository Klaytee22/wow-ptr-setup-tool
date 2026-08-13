# Architecture

## The shape of it

```
Start-PtrUiSetup.cmd      powershell.exe -STA -ExecutionPolicy Bypass
   │
PtrUiSetup.ps1            WPF window: renders state, handles clicks
   │  (+ ui/MainWindow.xaml for the layout)
   ▼
Modules/PtrUiSetup/
   Session.ps1            the user's selection, and the first guess at it
   Steps.ps1              the guide as data: id, mode, instructions, plan
   Detect.ps1             installs, accounts, realms, characters
   FileOps.ps1            plan → preview → apply, backup, restore
   ConfigWtf.ps1          parse / merge / render Config.wtf
```

Three rules keep it maintainable:

1. **The module knows nothing about the window.** Every function is callable from a
   console and tested that way. The GUI is one consumer, which is why the whole suite
   runs on Linux CI where WPF does not exist.
2. **Plan, then apply.** No step writes during planning. `New-PtrSetupStepPlan` returns
   `FileAction` objects; the same list is what the preview shows and what
   `Invoke-FileActionPlan` executes. A preview is not a different code path — it is the
   real one with `-PreviewOnly`.
3. **Status is derived, never stored.** `Get-PtrSetupStepStatus` re-reads the
   filesystem on every refresh, so the window cannot drift out of sync with what is
   actually on disk — including changes made outside the tool.

## Steps

A step is one item in the guide (see [`GUIDE.md`](GUIDE.md)), created by
`New-PtrSetupStep`. Both kinds implement one shape so the window renders them in a
single list:

- `Mode = 'auto'` — `Plan` returns file actions; `Invoke-PtrSetupStep` performs them.
- `Mode = 'manual'` — `Instructions` plus a `Status` scriptblock that watches the
  filesystem, so the step ticks itself off once the user has done it (or they tick it
  by hand).

`Prerequisite` separates *cannot run yet* from *already done*: without it, an empty
plan is ambiguous — it could mean "nothing to copy from" or "everything is copied".
Blocked steps say why; finished steps say so.

To add a step: add a `New-PtrSetupStep` entry to `$script:PtrSetupSteps`. Nothing else
changes. Keep filesystem-layout knowledge in `Detect.ps1`; a step decides *which*
folders matter, not how to find them.

## FileAction

```powershell
New-FileAction -Kind create|overwrite|skip|delete -Source <path> -Destination <path> `
               -Size <bytes> -Note <string> -Content <string>
```

Most actions copy `Source` to `Destination`. A step that generates a file instead (the
`Config.wtf` merge) leaves `Source` empty and sets `Content`, which the applier writes
verbatim. A `delete` has only a `Destination` — it comes from `New-TreeCopyPlan -Prune`,
which is how "delete any addons there, then paste yours" is expressed in file terms.
Everything else — preview rendering, byte totals, backup selection — treats them all
identically.

A `skip` is a file the plan considered and decided not to touch. There are two reasons
for one: the user turned overwriting off, or the file is already there and identical
(`Test-FileUnchanged`). The second is what makes the tool idempotent — without it a
second run re-copies every file, backs up every one of them, and no step can ever say it
is finished, because `Get-PtrSetupStepStatus` reads "done" as *nothing left that is not a
skip*. The window counts skips separately for the same reason: they belong in the file
list, not in "12 file(s) will change".

`Test-FileUnchanged` compares size and last-write time rather than hashing. `Copy-Item`
preserves the source timestamp tick for tick, so a file this tool copied compares equal
on the next run; hashing would be exact but the plan is rebuilt on every refresh of the
window, and a real `AddOns` folder runs to hundreds of megabytes. The comparison is exact
rather than tolerant: a tolerance wide enough for a coarse filesystem is also wide enough
to call two different same-size files identical, and skipping a file the user edited is
the worse of the two failures.

## Keeping the window quick

Building a step's plan walks the whole `AddOns` tree, and a real one is tens of
thousands of files. Two things follow.

**A plan is built once per refresh.** The status, the file list on the card, and the
footer total all want the same answer, and the window used to ask for it three times —
27 tree walks to open a window with nine steps in it. `Update-Steps` builds each plan
once, keeps it in `$script:Plans`, and passes it to `Get-PtrSetupStepStatus -Action`;
`Update-Summary` reads the same cache.

**Only the plans a change could have altered are thrown away.** Picking a character
cannot alter what the addon copy would do, so re-walking a 30,000-file `AddOns` folder
to find that out is the difference between a dropdown that responds and one that looks
hung. `$script:Invalidates` maps each change to the steps that read it, and `Reset-Plan`
is the only way plans are discarded. Anything not in the map clears everything, which is
why `Overwrite` is deliberately absent — it reaches several steps and guessing wrong
shows the user a stale file count. `Update-All` clears the lot, because every path to it
(a rescan, a different client, an Apply, a Restore) has changed something wholesale;
Apply and Restore in particular have just written to the PTR folder. On a 3,000-file
install that takes picking a character or an account from about 1.3 seconds to 0.14.

`Ui.Tests.ps1` reads the map out of the script and checks it against what the module
actually does, so a step that starts reading a new option cannot quietly keep a stale
plan.

**Planning happens on another thread.** A persistent background runspace does the tree
walking; the UI thread polls for answers from a `DispatcherTimer`, which is the only
place a worker's result meets WPF. The worker never sees the live context — it gets a
`ConvertTo-PtrSetupSnapshot` of plain values and rebuilds its own, so no object is
touched by two threads. Requests go one step at a time so each card fills in as its own
answer arrives, cheapest step first (`copy_addons` is much the slowest and goes last).
A superseded answer is dropped by comparing a token, cancellation is `BeginStop` rather
than `Stop` so cancelling never blocks the thread it is protecting, and if a runspace
cannot be had at all the window falls back to planning inline — slower, but working.

**A step that cannot be worked out is recorded as an empty plan and reported**, never
left pending. The queue moves on in a `finally`, because a step still waiting is far
worse than a step got wrong: the summary waits on it, Apply stays disabled, and the
window sits on *working out what needs copying* with no way forward. That is precisely
how a single failing step used to present.

`Ui.Tests.ps1` lifts the scriptblock the window sends to the worker out of the source and
runs it in a real runspace, so a name the module does not export fails there rather than
as a window that never finishes loading. It also drives the whole queue by hand with the
timer stubbed out, which is how the fail-safe above is checked: break one step on
purpose and the other four still land.

**Nothing waits on a plan that is only about counting.** Whether a step *can* run is a
few `Test-Path` calls (`Get-PtrSetupStepBlocker`), so the tick boxes are live and
pre-ticked the moment the cards are drawn. Only the file counts arrive late. Ticking a
step and knowing how many files it will copy are separate questions, and making the
first wait on the second is what made the list look broken.

**The file list inside a step is built when it is first expanded**, not when the card is
drawn. Formatting tens of thousands of lines for a panel nobody has opened is most of a
refresh wasted.

**The first scan happens after the window is on screen**, hung off `ContentRendered`
rather than run before `ShowDialog`. Before that the window does not exist yet, so the
console the launcher opened reports what is loading — a few seconds of silence after a
double-click reads as a machine that has ignored you.

`Get-RelativeFile` is the inner loop of all of it, so it does its own string handling
rather than calling `Get-PathRelative` (and through it `GetFullPath`) once per file. For
the same reason `New-TreeCopyPlan` builds its `FileAction` objects inline instead of
calling `New-FileAction`: binding parameters to an advanced function costs a fraction of
a millisecond, which is nothing once and was about half the cost of planning a real
`AddOns` folder. `New-FileAction` remains the way to make one anywhere that is not that
loop, and a test holds the two shapes together property by property.

## Statements used as expressions

`$x = if (...) { @($y) }` does not do what it looks like. A statement used as an
expression has its output unrolled, so a one-item array comes back as the bare item and
an empty one as `$null`. Combined with strict mode, where `.Count` on either is a
terminating error, every step with exactly one file to copy threw — and the window could
only report *the property 'Count' cannot be found*, with no hint where. Assign inside
each branch instead. `Syntax.Tests.ps1` fails the build on the pattern.

## Strict mode and empty collections

The module runs under `Set-StrictMode -Version Latest`, where `.Count` on `$null` is a
terminating error rather than 0 — and `@($null).Count` is 1 rather than 0, so wrapping
is not the fix it looks like. A context arriving from the window can have its character
mapping cleared, so `Get-ContextCharacter` normalises it in one place and everything
reads through that rather than repeating a subtle idiom at each use.

This matters more than it sounds: a step that throws while being planned used to take
the whole window with it, so an empty mapping presented as five identical failures and a
list that never finished loading.

## Safety model

`Invoke-FileActionPlan` is the only thing that writes, and it:

1. Rejects the whole batch if any destination falls outside the selected PTR install.
   A mis-selected target fails loudly instead of copying over a live client.
2. Copies every file it is about to overwrite **or delete** into
   `<install>\_ptrsetup_backups\<timestamp>-<step_id>\`, preserving the relative path,
   and records every path it is about to **create** in the same `manifest.json`.
   `Restore-PtrSetupBackup` uses both halves, so an undo is a real undo: replaced files
   come back and added files go away. Restoring only the first half would leave a
   half-copied client behind, which is not what someone watching a step go wrong means
   by "undo". `-KeepAdded` opts out.
3. Returns without writing anything under `-PreviewOnly`.

The live client is only ever read from. No code path writes to the source install, and
`Steps.Tests.ps1` asserts the live tree is byte-identical after a full run.

## Config.wtf

`Config.wtf` is a flat `SET key "value"` file. The merge is deliberate rather than a
copy: `$script:ProtectedConfigKeys` (realm list, portal, account name, …) keep the
PTR's own values, so carrying settings across cannot repoint the PTR client at live
realms. Overrides — currently just `checkAddonVersion "0"` — are applied last.

## Two PowerShell editions

The launcher uses **Windows PowerShell 5.1** (it ships with Windows, so users install
nothing); development and CI also run **PowerShell 7**. Two gaps bite, and both are
wrapped rather than repeated:

| Gap | Wrapper |
|-----|---------|
| `[System.IO.Path]::GetRelativePath` is .NET Core only | `Get-PathRelative` |
| `Set-Content -Encoding UTF8` writes a BOM on 5.1, none on 7 | `Write-TextFileNoBom` |
| `$IsWindows` / `$IsMacOS` do not exist on 5.1 (and `Set-StrictMode` makes reading them fatal) | `Test-WindowsHost` / `Test-MacHost` |
| 5.1 decodes a BOM-less script as ANSI, not UTF-8 | every source file carries a UTF-8 BOM, enforced by `Encoding.Tests.ps1` |

That last one is the worst of the three, because it does not degrade — it stops the
tool from starting. Under Windows-1252 the three UTF-8 bytes of an em dash come back
as three characters ending in `U+201D`, and PowerShell accepts curly quotes as real
string delimiters. One em dash inside a single-quoted string therefore opens a string
that is never closed, and the file fails to parse with a message about a missing
terminator hundreds of lines later. Everywhere the tests run reads BOM-less UTF-8
correctly, so nothing catches it except the byte-level check — and the one machine it
breaks on is the one the double-click launcher uses.

CI runs the suite under both editions so a regression here shows up as a red build
rather than a user's crash.

## Noticing changes

The window polls `Get-WowFolderFingerprint` every few seconds: a fixed handful of
directory timestamps and one process lookup, about five milliseconds. A directory's own
timestamp moves when an entry is added or removed inside it, which covers every event
worth noticing — the PTR growing a `WTF` folder, a character appearing under a realm, an
addon installed, the game quitting.

A `FileSystemWatcher` is the other way to do this and is worse here: its events arrive on
a thread that must not touch WPF, and WoW rewriting its whole `WTF` tree on exit delivers
them by the hundred. A timer that looks costs less and cannot surprise anyone.

The refresh is deliberately narrower than *Rescan now*: the installs and the folder box
stay as they are, so a refresh cannot move the selection under someone mid-decision. It
holds off entirely while a run is in progress or planning is already going, and a
character mapping the user arranged themselves is never re-guessed — `$script:Mapping
Touched` records that they have taken it over.

## Testing

`tests/TestRunner.ps1` is a small `Describe`/`It` harness — Pester would mean every
contributor needs Gallery access before running anything, and the suite is worth more
than the framework. `tests/TestHelpers.ps1` builds fake `World of Warcraft` trees in
temp folders; each `It` gets its own `$script:TestDrive`, cleaned up afterwards.

**Nothing may depend on the machine running it.** Detection is where this bites: a test
that asserts `Find-WowFolder` returns the tree it just built passes on a machine without
the game and fails on one with it, because finding the real install first is correct
behaviour. `-SkipDefaultLocations` exists on `Get-WowRootCandidate` and `Find-WowFolder`
for exactly this, and where the test is *about* the ordering between an override and a
real install, `Use-FakeInstalledCopy` in `Detect.Tests.ps1` injects the installed copy by
stubbing `Get-WowRegistryPath` inside the module and restoring it afterwards. Without
that injection those tests are vacuous everywhere the game is absent — which is every
machine CI runs on, so they would pass forever while the behaviour rotted.

Two layers:

- **Unit** — `Detect`, `ConfigWtf`, `FileOps`, `Steps`, `Ui`: one function against small
  fixtures.
- **Integration** — `Integration.Tests.ps1` builds the *shipped* mock install
  (`tools/New-MockWowFolder.ps1`, the same one a user runs by hand) and walks the guide
  end to end, asserting on disk contents: one test per guide instruction, plus undo,
  idempotency, per-option behaviour, and awkward cases. Using the shipped builder rather
  than a test-only fixture means the builder is covered too — if it stops producing a
  realistic install, the suite fails. Tree comparisons are SHA-256 per file, which is
  how "the live client is untouched" and "undo restores exactly" are asserted.

Most of the window cannot be run by the suite at all, which makes the mistakes
PowerShell only reports when a line executes the dangerous ones.
`Syntax.Tests.ps1` walks the syntax tree of every file for three of them: a call to a
function that does not exist, a call naming a parameter its target does not have, and a
switch given its value with a space instead of a colon. That last one is not a typo but
a trap — `-Blocked $false` reads the switch as present and `$false` as a positional
argument, so it means the opposite of what it looks like and an advanced function
rejects it outright. It shipped once, and emptied the step list.

What the tests do *not* cover: the window actually rendering. `Ui.Tests.ps1` closes
part of that gap without WPF — it parses `PtrUiSetup.ps1` and `MainWindow.xaml` and
asserts every `$ui.<Name>` the script reaches for exists in the XAML and vice versa,
which catches the failure this pairing really has (a renamed control that only breaks
in front of a user). Rendering, layout and click behaviour still need a human on
Windows.

## A note on the loop-variable trap

`foreach ($addon in $AddOn)` looks like two variables. PowerShell names are
case-insensitive, so it is one — and if `$AddOn` is a typed parameter (`[string[]]`),
each assignment is coerced back through that type and the loop variable becomes a
one-element array. It cost an afternoon here. Loop variables never share a name with a
parameter in this codebase.
