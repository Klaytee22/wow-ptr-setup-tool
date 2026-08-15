# The source guide

This tool automates a written procedure. That procedure lives here, so the step list in
`Modules/PtrUiSetup/Steps.ps1` can be checked against it rather than against someone's
memory. Every step carries a `SourceNote` pointing back at the instruction it implements.

## Reference procedure

> **How to copy over addons, addon settings, keybindings, macros, and game settings over to the PTR:**
>
> Before doing anything, log onto the PTR, copy your character, log in, then exit the game.
>
> Make sure the PTR client is closed, as some settings will not save if you have it open.
>
> Open up two Windows Explorer windows. On one window, go to World of Warcraft -> classic. On the other, go to World of Warcraft -> classic_ptr.
>
> **Copying Addons**
>
> Step 1 - On classic, go to Interface -> Addons. Select all your addons and copy.
>
> Step 2 - On classic_ptr, go to Interface -> Addons. Delete any addons there if you have any. Paste your addons.
>
> **Copying Addon Settings**
>
> Step 1 - On classic, go to WTF -> Account -> Account Name/Number -> Realm -> Character -> OPEN Saved Variables. Copy all the files.
>
> Step 2 - On classic_ptr, go to WTF -> Account -> Account Number -> Classic PTR Realm 1 -> Character -> OPEN Saved Variables. Paste and overwrite all the files.
>
> Addons will default to account-wide settings. Log in and go to each addon and copy the profile from your Live Character's profile.
>
> **Copying Game Settings**
>
> *Client-based Settings: Stuff like weather intensity and graphics.*
>
> Step 1 - On classic, go to WTF -> Account. Open "Config.wtf" in Notepad. Copy all the text.
>
> Step 2 - On classic_ptr, go to WTF -> Account. Open "Config.wtf" in Notepad. Paste all the text and save.
>
> *Character-based Settings: Stuff like max camera distance and floating combat text.*
>
> Step 1 - On classic, go to WTF -> Account -> Account Name/Number -> Realm -> Character. Open "config-cache.wtf" in Notepad. Copy all the text.
>
> Step 2 - On classic_ptr, go to WTF -> Account -> Account Number -> Classic PTR Realm 1 -> Character. Open "config-cache.wtf" in Notepad. Select all, paste all the text and save.
>
> **Copying Keybindings**
>
> *Account-wide Keybindings:*
>
> Step 1 - On classic, go to WTF -> Account -> Account Name/Number. Open "bindings-cache.wtf" in Notepad. Copy all the text.
>
> Step 2 - On classic_ptr, go to WTF -> Account -> Account Number. Open "bindings-cache.wtf" in Notepad. Select all, paste all the text and save.
>
> *Character-specific Keybindings:*
>
> Step 1 - On classic, go to WTF -> Account -> Account Name/Number -> Realm -> Character. Open "bindings-cache.wtf" in Notepad. Copy all the text.
>
> Step 2 - On classic_ptr, go to WTF -> Account -> Account Number -> Classic PTR Realm 1 -> Character. Open "bindings-cache.wtf" in Notepad. Select all, paste all the text and save.
>
> **Copying Macros**
>
> *Account-wide Macros:*
>
> Step 1 - On classic, go to WTF -> Account -> Account Name/Number. Open "macros-cache.wtf" in Notepad. Copy all the text.
>
> Step 2 - On classic_ptr, go to WTF -> Account -> Account Number. Open "macros-cache.wtf" in Notepad. Select all, paste all the text and save.
>
> *Character-specific Macros:*
>
> Step 1 - On classic, go to WTF -> Account -> Account Name/Number -> Realm -> Character. Open "macros-cache.wtf" in Notepad. Copy all the text.
>
> Step 2 - On classic_ptr, go to WTF -> Account -> Account Number -> Classic PTR Realm 1 -> Character. Open "macros-cache.wtf" in Notepad. Select all, paste all the text and save.

Source: r/classicwowtbc, <https://www.reddit.com/r/classicwowtbc/s/fyaWbK0Q1o>

## Instruction → step

| Guide instruction | Step | Notes |
|---|---|---|
| "log onto the PTR, copy your character, log in, then exit" | `install_ptr_client`, `copy_character` | Both manual, both self-checking: the first watches for the PTR's `WTF` folder, the second for a character folder on a PTR realm |
| "Make sure the PTR client is closed" | `quit_the_game` | Ticks itself off when no `Wow*` process is running; the Apply dialog warns again if one appears |
| "Open up two Windows Explorer windows" | — | Replaced by the two client dropdowns |
| Addons: copy all, delete any on the PTR, paste | `copy_addons` | The delete half is the **Replace the PTR addon folder** option, on by default |
| Character `SavedVariables` | `copy_character_data` | |
| "Addons will default to account-wide settings…" | `copy_account_saved_variables` | See deviations 1 and 6 — between them, that manual profile-copying is unnecessary |
| Client settings: `Config.wtf` | `copy_config_wtf` | See deviation 2 |
| Character settings: `config-cache.wtf` | `copy_character_data` | |
| Account keybindings: `bindings-cache.wtf` | `copy_account_saved_variables` | |
| Character keybindings: `bindings-cache.wtf` | `copy_character_data` | |
| Account macros | `copy_account_saved_variables` | See note 3 on the file extension |
| Character macros | `copy_character_data` | |
| — | `allow_out_of_date_addons` | Addition: the PTR runs a higher interface version, so live addons load only with `checkAddonVersion "0"` |
| — | `verify_in_game` | Addition: closing check |

## Where this tool deviates, and why

**1. It also copies account-level `SavedVariables`.** The guide only copies the
character folder, then says: *"Addons will default to account-wide settings. Log in and
go to each addon and copy the profile from your Live Character's profile."* That manual
step exists because the account-wide profiles never came across. Copying
`WTF\Account\<ACCOUNT>\SavedVariables` too brings them, so most addons come up already
configured. It is a separate, tickable step — untick it to follow the guide exactly.

**2. `Config.wtf` is merged, not pasted wholesale.** The guide pastes the whole file.
A live `Config.wtf` contains `realmList` and `portal` pointing at live login servers,
and pasting those into the PTR client can send it at live realms. The merge takes every
live setting *except* the client-identity keys
(`realmList`, `realmName`, `portal`, `agentUID`, `accountName`, `lastCharacterIndex`),
which keep the PTR's own values. Everything the guide is actually after — resolution,
window mode, weather density, graphics quality, volume — comes across. An integration
test asserts both halves of this.

**3. The macro cache is `macros-cache.txt`, not `.wtf`.** The guide writes
"macros-cache.wtf". WoW writes `macros-cache.txt`. Both names are planned and whichever
exists is copied, so the tool is right either way and a future rename cannot break it.

**4. `Config.wtf` lives in `WTF\`, not `WTF\Account\`.** The guide says
"go to WTF -> Account. Open Config.wtf" for client settings; the file is one level up,
at `WTF\Config.wtf`. The tool uses the real location.

**6. It points each addon's profile at the PTR character.** This is the other half of
deviation 1. Copying the account SavedVariables brings the profiles across, but most
addons pick which one to load out of an `AceDB-3.0` table keyed by character:

```lua
["profileKeys"] = {
	["Sunderfury - Whitemane"] = "Sunderfury - Whitemane",
},
```

The PTR realm is not `Whitemane`, so nothing matches and the addon starts on its
default — the profile is sitting right there in the file, unused. That is exactly
what the guide's *"Log in and go to each addon and copy the profile from your Live
Character's profile"* is working around. Adding one line per mapped character closes
it, so bars, unit frames and layouts come up right on the first login rather than
after a round of profile-picking.

The key itself is the delicate part. In game AceDB builds it from `UnitName` and
`GetRealmName`; all this tool has is the realm's folder name under `WTF\Account\`.
Those are usually the same string, and when they are not, a key written from the
folder name is a key nothing ever reads — the addon starts on its default with the
right profile sitting unused beside it, and there is no error anywhere. So the
folder-name key is only a fallback: the PTR's own copy of the file is read first,
because the game wrote a key for that character there the first time it logged in,
and that one needs no assumption. Where the two differ, both are written — a
profileKeys entry that matches nobody is inert.

Only files that already hold a key for the live character are touched, only that
table is edited, and the added key is written the way WoW writes them (decimal
escapes for anything outside printable ASCII), so a name like `Ölrún` matches and
round-trips. It is the **Point addon profiles at your PTR character** option; untick
it and the files are copied verbatim, as in deviation 1 alone.

What this cannot reach is an addon that stores per-character data under its own
scheme rather than through `profileKeys` — those still need a profile picked in
game, as the guide says.

**5. Deleting the PTR addon folder is reversible here.** The guide says delete; this
copies everything it removes into a backup first, so Restore puts it back — including
addons that only ever existed on the PTR.

## A second implementation of the same guide

[WoW-PTR-Config-Copier](https://github.com/Azevedoc/WoW-PTR-Config-Copier)
(`CopyWoWConfigs.ps1`) is an interactive terminal script automating the same Reddit
thread. It is a useful second opinion on what has to move, and
`tests/Coverage.Tests.ps1` asserts that every copy operation in it is a file some step
here plans to write. Its nine operations map onto four of our steps:

| Its operation | Here |
|---|---|
| `Interface\AddOns` (robocopy, `/MIR` on "overwrite") | `copy_addons`, with `ReplaceAddOns` as `/MIR` |
| Account `SavedVariables` | `copy_account_saved_variables` |
| Account `bindings-cache.wtf`, `macros-cache.wtf`/`.txt` | `copy_account_saved_variables` |
| Character `SavedVariables` | `copy_character_data` |
| Character `config-cache.wtf`, `bindings-cache.wtf`, macros | `copy_character_data` |
| `WTF\Config.wtf` (copied wholesale) | `copy_config_wtf`, **merged** — deviation 2 |

Two differences are worth recording:

- It copies `Config.wtf` whole, which is the thing deviation 2 exists to avoid: that
  carries `realmList` and `portal` over from the live client. Independent arrival at the
  same file list, with the same hazard in it, is decent evidence the deviation is right.
- It copies `profileKeys` across unchanged, so every copied addon comes up on its
  default profile on the PTR — the manual profile-picking the guide describes. See
  deviation 6.
- It handles one character per run and does not touch `AddOns.txt`, `layout-local.txt`,
  or `checkAddonVersion`. Without the first two the addons arrive but come up disabled
  and in default positions; without the third the PTR treats every copied addon as out
  of date. Those are covered here and are not in the guide either — see the step table.

Things it has that this tool does not, both worth considering: it reads WoW's install
path out of the registry rather than scanning known folders, and it checks for an
elevated session, which matters when WoW lives under `Program Files`.

## Things the guide gets right that are easy to miss

- **The realm folder is named differently on the PTR** ("Classic PTR Realm 1"), so the
  character mapping is explicit in the window rather than matched by path.
- **The account folder may be named differently too** ("Account Name/Number" vs
  "Account Number"), which is why both sides have their own account dropdown.
- **Quitting the game matters.** WoW rewrites `WTF` on exit, so anything copied while
  it is running is silently undone.

## Client folder names

`Detect.ps1` names the client folders Blizzard has shipped so far and gives them tidy
labels, but the list is not the authority. Every client folder carries a `.flavor.info`
holding its product code (`wow`, `wow_classic`, `wow_classic_era`, …), and that is what
decides which line of the game a folder belongs to. A folder the table has never heard
of — `_anniversary_` and `_ptr2_` were both sitting in a real install with no way to
select them — is still detected as long as it is shaped like a client folder and carries
that file.

So a version added after this was written turns up in the dropdowns on its own, paired
with the right counterpart, without an update here.

## If the guide changes

Walk the new text and check, for each instruction:

- [ ] Is there a step for it? If not, add a `New-PtrSetupStep` entry to `$script:PtrSetupSteps`.
- [ ] Does the ordering still match `$script:PtrSetupSteps`?
- [ ] Does it name a file the tool does not copy? File lists are the `$script:*Files`
      constants at the top of `Steps.ps1`.
- [ ] Does it contradict a deviation above? Update the reasoning here before changing
      the behaviour.
- [ ] Add an integration test in `tests/Integration.Tests.ps1` asserting the new
      instruction's outcome on the mock install.
