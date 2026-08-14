# First run on Windows

The window has never been opened. Everything underneath it is well tested — the file
operations, the `Config.wtf` merge, backups and undo all have tests, and the whole
mock walkthrough below has been run headlessly and asserted on disk. What has never
run is WPF itself: rendering, layout, and what happens when you click things.

So this page is two things at once — a walkthrough of the tool, and a checklist for
the first person to see it on a screen. Do it against the **mock install**, not your
real game folder. Nothing here touches your actual WoW install.

## 1. Build the fake install and open the window

**Double-click `Try-It-Safely.cmd`** in the repo folder.

That builds `PtrUiSetup-Mock\World of Warcraft` on your desktop and opens the window
pointed at it, rebuilding the folder from scratch each time you run it.

> Double-clicking a `.ps1` will not work — Windows opens those in Notepad. So does
> pasting `.\tools\New-MockWowFolder.ps1` into Command Prompt. The `.cmd` files are
> the clickable entry points; a terminal has to be **PowerShell**, where
> `.\tools\New-MockWowFolder.ps1 -Launch -Force` does the same thing.

It creates a live client (`_classic_`: 5 addons, 3 characters, full settings) and a
PTR client (`_classic_ptr_`: launched once, one copied character, one stale addon).
**Every file is stamped `LIVE` or `PTR`**, so after applying you can open anything on
the PTR side and see whether it genuinely came across.

> If the window does not appear at all, the console window that opened behind it
> holds the error. Double-click `Run-Tests.cmd` as a second opinion: if the suite
> passes, the module is fine and the problem is in the window itself, which is most
> of the debugging done.

## 2. What the window should show before you touch anything

These numbers are exact — they have been computed against this same mock install, so
anything different is a finding worth reporting.

**1 · Game folder** — the box holds the path to the mock's `World of Warcraft` folder,
with **Browse…** and **Detect** beside it, and underneath:
`2 client(s) found: Classic, Classic PTR`. Below that, `Classic — …\_classic_` on the
left and `Classic PTR — …\_classic_ptr_` on the right.

Worth poking while you are here, since none of it has run:

- Type nonsense into the box and press **Enter** → *That folder does not exist — check
  the path, or press Detect.* The client dropdowns should empty out.
- Put the real path back, or press **Browse…** — the picker should open *at* the folder
  you were on, not at the top of the tree.
- **Detect** searches your machine for a real install. On this mock it will most likely
  find your actual WoW folder, or say it could not find one. Either is fine; just put
  the mock path back afterwards. (Detect is instant — if it visibly hangs, that is a
  finding.)

**2 · Account & characters** — `112233445#1` on both sides, and one mapping row:

```
Sunderfury                     [ Sunderfury — Whitemane        ▼ ]
Classic PTR Realm 1
```

The dropdown on that row should offer *— skip this character —* plus the three live
characters (Bankalt, Mendicant, Sunderfury). **Check the skip entry is not blank** —
that was a bug, and it is the one to eyeball.

**3 · Steps** — nine cards. The first three are `MANUAL` and should already read
*done* (the PTR has a `WTF` folder, one character is mapped, no WoW is running — if
WoW *is* running, step 3 will say so, which is correct). Then:

| Step | Pill | Expander |
|---|---|---|
| Copy your addons | READY | Show the 12 file(s) — 647 B |
| Carry over `Config.wtf` | READY | Show the 1 file(s) — 266 B |
| Copy account-wide addon settings | READY | Show the 6 file(s) — 792 B |
| Copy per-character settings | READY | Show the 7 file(s) — 392 B |
| Allow out-of-date addons | READY | Show the 1 file(s) — 170 B |

**Footer** — `5 step(s) selected · 27 file(s) · 2.2 KB`, with *Preview changes* and
*Apply selected steps* both enabled.

Open one of those expanders. The file list should be **multi-line**, one action per
row, like `create    C:\…\Interface\AddOns\WeakAuras\WeakAuras.lua`. If it is all
crammed onto one line, the `AcceptsReturn` fix did not take.

## 3. Preview

Press **Preview changes**. The Results box should print one line per step:

```
--- Preview (nothing is written) ---
[ok]   Copy your addons — Preview: 12 file(s).
[ok]   Carry over Config.wtf — Preview: 1 file(s).
…
```

Again: **multi-line**. The Results box was single-line before, which put all of that
on one row.

Nothing on disk should change. If you want to be sure, note the mock folder's
modified date before and after.

## 4. Apply

Press **Apply selected steps**. Confirm the dialog — it should mention that 2 files
will be **removed** (the stale addon) and that everything is backed up first.

Then check, on the PTR side of the mock folder:

- `_classic_ptr_\Interface\AddOns` now has **5** folders — Bartender4, Details,
  Plater, Questie, WeakAuras — and `OldPtrAddon` is **gone**.
- `_classic_ptr_\WTF\Config.wtf` still says
  `SET realmList "us.logon-ptr.worldofwarcraft.com"` and `SET portal "us-ptr"`, while
  `gxResolution` is now `2560x1440` (the live value). **This is the important one** —
  it is the difference between this tool and pasting the file wholesale, which would
  point the PTR client at live realms.
- `SET checkAddonVersion "0"` is in that file.
- Open any copied file, e.g. the character's `AddOns.txt` — it should say `LIVE`.
- `_classic_ptr_\WTF\Account\112233445#1\SavedVariables\Bartender4.lua` has a new
  line near the top:
  `["Sunderfury - Classic PTR Realm 1"] = "Sunderfury - Whitemane",` — the PTR
  character now loads the profile its live counterpart used, and the three live keys
  below it are untouched. That is the "Point addon profiles at your PTR character"
  option; untick it and this line does not appear.
- `_classic_ptr_\_ptrsetup_backups\` has one folder per step that wrote something.

## 5. Apply again

Every automated step should now read **done**, with *Already up to date — nothing left
to copy* or *Every file is already on the PTR*. The footer should say
`5 step(s) selected · already up to date, nothing to copy` and both buttons should be
disabled.

This is the check that a second run is a genuine no-op — it did not used to be.

## 6. Restore

Pick a backup in **4 · Options & safety** and press **Restore**.

Note that a backup is **per step, not per Apply**. An Apply that ran five steps leaves
one entry per step that wrote something, and Restore undoes the one you picked — the
confirmation dialog says so. To roll the whole run back, restore each entry.

Restore the addon one and `OldPtrAddon` should reappear while the five copied addons
disappear: added files are removed as well as replaced ones being put back.

## 7. When you are done

Delete the `PtrUiSetup-Mock` folder from your desktop.

One other thing the tool leaves behind: `%LOCALAPPDATA%\PtrUiSetup\settings.json`,
which is how it remembers your folder between launches. Delete it if you want to see
first-launch detection again. Nothing else on your machine was touched.

Then, on your real install, the honest order is: **Preview first, read the file list,
and only then Apply.** Quit WoW before applying — it rewrites `WTF` when it exits and
will undo the copy.

## Worth reporting back

Everything visual is unverified, so anything that looks wrong probably is. Specifically:

- [ ] Do the **dropdowns** read clearly? They keep the system's light popup background
      while the window is dark, so their text is pinned dark on purpose. If items look
      white-on-white or otherwise unreadable, that is the one styling guess that could
      not be settled without a screen.
- [ ] Does the **Apply** button read dark-on-gold, not light-on-gold?
- [ ] Do long instruction paragraphs on the step cards **wrap**, or do they clip?
- [ ] Does the window **resize** sensibly — does the steps list scroll rather than
      squashing the footer?
- [ ] Does the progress bar move during Apply, and does the window stay usable? The
      copy runs on a background thread, so it should never grey out.
- [ ] Does anything throw? Errors now land in the Results box as `[fail] …` instead of
      closing the window, so the message should be readable rather than lost.
- [ ] Does the **folder box** behave — Enter commits, clicking away commits, Browse
      opens where you already are, and the second launch opens on the folder you left
      it on?
- [ ] On your *real* install, does **Detect** find it? That path comes from the
      registry first, so it should be instant and exact.

A screenshot is worth more than a description for any of these.
