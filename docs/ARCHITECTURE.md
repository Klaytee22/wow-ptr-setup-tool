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
