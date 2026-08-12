# WoW PTR UI Setup

Copy your live World of Warcraft UI — addons, addon profiles, keybinds, macros and
frame layout — onto the PTR client, without hand-copying folders and hoping you got
the right one.

The tool opens a local web page and walks the whole setup top to bottom. Anything it
can do itself, it does; anything only you can do (installing the PTR client, running a
character copy) it explains, then watches the filesystem and ticks itself off once
it sees the step is done.

```
┌─ 1 Clients ────────── live client  →  PTR client
├─ 2 Account & chars ── account folder pair + per-character mapping
├─ 3 Steps ─────────── 6 automated · 2 hand-held, each previewable
└─ 4 Options & safety ─ what to include, and one-click restore of any run
```

## Running it

```bash
pip install -e .
ptrsetup                 # opens http://127.0.0.1:<port>/ in your browser
```

Or without installing:

```bash
pip install -r requirements.txt
python -m ptrsetup
```

Flags: `--port N` to pin a port, `--no-browser` to skip opening a tab.

The server binds to `127.0.0.1` only. It reads and writes your game folders, so it is
never reachable from your network.

### A standalone .exe

For handing to someone who does not have Python:

```bash
pip install -e ".[build]"
python tools/build_exe.py        # -> dist/ptrsetup.exe (or dist/ptrsetup)
```

## What it does

| # | Step | Mode | What happens |
|---|------|------|--------------|
| 1 | Install and launch the PTR client once | manual | Waits until the PTR folder has a `WTF` tree — nothing can be copied before that |
| 2 | Copy your character to the PTR | manual | Blizzard's character copy; the tool detects the result |
| 3 | Copy your addons | auto | `Interface/AddOns` → PTR |
| 4 | Carry over `Config.wtf` | auto | Merges live cvars into the PTR's file, keeping PTR realm/account keys |
| 5 | Copy account-wide addon settings | auto | `WTF/Account/<ACCOUNT>/SavedVariables` (+ macros, keybinds) |
| 6 | Copy per-character settings | auto | Per character: `SavedVariables`, `AddOns.txt`, `layout-local.txt`, macros, keybinds |
| 7 | Allow out-of-date addons | auto | Sets `checkAddonVersion "0"` so live-built addons load on a higher interface version |
| 8 | Launch the PTR and check the UI | manual | Closing check, with a pointer back to Restore if something looks wrong |

Every automated step is **previewable** — press *Preview changes* to get the exact file
list with no writes — and **individually selectable**, so you can copy addons without
touching settings, or the reverse.

## Safety

- Nothing is written until you press **Apply**.
- Every file that gets overwritten is copied into `_ptrsetup_backups/<timestamp>-<step>/`
  inside the PTR folder first, with a manifest. **Restore** puts a whole run back.
- Writes are constrained to the selected PTR folder — a planned write that would land
  anywhere else aborts the run rather than touching it.
- The tool never writes to your live client. It only reads from it.
- `Config.wtf` is merged, not copied: `realmList`, `portal`, `accountName` and friends
  keep the PTR's own values, so the PTR client keeps pointing at PTR realms.

Quit the WoW client before applying — WoW rewrites `WTF` when it exits and will
happily undo the copy.

## Layout

```
src/ptrsetup/
  detect.py      find installs, accounts, realms, characters
  fsops.py       plan → preview → apply, with backup and restore
  configwtf.py   parse/merge/render Config.wtf
  steps/         the guide, expressed as data (base.py + library.py)
  session.py     what the user picked; re-derives everything else
  app.py         local FastAPI server
  web/           the one-page wizard (vanilla JS, no build step)
tests/           59 tests against fake install trees — no WoW needed
```

Adding a step means writing a class in `steps/library.py` and appending it to `STEPS`.
The wizard, the preview, the backup and the API pick it up with no other changes.

## Development

```bash
pip install -e ".[dev]"
pytest            # 59 tests, no game install required
ruff check .
```

Tests build fake `World of Warcraft` trees under `tmp_path`, so the suite runs on CI
machines that have never seen the game. To drive the real UI against a fake install:

```bash
PTRSETUP_EXTRA_ROOTS="/path/to/fake/World of Warcraft" python -m ptrsetup
```

`PTRSETUP_EXTRA_ROOTS` is a `os.pathsep`-separated list of extra folders to scan.

## Status

v0.1 — working end to end against fake installs; not yet exercised against a real PTR
install. See [`docs/GUIDE.md`](docs/GUIDE.md) for where each step came from and what is
still open.

MIT licensed.
