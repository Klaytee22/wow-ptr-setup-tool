# The source guide

This tool automates a written procedure. This file is where that procedure lives, so
the step list in `Modules/PtrUiSetup/Steps.ps1` can be checked against it rather than
against someone's memory.

## Status: not yet transcribed

The reference guide is a Reddit post in r/classicwowtbc:

    https://www.reddit.com/r/classicwowtbc/s/fyaWbK0Q1o

It has not been transcribed here yet — paste its text into the "Reference procedure"
section below, then reconcile it against the implemented steps and delete this notice.

Until that happens, the steps in `Steps.ps1` are built from the **standard, widely
documented PTR UI copy procedure**, not from that specific post. Each step carries a
`SourceNote` explaining why it exists, and those notes are what the reconciliation
pass should replace with a pointer into the guide.

## Reference procedure

> _(paste the guide here)_

## Implemented steps

| Step id | Mode | Why it exists |
|---------|------|---------------|
| `install_ptr_client` | manual | The PTR's `WTF` and `Interface` trees only exist after a first launch; without them there is nowhere to copy to. |
| `copy_character` | manual | Per-character settings need a character folder on a PTR realm, which only Blizzard's character copy creates. |
| `copy_addons` | auto | `Interface/AddOns` is the addon code itself. |
| `copy_config_wtf` | auto | `Config.wtf` holds client-wide cvars — resolution, window mode, sound. |
| `copy_account_saved_variables` | auto | `WTF/Account/<ACCOUNT>/SavedVariables` is where most addons keep profiles. |
| `copy_character_data` | auto | Per-character `SavedVariables` plus `AddOns.txt` and `layout-local.txt`. |
| `allow_out_of_date_addons` | auto | The PTR runs a higher interface version, so live addons read as out of date. |
| `verify_in_game` | manual | The copy is only good if the client comes up with it. |

## Reconciliation checklist

When the guide text lands, walk it and confirm for each instruction:

- [ ] Is there a step for it? If not, add a `New-PtrSetupStep` entry to `$script:PtrSetupSteps`.
- [ ] Does the guide's ordering match the order in `$script:PtrSetupSteps`?
- [ ] Does the guide copy anything this tool does not (e.g. `chat-cache.txt`,
      `config-cache.wtf`, `bindings-cache.wtf`)? Those are options today — check the
      defaults match the guide's advice.
- [ ] Does the guide say to copy `Config.wtf` wholesale? This tool deliberately merges
      instead, keeping the PTR's `realmList`/`portal`. If the guide has a reason to
      copy it whole, capture that reason here before changing the behaviour.
- [ ] Are any steps guide-specific to one expansion's PTR cycle (folder names,
      character-copy flow)? Those need to stay data-driven rather than hardcoded.
- [ ] Replace each step's `SourceNote` with a reference into this file.

## Client folder names

The tool recognises these client folders inside a `World of Warcraft` install; live and
PTR clients on the same `line` are what it pairs up automatically.

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
