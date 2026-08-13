# First run on Windows

The window has never been opened. Everything underneath it is well tested — the file
operations, the `Config.wtf` merge, backups and undo all have tests, and the whole
mock walkthrough below has been run headlessly and asserted on disk. What has never
run is WPF itself: rendering, layout, and what happens when you click things.

So this page is two things at once — a walkthrough of the tool, and a checklist for
the first person to see it on a screen. Do it against the **mock install**, not your
real game folder. Nothing here touches your actual WoW install.

## 1. Build the fake install and open the window

From the repo folder, in PowerShell:

```powershell
.\tools\New-MockWowFolder.ps1 -Launch
```

That builds `PtrUiSetup-Mock\World of Warcraft` on your desktop and opens the window
pointed at it. If you have run it before, add `-Force` to rebuild.

It creates a live client (`_classic_`: 5 addons, 3 characters, full settings) and a
PTR client (`_classic_ptr_`: launched once, one copied character, one stale addon).
**Every file is stamped `LIVE` or `PTR`**, so after applying you can open anything on
the PTR side and see whether it genuinely came across.

> If the window does not appear at all, run `.\PtrUiSetup.ps1 -ListSteps` — that uses
> the same module without WPF. If it prints nine steps, the module loaded and the
> problem is in the window; that distinction is most of the debugging.
>
> If it says the session is multi-threaded, double-click `Start-PtrUiSetup.cmd`
> instead — that launcher passes `-STA`, which is what WPF needs. Then point the
> folder box at the mock folder on your desktop.

## 2. What the window should show before you touch anything

These numbers are exact — they have been computed against this same mock install, so
anything different is a finding worth reporting.

**1 · Game folder** — the box holds the path to the mock's `World of Warcraft` folder,
with **Browse…** and **Detect** beside it, and underneath:
`2 client(s) found: Classic, Classic PTR`. Below that, `Classic — …\_classic_` on the
left and `Classic PTR — …\_classic_ptr_` on the right. No amber warning.

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
| Copy your addons | READY | Show the 12 file(s) — 747 B |
| Carry over `Config.wtf` | READY | Show the 1 file(s) — 266 B |
| Copy account-wide addon settings | READY | Show the 5 file(s) — 214 B |
| Copy per-character settings | READY | Show the 7 file(s) — 392 B |
| Allow out-of-date addons | READY | Show the 1 file(s) — 170 B |

**Footer** — `5 step(s) selected · 26 file(s) · 1.7 KB`, with *Preview changes* and
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
- [ ] Does the progress bar move during Apply, or does the window freeze?
- [ ] Does anything throw? Errors now land in the Results box as `[fail] …` instead of
      closing the window, so the message should be readable rather than lost.
- [ ] Does the **folder box** behave — Enter commits, clicking away commits, Browse
      opens where you already are, and the second launch opens on the folder you left
      it on?
- [ ] On your *real* install, does **Detect** find it? That path comes from the
      registry first, so it should be instant and exact.

A screenshot is worth more than a description for any of these.
