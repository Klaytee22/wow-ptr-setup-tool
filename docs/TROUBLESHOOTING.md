# When something looks wrong

Four things that have actually gone wrong, what causes each, and what to do. Everything
here is about the game rather than the copy: the file operations have tests, and these
do not.

## Contents

- [Will my action bars look the same?](#will-my-action-bars-look-the-same)
- [Two macros with the same name](#two-macros-with-the-same-name)
- [An addon that loads on live and errors on the PTR](#an-addon-that-loads-on-live-and-errors-on-the-ptr)
- [What about Blizzard's "Copy Account Data" button?](#what-about-blizzards-copy-account-data-button)

## Will my action bars look the same?

Three separate things, from three different places.

**The abilities sitting in each bar slot are server-side.** WoW keeps them on the
character, not in any file on your disk — which is why an addon has to read them
through the game API to back them up at all. So this tool cannot move them, cannot
break them, and does not try.

**Blizzard's character copy does not appear to bring them either.** On the run this was
tested against — an Anniversary live client onto its PTR — everything else arrived and
the bars came up empty. Treat that as one observation rather than a rule, but plan for
it: the recipe below is quick and costs nothing if the bars turn out fine.

**Where the bars are — Bartender, ElvUI, Dominos** — is a profile in
`WTF\Account\<ACCOUNT>\SavedVariables\<Addon>.lua`, which the account settings step copies.

**Which profile loads** is the part that used to need doing by hand. Those addons pick
one out of a table keyed by `"Character - Realm"`, and the PTR realm has a different
name, so the copied file has your profile in it but no key that matches — the addon
falls back to its default and the bars come up bare. The **Point addon profiles at
your PTR character** option (on by default) adds that one key, so the profile its live
counterpart used is the one that loads. This is what the source guide means by *"Log
in and go to each addon and copy the profile from your Live Character's profile"*;
[`docs/GUIDE.md`](docs/GUIDE.md) has the detail.

If an addon still comes up on defaults, pick the profile once in its own options — in
Bartender that is **Profiles → Copy From → your live character** — and it sticks. That
means the profile came across and only the selection missed, which is worth reporting:
it is a bug in this tool, not something you should have to do.

### Getting the bar slots across anyway

Nothing outside the game can read or write those slots, so this has to be done by an
in-game addon, and the addon's own saved data is then just another file this tool
copies — both account-level and character-level `SavedVariables` are covered, so
whichever scope the addon uses comes across.

**Take a build that matches your client**, which the addon installers get right on their
own. The one that goes wrong is picking an abandoned addon: the long-recommended
[Action Bar Saver] was last updated in 2010 and does not load on a modern client at all,
so its `/abs` command does not exist and it looks as though nothing was installed. Two
that are maintained:

- [ActionBarSaver: Reloaded] — a rewrite of the original. It files sets by **class**,
  not by character, so the copied character having a different name or realm makes no
  difference to it: land the file on the PTR and `/abs list` shows your sets. Its own
  data is account-level, so the account settings step carries it.
- [TBCA Action Bars Saver] — ten bars, and it copes with spells that are missing on the
  destination.

The order that works, without copying your character again:

1. **On live:** install it, log in on the character whose bars you want, and save a
   profile with whatever command the addon uses.
2. **Log out.** WoW writes `SavedVariables` on exit, so the file does not exist until
   you do. Skipping this is the most common way to get an empty result.
3. **Run this tool** — the addon and its saved data go over with everything else.
4. **On the PTR:** log in and restore the profile.

Do step 1 *before* the copy next time and the bars are right on the first login.

**If the addon's command does nothing on the PTR** — as though it were never installed —
then it did not load, which is a different problem from the profile being missing. Check
in this order:

1. **Did you install it on live after the last time you ran this tool?** The addon step copies
   the addon folder as it stood when it ran. Install something on live afterwards and it
   is simply not on the PTR yet. Re-run the tool; the window notices the live `AddOns`
   folder changing on its own, so the addon step will already be offering to copy again.
   This is far and away the most common cause.

   While you are at it: **log into the live client once after installing an addon,
   before running this tool.** `AddOns.txt` is a snapshot of which addons were ticked
   the last time that character logged in, and the per-character step copies it. Take the snapshot
   before the addon existed and the copied character has no entry for it.
2. **Is the folder there?** Look for `Interface\AddOns\<Addon>\` inside the PTR client
   folder. Nothing there means point 1.
3. **Is it ticked?** At character select, open **AddOns**. A copied addon that is listed
   but unticked just needs enabling.
4. **Does the build match the client?** An addon built for retail will not load on an
   Anniversary client however out-of-date loading is set.
5. **Is out-of-date loading on?** Confirm `SET checkAddonVersion "0"` is in the PTR's
   `WTF\Config.wtf` — the out-of-date addons step sets it, and without it everything built for live reads as
   out of date.

### Two macros with the same name

Anything that identifies a macro by name needs those names to be distinct.
ActionBarSaver says so outright, and a restore otherwise fails with a page of *unable to
restore item to slot*.

The usual way to end up there is not a bug: Classic prints a macro's name on its action
button, so wanting clean bars leads to naming every macro the same single space. Thirty
macros called `" "` is thirty conflicts. But two both called `weps` break it just as
thoroughly, and that is the actual problem — duplication, not blankness.

There is an option, **Break ties between macros that share a name**, which fixes the
PTR's copy on the way over. The first macro of each duplicated name keeps it; the rest
get a suffix built from spaces and no-break spaces, so `weps` still reads as `weps` on
the bar while being unique to anything looking it up. A macro whose name is already its
own is never touched.

**On its own that is not enough for an action bar saver**, and it is worth being clear
why. The addon records, for each slot, the name of the macro in it — and it does that
*on your live client*, where the names still collide. A profile saved from thirty
identically-named macros is already ambiguous; making the PTR's names unique afterwards
cannot recover which slot wanted which macro.

So the names have to be fixed on the **live** client, before the profile is saved.

There is a step for it in the window — **Break ties between macros on your LIVE client**.
It is the only thing in the whole tool that writes outside the PTR folder, so it behaves
differently from everything else:

- **It is never ticked for you.** Every other automated step is on by default; this one
  you have to choose.
- The Apply confirmation names it and names the folder it will write to.
- It is previewable like anything else.
- It touches nothing but `macros-cache.txt`, and within that nothing but the names.
- It is the one step that does **not** leave a backup. It writes once and then reports
  itself done, so a backup would be a folder created inside your real game install and
  never used again. That does mean no undo from the window: if you want one,
  `tools\Rename-DuplicateMacros.ps1` does the same job and keeps the original beside the
  file as `macros-cache.txt.before-rename`.

**The order matters:**

1. Quit WoW — it rewrites `macros-cache.txt` on exit and would undo this.
2. Tick that step, Apply.
3. Log in on live and save your action bar profile. *Now*, not before — a profile saved
   earlier was written from the old names.
4. Run the rest of the tool, then restore the profile on the PTR.

There is the same thing as a script, if you would rather do it outside the window:

```powershell
.\tools\Rename-DuplicateMacros.ps1 -Path 'C:\...\WTF\Account\<ACCOUNT>\macros-cache.txt'
```

It reports what it would do and writes nothing until you add `-Apply`, keeping the
original as `macros-cache.txt.before-rename`. Do the character-level file too, with
`-Scope Character`.

### An addon that loads on live and errors on the PTR

If the error names `Libs/AceDB-3.0/AceDB-3.0.lua` and says **"attempt to concatenate
local 'regionKey' (a nil value)"**, that is a stale copy of the Ace3 libraries, not
anything this tool did. AceDB builds its scope keys from a five-entry region table:

```lua
local regionTable = { "US", "KR", "EU", "TW", "CN" }
local regionKey = regionTable[GetCurrentRegion()]
```

PTR realms report a region id that is not in it, so `regionKey` is `nil` and the next
line — a concatenation — throws. The addon's `OnInitialize` dies with it, so its slash
commands are never registered and it looks as though it is not installed at all.

It is worse than one addon. Ace3 libraries are shared through LibStub, and the
highest-versioned copy across *all* your addons is the one everything uses — so a single
addon carrying a stale AceDB breaks every Ace3 addon on the PTR at once, which can look
like copied settings having gone wrong. The traceback names which addon's copy is in
play.

**This tool fixes it for you**, and the option — *Fix the PTR copy of Ace3 so addons
using it can start* — is on by default. It gives the lookup a fallback:

```lua
local regionKey = regionTable[GetCurrentRegion()] or "US"
```

Three things bound what that does. It writes **only to the PTR**; your live client is
read and never touched, which is the invariant the whole tool rests on and which an
integration test asserts. It touches **only files named `AceDB-3.0.lua`**, and only that
one assignment — everything else in the file, down to the line endings, is byte for byte
the live copy. And a library that already has a fallback is left alone, so a current
Ace3 passes through untouched and a second Apply still reports itself done.

It is a workaround, not a fix. The real answer is updating the addon that carries the
stale copy, or dropping a current Ace3 `Libs\AceDB-3.0` into any one addon so it wins
the LibStub version race. Untick the option if you would rather do that yourself.

Errors from the addon while *saving* on live are a different matter and usually harmless:
macros are the part these addons handle least well, since a macro that does not exist on
the destination cannot be placed. Bars restore; a few macro slots may not.

On retail, save and restore on the same specialisation — action bars are per-spec there.
Screenshots remain the no-addon option, and are worth taking before a first attempt.

[Action Bar Saver]: https://www.curseforge.com/wow/addons/action-bar-saver
[ActionBarSaver: Reloaded]: https://www.curseforge.com/wow/addons/actionbarsaver-reloaded
[TBCA Action Bars Saver]: https://www.curseforge.com/wow/addons/tbca-action-bars-saver-copy-save-restore

## What about Blizzard's "Copy Account Data" button?

It does not overlap with this tool much, and if it fails for you it costs you very
little. Blizzard's servers cannot read your hard drive, so whatever that button moves
is server-side account data. Everything below lives in files on your PC and is out of
its reach entirely:

- the addon folders themselves, `Interface\AddOns`
- every addon's settings — Bartender, WeakAuras, Details, Plater and the rest, in
  `SavedVariables`
- which profile each character loads (see the section above)
- `AddOns.txt`, the enabled list, and `layout-local.txt`, the frame positions
- `Config.wtf` — resolution, graphics, weather, volume

The genuine overlap is **macros and keybinds**, which are plausibly server-side as
well. This tool copies them from files regardless — `bindings-cache.wtf` and
`macros-cache.txt` at both account and character level — so a button that does not
work changes nothing as long as *Include macros and keybinds* stays ticked. If the
button does work for you, untick it and let Blizzard do that half.

Either way the step cards settle it without writing anything: press the button, then open
the file list on *Copy account-wide addon settings*. Files that already match are marked
as such, so what is left is exactly what Blizzard did not bring across.

If keybinds arrive correctly and then revert after you log in and out, that is not this
tool — WoW rewrites `WTF` on exit, and a client with server-side settings sync enabled
can push its own copy down over the file. Look for a sync or cloud settings option in
the game's own settings, then re-run the step.
