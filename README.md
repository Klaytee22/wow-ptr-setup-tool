# WoW PTR UI Setup

Copy your live World of Warcraft UI — addons, addon settings, keybinds, macros and frame
layout — onto the PTR client, instead of hand-copying folders and hoping you got the
right one.

Double-click, get a window. It does what it can itself and explains the rest, watching
your folders and ticking each step off as it sees it done.

## Running it

**[Download the zip.](https://github.com/Klaytee22/wow-ptr-setup-tool/archive/refs/heads/master.zip)**

**Extract it first** — Documents or Desktop is fine, `Program Files` is not, and running
it from inside the zip preview will not work. Then **double-click
`Start-PtrUiSetup.cmd`**.

Nothing to install: it uses the PowerShell that ships with Windows. Keep the folder as it
comes; the launcher looks for the other files beside it. **Windows only.**

## What it does

| # | Step | | |
|---|------|---|---|
| 1 | Install and launch the PTR client once | manual | It needs to build its folders before anything can go in them |
| 2 | Copy your character to the PTR | manual | Blizzard's character copy; the tool spots the result |
| 3 | Quit World of Warcraft | manual | Ticks itself off when the game closes — WoW rewrites its settings on exit and would undo the copy |
| 4 | Break ties between macros on your LIVE client | opt-in | The only step that touches your live client, and it is never ticked for you. Needed if an action bar addon is to tell your macros apart |
| 5 | Save your action bars on the live client | manual | `/abs save` with an action bar addon. Your bars live on Blizzard's servers, so this is the only way to carry them |
| 6 | Copy your addons | auto | Optionally clearing PTR-only addons first |
| 7 | Carry over `Config.wtf` | auto | Resolution, graphics, sound — merged, so the PTR keeps pointing at PTR realms |
| 8 | Copy account-wide addon settings | auto | Every addon's profiles, keybinds and macros, with each addon pointed at your PTR character |
| 9 | Copy per-character settings | auto | Per character: addon settings, addon list, frame layout, keybinds, macros |
| 10 | Allow out-of-date addons | auto | So addons built for live still load |
| 11 | Launch the PTR and check | manual | Enable anything unticked, `/abs restore`, and undo from here if it looks wrong |

Every automated step ticks on and off separately, and each one lists the exact files it
would write — open *Show the N file(s)* on a card and that is the plan, file by file.

These come from a written guide, transcribed in [`docs/GUIDE.md`](docs/GUIDE.md) along
with the eight places this tool deliberately does something different.

## If something looks wrong in game

Four things go wrong often enough to write down, and none of them are the copy itself:

| Symptom | Cause |
|---|---|
| Bars in the wrong place, unit frames unstyled | The addon loaded its default profile |
| Bar slots empty | Blizzard's copy does not reliably bring them; an addon has to save them first |
| An addon's slash command missing on the PTR | It did not load — usually installed after the last copy |
| `Unable to restore item to slot`, repeatedly | Macros sharing a name, or items you are not carrying |

[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) has the fix for each.

## Safety

- **Nothing is written until you press Apply and confirm.**
- **Every step backs up first**, and Restore is a real undo: replaced files go back *and*
  added files are removed. One backup per step, so undoing a whole run means restoring
  each. *Delete all* clears old backups and touches nothing else.
- **Your live client is read, never written** — except step 4, which is off unless you
  tick it and says so twice before it runs.
- **Running it twice is a no-op.** Anything already copied is left alone.
- **`Config.wtf` is merged, not pasted**, so the PTR keeps its own realm list. Pasting it
  wholesale is how you end up pointed at live realms.

Quit WoW before applying — it rewrites its settings on exit and will undo the copy.

## Where it looks for your game

There is nothing to configure. The window opens on the folder it used last, or the one
Blizzard recorded in the registry, or the usual `C:\Program Files (x86)\World of Warcraft`
— and **Browse** fixes it if all three are wrong. Either the `World of Warcraft` folder
or a client folder inside it will do.

Every client folder is offered — `_retail_`, `_classic_`, `_anniversary_`, `_ptr_`,
`_ptr2_`, the betas — including ones released after this was written, which it recognises
from a file every client carries.

It also watches. Launching the PTR, copying a character, installing an addon or quitting
the game all register within a few seconds; *Rescan now* is for when you want everything
re-read from scratch.

## Docs

- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — when the game looks wrong afterwards
- [`docs/FIRST-RUN.md`](docs/FIRST-RUN.md) — try it against a fake install first
- [`docs/GUIDE.md`](docs/GUIDE.md) — the guide it automates, and where it deviates
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how it works, and how to work on it
- [`docs/PUBLISHING.md`](docs/PUBLISHING.md) — cutting a release and handing it out

MIT licensed.
