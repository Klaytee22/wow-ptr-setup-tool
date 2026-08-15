# Publishing and sharing

The repository is at <https://github.com/Klaytee22/wow-ptr-setup-tool>, already pushed
and already running CI. What is left is getting it to other people.

## Sharing it with your guild

### Cut a release

A release gives people one stable link instead of a branch name, and tells you which
version someone is on when they report something.

```powershell
git tag -a v1.0.0 -m "First release"
git push origin v1.0.0
```

Then on GitHub: **Releases → Draft a new release → choose the `v1.0.0` tag → Publish**.
GitHub attaches *Source code (zip)* on its own, so there is nothing to build or upload.
The link to hand out is:

<https://github.com/Klaytee22/wow-ptr-setup-tool/releases/latest>

That URL always points at the newest release, so it stays correct after the next one.

### The one thing that will generate messages

Windows marks every file that came off the internet. An extracted `.cmd` carrying that
mark shows *"Windows protected your PC"* instead of running, and people read that as a
virus warning rather than as a shrug.

Tell them: **right-click the zip → Properties → tick Unblock → OK, then extract.** One
tick on the zip clears every file inside it. Doing it after extracting means doing it
one file at a time.

### A message you can paste

```
WoW PTR UI Setup — copies your live addons, addon profiles, keybinds, macros and
UI layout onto the PTR client, so you are not rebuilding your interface every patch.

Download: https://github.com/Klaytee22/wow-ptr-setup-tool/releases/latest
  → under Assets, "Source code (zip)"

1. Right-click the zip → Properties → tick "Unblock" → OK.  (Windows blocks
   downloaded scripts otherwise and shows a scary-looking box.)
2. Extract it to Documents or Desktop.
3. Double-click Start-PtrUiSetup.cmd.

Windows only. Nothing to install — it uses the PowerShell that ships with Windows.

Quit WoW first (both clients), and copy your character to the PTR before you run it.
Each step shows the exact files it will write — open the "Show the N file(s)" list on
a card before you Apply. Every step that writes into the PTR backs it up first, and
there is a Restore dropdown that undoes any of them.

It only ever writes inside the PTR folder. Your live client is read and never
written to.
```

### If someone reports a problem

Ask for the **Results box** at the bottom of the window — errors land there with a line
number, and that is usually enough to place the fault. `Run-Tests.cmd` on their machine
is the next thing: it needs no game folder and confirms whether the problem is their
install or the tool.

## Day to day

```powershell
cd <repo>
git status
git add -A
git commit -m "Fix the thing"
git push
```

GitHub Actions runs `tools/Invoke-Gate.ps1` on Windows PowerShell 5.1, PowerShell 7 on
both Windows and Linux, and PSScriptAnalyzer. Run the gate before pushing and it will
have told you already.
