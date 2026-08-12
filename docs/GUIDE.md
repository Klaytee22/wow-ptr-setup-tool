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
| "Addons will default to account-wide settings…" | `copy_account_saved_variables` | See deviation 1 — with this step, that manual profile-copying is unnecessary |
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

**5. Deleting the PTR addon folder is reversible here.** The guide says delete; this
copies everything it removes into a backup first, so Restore puts it back — including
addons that only ever existed on the PTR.

## Things the guide gets right that are easy to miss

- **The realm folder is named differently on the PTR** ("Classic PTR Realm 1"), so the
  character mapping is explicit in the window rather than matched by path.
- **The account folder may be named differently too** ("Account Name/Number" vs
  "Account Number"), which is why both sides have their own account dropdown.
- **Quitting the game matters.** WoW rewrites `WTF` on exit, so anything copied while
  it is running is silently undone.

## Client folder names

The guide says `classic` and `classic_ptr`; on disk those are `_classic_` and
`_classic_ptr_`. The tool recognises the whole family, and pairs a live client with the
PTR client on the same `line` automatically.

| Folder | Label | Line | PTR? |
|--------|-------|------|------|
| `_retail_` | Retail | retail | no |
| `_ptr_` | Retail PTR | retail | yes |
| `_xptr_` | Retail PTR 2 | retail | yes |
| `_beta_` | Retail Beta | retail | yes |
| `_classic_` | Classic | classic | no |
| `_classic_ptr_` | Classic PTR | classic | yes |
| `_classic_beta_` | Classic Beta | classic | yes |
| `_classic_era_` | Classic Era | era | no |
| `_classic_era_ptr_` | Classic Era PTR | era | yes |
| `_classic_era_beta_` | Classic Era Beta | era | yes |

Blizzard adds folders over time; new ones go in `$script:WowFlavors` in
`Modules/PtrUiSetup/Detect.ps1` and need no other change.

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
