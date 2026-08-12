# Architecture

## The shape of it

```
browser (one page, vanilla JS)
   │  every action POSTs and gets a full snapshot back
   ▼
app.py            FastAPI, 127.0.0.1 only
   ▼
session.py        the user's selection; auto-guesses the rest
   ▼
steps/            the guide as data: Step objects with plan() / status() / apply()
   ▼
detect.py · fsops.py · configwtf.py     pure filesystem logic, no web layer
```

Two rules keep it maintainable:

1. **The server owns all state.** Every mutating endpoint returns the complete snapshot
   (`Session.snapshot()`), and the page re-renders from it. There is no client-side
   model to drift out of sync, which is why `app.js` has no state beyond the checkbox
   set.
2. **Plan, then apply.** No step writes during planning. `plan()` returns
   `FileAction`s; the same list is what the preview shows and what `apply()` executes.
   A preview is therefore never a different code path from the real run — it is the
   real run with `dry_run=True`.

## Steps

A step is one item in the guide (see [`GUIDE.md`](GUIDE.md)). Both kinds implement one
interface so the wizard renders them in a single list:

- `mode = "auto"` — `plan()` returns file actions, `apply()` performs them.
- `mode = "manual"` — instructions plus a `status()` that watches the filesystem, so
  the step ticks itself off once the user has done it (or they can tick it by hand).

To add a step: write a class in `steps/library.py`, append it to `STEPS`. The API,
preview, backup and UI need no changes. Keep the file-layout knowledge inside the step
— `detect.py` knows about folders, steps know about *which* folders matter.

## FileAction

```python
FileAction(kind, source, dest, size, note, content)
```

`kind` is `create` / `overwrite` / `skip`. Most actions copy `source` → `dest`. A step
that generates a file instead (the `Config.wtf` merge) leaves `source` empty and sets
`content`, which the applier writes verbatim. Everything else — preview rendering,
byte totals, backup selection — treats both identically.

## Safety model

`apply_actions()` is the only thing that writes, and it:

1. Rejects the whole batch if any `dest` falls outside the selected PTR install
   (`UnsafePathError`). A mis-selected target fails loudly instead of copying over a
   live client.
2. Copies every file it is about to overwrite into
   `<install>/_ptrsetup_backups/<timestamp>-<step_id>/`, preserving the relative path,
   with a `manifest.json`. `restore_backup()` replays it.
3. Returns without writing anything when `dry_run` is set.

The live client is only ever read from. No code path writes to the source install.

## Config.wtf

`Config.wtf` is a flat `SET key "value"` file. The merge is deliberate rather than a
copy: `PROTECTED_KEYS` (realm list, portal, account name, …) keep the PTR's own values,
so carrying settings across cannot repoint the PTR client at live realms. Overrides —
currently just `checkAddonVersion "0"` — are applied last.

## Testing

`tests/helpers.py` builds fake `World of Warcraft` trees under `tmp_path`: a populated
live client and an empty PTR one. Every layer is tested against those, including the
API via `TestClient`, so the suite needs neither WoW nor a browser.

What tests do *not* cover: the actual browser rendering in `web/`, and behaviour
against a real Blizzard install. Both need a manual pass — the README explains how to
point the app at a fake tree with `PTRSETUP_EXTRA_ROOTS`.
