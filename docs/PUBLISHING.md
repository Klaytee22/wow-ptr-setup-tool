# Handing it out

The repository is at <https://github.com/Klaytee22/wow-ptr-setup-tool> and CI runs
`tools/Invoke-Gate.ps1` on every push. What is left is getting it to other people.

## Cut a release

One stable link instead of a branch name, and a version number when somebody reports
something. Until the first one exists, `/releases/latest` is an empty page — so cut it
before handing the link to anybody. [Draft a new release](https://github.com/Klaytee22/wow-ptr-setup-tool/releases/new),
type the tag (`v1.1.0`, matching `ModuleVersion` in the manifest), choose *Create new tag
on publish*, publish. GitHub attaches *Source code (zip)* itself — nothing to build.

Hand out <https://github.com/Klaytee22/wow-ptr-setup-tool/releases/latest>, which follows
the newest release and stays correct after the next one.

## A message you can paste

```
WoW PTR UI Setup — copies your live addons, addon settings, keybinds, macros and
UI layout onto the PTR client, so you are not rebuilding your interface every patch.

Download: https://github.com/Klaytee22/wow-ptr-setup-tool/releases/latest
  → under Assets, "Source code (zip)"
  (or the green Code button on the repo → Download ZIP)

1. Extract the zip to Documents or Desktop. Do not run it from inside the zip.
2. Double-click Start-PtrUiSetup.cmd.

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
