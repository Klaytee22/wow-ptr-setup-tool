# Handing it out

The repository is at <https://github.com/Klaytee22/wow-ptr-setup-tool> and CI runs
`tools/Invoke-Gate.ps1` on every push. What is left is getting it to other people.

## The link to hand out

<https://github.com/Klaytee22/wow-ptr-setup-tool/archive/refs/heads/master.zip>

Clicking it downloads the zip. That matters more than it sounds: a release page puts the
zip under *Assets*, below the notes and collapsed on a phone, and somebody who does not
use GitHub will not find it. This link has nothing to find.

It always carries the current `master`, so it never needs changing and nobody ends up on
a stale build. The cost is that every download reports the same version until you bump
one, which is what the next section is for.

## Cut a release

Releases are the notes and the version number, not the download. Worth one whenever
there is something to say. [Draft a new release](https://github.com/Klaytee22/wow-ptr-setup-tool/releases/new),
type the tag, choose *Create new tag on publish*, publish — GitHub attaches the zip
itself, nothing to build.

**Bump `ModuleVersion` in `Modules/PtrUiSetup/PtrUiSetup.psd1` to match the tag, and push
that before you publish.** The window writes that version into `%TEMP%\ptrsetup-error.log`,
so it is what places a report against a build — and it is only worth anything if the two
agree.

For a download pinned to one release rather than to `master`, the same direct form works:
`…/archive/refs/tags/v1.0.zip`.

## A message you can paste

```
WoW PTR UI Setup — copies your live addons, addon settings, keybinds, macros and
UI layout onto the PTR client, so you are not rebuilding your interface every patch.

1. Download (this link starts it straight away):
   https://github.com/Klaytee22/wow-ptr-setup-tool/archive/refs/heads/master.zip
2. Extract it to Documents or Desktop. Do not run it from inside the zip.
3. Double-click Start-PtrUiSetup.cmd.

Windows only, nothing to install. Before you start: copy your character to the PTR,
then quit WoW completely — it rewrites its settings on exit and would undo the copy.

Work down the steps in order. Each one lists the exact files it will write before you
press anything, backs them up first, and can be undone from the Restore dropdown.

It writes inside your PTR folder only. One step can fix duplicate macro names on your
live client, and that one is never ticked for you — it says so on its own card and
again before it runs.

Bars come up empty or in the wrong place? That is Blizzard's character copy, not this.
docs/TROUBLESHOOTING.md has the fix.
```

## When someone reports a problem

Ask for two things:

- the **Results box** at the bottom of the window — errors land there with a line number
- `%TEMP%\ptrsetup-error.log` if the window closed without opening, which holds the
  message, the line, and their PowerShell and Windows versions

Between them that is usually enough to place the fault without a back-and-forth.
